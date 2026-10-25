#!/usr/bin/env bash
# Verification checks for the AI coding stack. Prints PASS/FAIL/SKIP per
# check (WARN for advisories that don't fail); exits non-zero if any check fails.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found. Run: cp .env.example .env" >&2
  exit 1
fi
# setup.sh also puts Ollama's memory settings in the login environment
# (launchctl), so a shell started since then inherits the values last applied;
# only .env or the defaults in services/config.py may decide them.
unset OLLAMA_KV_CACHE_TYPE OLLAMA_NUM_PARALLEL LLAMA_ARG_CTX_CHECKPOINTS LLAMA_ARG_CACHE_RAM
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

case "${MODE:-}" in
  local|server) ;;
  *) echo "ERROR: MODE must be 'local' or 'server' in .env (got: '${MODE:-}')" >&2; exit 1 ;;
esac

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
WEBUI_HOST="${WEBUI_HOST:-127.0.0.1}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
BRAVE_MCP_HOST="${BRAVE_MCP_HOST:-127.0.0.1}"
BRAVE_MCP_PORT="${BRAVE_MCP_PORT:-8765}"
source "$REPO_ROOT/scripts/runtime.sh"
RUN_DIR="$REPO_ROOT/run"

# Allowlist: hard-rule models plus our own derived ones. Keep this in sync
# with the master prompt's allowlist -- any addition needs explicit approval.
# `ollama create <name>`/`ollama pull <name>` with no tag normalizes to
# `<name>:latest` in `ollama list`, so both forms are listed wherever that
# applies (nomic-embed-text and our own derived models).
ALLOWLIST=(
  llama3.1:8b llama3.3:70b gemma4:12b starcoder2:3b
  nomic-embed-text nomic-embed-text:latest
  coder-local coder-local:latest
  coder-server coder-server:latest
)

FAIL_COUNT=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+ -- $2}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { printf 'SKIP  %s%s\n' "$1" "${2:+ -- $2}"; }
warn() { printf 'WARN  %s%s\n' "$1" "${2:+ -- $2}"; }

is_allowed() {
  local name="$1" a
  for a in "${ALLOWLIST[@]}"; do
    [[ "$name" == "$a" ]] && return 0
  done
  return 1
}

check_ollama() {
  if curl -fsS --max-time 3 "$OLLAMA_BASE_URL/api/version" >/dev/null 2>&1; then
    pass "Ollama reachable at $OLLAMA_BASE_URL"
  else
    fail "Ollama reachable at $OLLAMA_BASE_URL" "no response"
    return
  fi

  local server_json="$HOME/.ollama/server.json" service_env
  if [[ "$(uname -s)" != "Darwin" ]] && command -v systemctl >/dev/null 2>&1; then
    # The Linux service runs as the `ollama` user and never reads this
    # account's server.json (see setup.sh).
    service_env="$(systemctl show ollama --property=Environment 2>/dev/null)"
    if [[ " ${service_env#Environment=} " == *" OLLAMA_NO_CLOUD=1 "* ]]; then
      pass "Ollama Cloud disabled (OLLAMA_NO_CLOUD=1 in the ollama service)"
    else
      fail "Ollama Cloud disabled" "the ollama service lacks OLLAMA_NO_CLOUD=1 -- ./scripts/setup.sh prints the systemctl steps"
    fi
  elif [[ -f "$server_json" ]] && grep -Eq '"disable_ollama_cloud"[[:space:]]*:[[:space:]]*true' "$server_json"; then
    pass "Ollama Cloud disabled"
  else
    fail "Ollama Cloud disabled" "disable_ollama_cloud:true not found in $server_json (run ./scripts/setup.sh)"
  fi
}

check_ollama_cache_limits() {
  # setup.sh puts these in Ollama's environment; llama-server only sees them
  # once Ollama has been restarted, so check the running server, not launchctl.
  local want=() var kv current pid missing=() name="Ollama memory settings applied"
  for var in OLLAMA_KV_CACHE_TYPE OLLAMA_NUM_PARALLEL LLAMA_ARG_CTX_CHECKPOINTS LLAMA_ARG_CACHE_RAM; do
    if [[ -n "${!var}" ]]; then want+=("$var=${!var}"); fi
  done
  if [[ ${#want[@]} -eq 0 ]]; then
    skip "$name" "not set in .env"
    return
  fi
  name="$name (${want[*]})"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pid="$(pgrep -f 'ollama serve' | head -1)"
    if [[ -z "$pid" ]]; then
      skip "$name" "no 'ollama serve' process found"
      return
    fi
    current="$(ps eww -p "$pid" 2>/dev/null)"
  elif command -v systemctl >/dev/null 2>&1; then
    current="$(systemctl show ollama --property=Environment 2>/dev/null)"
    current="${current#Environment=}"
  else
    skip "$name" "no systemd to read the ollama service's environment from"
    return
  fi
  for kv in "${want[@]}"; do
    if [[ " $current " != *" $kv "* ]]; then missing+=("$kv"); fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "$name"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    fail "$name" "Ollama is running without ${missing[*]} -- run ./scripts/setup.sh, then quit and reopen the Ollama app"
  else
    fail "$name" "the ollama service lacks ${missing[*]} -- ./scripts/setup.sh prints the systemctl steps"
  fi
}

check_allowlist() {
  local listing
  listing="$(ollama list 2>/dev/null)" || { fail "All models in 'ollama list' are on the allowlist" "ollama list failed"; return; }

  local violations=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^NAME[[:space:]] ]] && continue
    local name="${line%% *}"
    is_allowed "$name" || violations+=("$name")
  done <<<"$listing"

  if [[ ${#violations[@]} -eq 0 ]]; then
    pass "All models in 'ollama list' are on the allowlist"
  else
    fail "All models in 'ollama list' are on the allowlist" "not allowed: ${violations[*]}"
  fi
}

check_webui_ocr_models() {
  # rapidocr, an open-webui dependency, bundles Baidu's PaddleOCR models;
  # setup.sh installs Open WebUI without it (hard rule 1).
  local python="$REPO_ROOT/.venv/openwebui/bin/python" found name="No Chinese-origin OCR models in Open WebUI's venv (rapidocr)"
  if [[ ! -x "$python" ]]; then
    skip "$name" "Open WebUI not installed"
    return
  fi
  found="$("$python" -c 'import importlib.util as u; print(" ".join(n for n in ("rapidocr", "rapidocr_onnxruntime") if u.find_spec(n)))' 2>/dev/null)"
  if [[ -z "$found" ]]; then
    pass "$name"
  else
    fail "$name" "installed: $found -- rebuild the venv: rm -rf .venv/openwebui && ./scripts/setup.sh"
  fi
}

check_whisper_model() {
  # Open WebUI's voice input reads this folder only (HF_HUB_OFFLINE=1), so a
  # missing or altered file means no transcription, never a download.
  local name="Voice input model (Whisper small) matches its pinned hashes"
  if whisper_model_ok; then
    pass "$name"
  else
    fail "$name" "missing or changed in data/whisper/ -- run ./scripts/setup.sh"
  fi
}

check_voice_cleanup() {
  # Open WebUI keeps every voice recording; stack.sh installs
  # services/voice_cleanup.py as an event function that deletes each one once
  # it is transcribed. Read-only look at Open WebUI's database.
  local db="$REPO_ROOT/data/openwebui/webui.db" name="Voice recordings deleted once transcribed (Open WebUI function)" state old
  if [[ ! -f "$db" ]]; then
    skip "$name" "Open WebUI has no database yet (run ./scripts/stack.sh up)"
    return
  fi
  state="$(python3 -I - "$db" "$REPO_ROOT/services/voice_cleanup.py" 2>/dev/null <<'PYEOF'
import pathlib, sqlite3, sys
db = sqlite3.connect(pathlib.Path(sys.argv[1]).as_uri() + '?mode=ro', uri=True)
row = db.execute("SELECT is_active, content FROM function WHERE id = 'delete_voice_recordings'").fetchone()
print('not installed' if row is None else 'inactive' if not row[0]
      else 'differs from services/voice_cleanup.py' if row[1] != pathlib.Path(sys.argv[2]).read_text() else 'ok')
PYEOF
)"
  case "$state" in
    ok) pass "$name" ;;
    '') fail "$name" "could not read data/openwebui/webui.db" ;;
    *) fail "$name" "$state -- run ./scripts/stack.sh down && ./scripts/stack.sh up" ;;
  esac
  old="$(find "$REPO_ROOT/data/openwebui/cache/audio/transcriptions" -type f -mmin +60 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$old" -gt 0 ]]; then
    warn "No voice recordings older than an hour" "$old file(s) in data/openwebui/cache/audio/transcriptions/ (failed transcriptions; deleted at the next one or at restart)"
  fi
}

check_pins_match_example() {
  # stack.sh and the gateway are verified against the pins in .env.example;
  # .env is authoritative, so one copied earlier keeps the old versions.
  local var want drift=()
  for var in OPEN_WEBUI_VERSION BRAVE_MCP_VERSION ACP_BRIDGE_VERSION ACP_BRIDGE_COMMIT; do
    want="$(sed -n "s/^$var=\([^[:space:]#]*\).*/\1/p" "$REPO_ROOT/.env.example" | head -1)"
    if [[ -n "$want" && "${!var:-}" != "$want" ]]; then drift+=("$var=${!var:-<unset>} (.env.example: $want)"); fi
  done
  if [[ ${#drift[@]} -eq 0 ]]; then
    pass "Version pins in .env match .env.example"
  else
    warn "Version pins in .env match .env.example" "${drift[*]} -- copy them into .env, then run ./scripts/setup.sh"
  fi
}

check_model_built() {
  local expect_ctx="$MODEL_CONTEXT"  # num_ctx in Modelfile.$MODE
  if ! ollama show "coder-$MODE" >/dev/null 2>&1; then
    fail "coder-$MODE exists" "not found (run ./scripts/setup.sh)"
    return
  fi
  pass "coder-$MODE exists"

  local modelfile
  modelfile="$(ollama show "coder-$MODE" --modelfile 2>/dev/null || true)"
  if grep -Eq "PARAMETER[[:space:]]+num_ctx[[:space:]]+$expect_ctx" <<<"$modelfile"; then
    pass "coder-$MODE has num_ctx=$expect_ctx"
  else
    fail "coder-$MODE has num_ctx=$expect_ctx" "not found in 'ollama show coder-$MODE --modelfile'"
  fi
}

check_chat_completion() {
  if python3 - <<'PYEOF'
import json, os, urllib.request
url = os.environ['GATEWAY_BASE_URL']
key = os.environ.get('GATEWAY_SERVICE_KEY', '')
request = urllib.request.Request(url + '/v1/chat/completions',
    data=json.dumps({'model': os.environ['CHAT_MODEL'], 'messages': [{'role':'user','content':'Reply pong'}], 'max_tokens':10}).encode(),
    headers={'Authorization':'Bearer '+key, 'Content-Type':'application/json'})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        assert 'choices' in json.load(response)
except Exception:
    raise SystemExit(1)
PYEOF
  then
    pass "Gateway chat completion ($CHAT_MODEL via $INFERENCE_BACKEND)"
  else
    fail "Gateway chat completion" "not ready or took longer than 30 seconds; check gateway/backend logs"
  fi
}

check_gateway() {
  if python3 - <<'PYEOF'
import json, os, urllib.request
try:
    with urllib.request.urlopen(os.environ['GATEWAY_BASE_URL'] + '/health', timeout=3) as response:
        data = json.load(response)
        assert data['backend'] == os.environ['INFERENCE_BACKEND']
        assert data['model'] == os.environ['CHAT_MODEL']
except Exception:
    raise SystemExit(1)
PYEOF
  then pass "Gateway mode/backend match .env"
  else fail "Gateway mode/backend match .env" "restart stack after configuration changes"; fi
  # "localhost" can mean ::1 first; Android Studio retries only there after a
  # timed-out request, so the gateway must answer on it too.
  if curl -fsS --max-time 3 -g "http://[::1]:${GATEWAY_PORT:-8787}/health" >/dev/null 2>&1; then
    pass "Gateway answers on [::1] (IPv6 loopback)"
  else
    fail "Gateway answers on [::1] (IPv6 loopback)" "restart the stack: ./scripts/stack.sh down && ./scripts/stack.sh up"
  fi
}

check_openwebui() {
  if curl -fsS --max-time 3 "http://$WEBUI_HOST:$WEBUI_PORT/health" >/dev/null 2>&1 \
    || curl -fsS --max-time 3 "http://$WEBUI_HOST:$WEBUI_PORT/" >/dev/null 2>&1; then
    pass "Open WebUI responds on $WEBUI_HOST:$WEBUI_PORT"
  else
    fail "Open WebUI responds on $WEBUI_HOST:$WEBUI_PORT" "no response (run ./scripts/stack.sh up)"
  fi
}

check_openwebui_tasks() {
  # stack.sh's settings for Open WebUI's own model calls, read from the running
  # process (they only apply after a restart): titles and tags without
  # thinking, no suggestions, and speech one paragraph at a time.
  local pid current kv missing=() name="Open WebUI background tasks without thinking, no suggestions, speech by paragraph"
  pid="$(cat "$RUN_DIR/openwebui.pid" 2>/dev/null)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    skip "$name" "Open WebUI not running"
    return
  fi
  current="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n')"
  for kv in 'TASK_MODEL_PARAMS={"reasoning_effort":"none"}' 'DEFAULT_PROMPT_SUGGESTIONS=[]' \
    'ENABLE_FOLLOW_UP_GENERATION=false' 'ENABLE_AUTOCOMPLETE_GENERATION=false' 'AUDIO_TTS_SPLIT_ON=paragraphs'; do
    grep -qxF -- "$kv" <<<"$current" || missing+=("$kv")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "$name"
  else
    fail "$name" "Open WebUI is running without ${missing[*]} -- restart the stack: ./scripts/stack.sh down && ./scripts/stack.sh up"
  fi
}

check_brave() {
  if [[ -z "${BRAVE_API_KEY:-}" ]]; then
    pass "Brave MCP server: disabled: no key"
    return
  fi
  # GET /ping is the server's own health route (answers {"message":"pong"};
  # dist/protocols/http.js in @brave/brave-search-mcp-server 2.1.4). Not a full
  # MCP handshake, which would need a real MCP client -- but it proves the Brave
  # server itself is up on the configured address.
  if curl -fsS --max-time 3 "http://$BRAVE_MCP_HOST:$BRAVE_MCP_PORT/ping" 2>/dev/null | grep -q '"pong"'; then
    pass "Brave MCP server answers GET /ping on $BRAVE_MCP_HOST:$BRAVE_MCP_PORT"
  else
    fail "Brave MCP server answers GET /ping on $BRAVE_MCP_HOST:$BRAVE_MCP_PORT" "no pong (run ./scripts/stack.sh up; see logs/brave-mcp.log)"
  fi
}

# Which editor runs acp-bridge with editors/acp/$1.
agent_label() {
  case "$1" in
    config.toml) echo "Xcode" ;;
    config.android.toml) echo "Android Studio" ;;
    config.vscode.toml) echo "VS Code" ;;
  esac
}

check_acp_web_search_url() {
  # The acp-bridge configs can't read .env, so the agents' Brave URL is a
  # literal there -- it must point at the server stack.sh starts.
  local want="http://$BRAVE_MCP_HOST:$BRAVE_MCP_PORT/mcp" got file label
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "ACP agents' web search URL matches .env" "not macOS (no acp-bridge here)"
    return
  fi
  for file in config.toml config.android.toml config.vscode.toml; do
    label="$(agent_label "$file")"
    got="$(awk '/^\[\[mcp\.servers\]\]/ {s = 1; next} /^\[/ {s = 0} s && /^[[:space:]]*url[[:space:]]*=/' "$REPO_ROOT/editors/acp/$file" 2>/dev/null \
      | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
    if [[ "$got" == "$want" ]]; then
      pass "$label agent's web search URL matches .env ($want)"
    else
      fail "$label agent's web search URL matches .env ($want)" "editors/acp/$file has: ${got:-<none>}"
    fi
  done
}

check_localhost_binding() {
  local ports=(11434 "$WEBUI_PORT" "${GATEWAY_PORT:-8787}")
  [[ -n "${BRAVE_API_KEY:-}" ]] && ports+=("$BRAVE_MCP_PORT")

  # Every listening address must be loopback: 127.0.0.1, or [::1] (the
  # gateway listens on both). Anything else -- *, 0.0.0.0, [::] or a LAN IP --
  # is reachable from the network.
  local bad=() port addr
  for port in "${ports[@]}"; do
    while read -r addr; do
      [[ -z "$addr" ]] && continue
      case "${addr%:"$port"}" in
        127.0.0.1|'[::1]') ;;
        *) bad+=("$addr") ;;
      esac
    done < <(
      if [[ "$(uname -s)" == "Darwin" ]]; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}'
      else
        ss -tln 2>/dev/null | awk -v p=":$port" 'NR > 1 && $4 ~ p"$" {print $4}'
      fi
    )
  done

  if [[ ${#bad[@]} -eq 0 ]]; then
    pass "Internal services bind to loopback only (127.0.0.1, ::1)"
  else
    fail "Internal services bind to loopback only (127.0.0.1, ::1)" "also listening on: ${bad[*]}"
  fi
}

check_privacy_env() {
  # Checks the flags stack.sh launches Open WebUI with, not a live /proc
  # read of the running process -- see docs/privacy.md for why.
  local stack_script="$REPO_ROOT/scripts/stack.sh"
  local required=(
    'OFFLINE_MODE=true'
    'HF_HUB_OFFLINE=1'
    "AUDIO_STT_ENGINE=''"
    'ENABLE_VERSION_UPDATE_CHECK=false'
    'ENABLE_COMMUNITY_SHARING=false'
    'DO_NOT_TRACK=true'
    'SCARF_NO_ANALYTICS=true'
    'ANONYMIZED_TELEMETRY=false'
    'ENABLE_WEB_SEARCH=false'
    'ENABLE_USER_WEBHOOKS=false'
    'ENABLE_PROFILE_IMAGE_URL_FORWARDING=false'
  )
  local missing=() kv
  for kv in "${required[@]}"; do
    grep -q "$kv" "$stack_script" || missing+=("$kv")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "Open WebUI privacy env flags configured in stack.sh"
  else
    fail "Open WebUI privacy env flags configured in stack.sh" "missing: ${missing[*]}"
  fi
}

check_continue_retired() {
  # Continue is no longer used (VS Code runs the ACP agent). Earlier --editors
  # runs left copies of BRAVE_API_KEY in .continue/ (the backups readable by
  # every account), which setup.sh now removes, and ~/.continue/config.yaml,
  # which is outside the repo and only reported here.
  local name="No leftovers from Continue (no longer supported)"
  if [[ -n "$(find "$REPO_ROOT/.continue" -maxdepth 1 -type f -name '.env*' 2>/dev/null)" ]]; then
    fail "$name" ".continue/ still holds copies of BRAVE_API_KEY -- run ./scripts/setup.sh to remove them"
  elif grep -qs -e 'coder-local' -e 'coder-server' "$HOME/.continue/config.yaml"; then
    warn "$name" "~/.continue/config.yaml still points at this stack -- uninstall the Continue extension and delete it (see docs/editors.md, VS Code)"
  else
    pass "$name"
  fi
}

check_env_not_tracked() {
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip ".env is not tracked by git" "not a git repository"
    return
  fi
  if git -C "$REPO_ROOT" ls-files --error-unmatch .env >/dev/null 2>&1; then
    fail ".env is not tracked by git" ".env IS tracked -- remove it: git rm --cached .env"
  else
    pass ".env is not tracked by git"
  fi
}

check_private_files() {
  # .env holds keys; data/ holds every chat, upload and API key (webui.db)
  # and the agents' saved conversations. setup.sh and stack.sh make them
  # owner-only.
  local bad=() path mode name="Secrets and data are owner-only (.env, data/, logs/, run/)"
  for path in .env data logs run; do
    [[ -e "$REPO_ROOT/$path" ]] || continue
    if [[ "$(uname -s)" == "Darwin" ]]; then
      mode="$(stat -f '%Lp' "$REPO_ROOT/$path")"
    else
      mode="$(stat -c '%a' "$REPO_ROOT/$path")"
    fi
    [[ "$mode" == *00 ]] || bad+=("$path")
  done
  if [[ ${#bad[@]} -eq 0 ]]; then
    pass "$name"
  else
    fail "$name" "other accounts can read: ${bad[*]} -- fix: chmod go= ${bad[*]}"
  fi
}

check_acp_bridge() {
  # Optional, macOS only (the Xcode, Android Studio and VS Code agents) --
  # built via `setup.sh --editors`, which writes bin/acp-bridge.stamp: the
  # version, commit and patch hash it was built from, plus the hash of the
  # binary it installed.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "acp-bridge built (ACP agents)" "not macOS"
    return
  fi
  local acp_bin="$REPO_ROOT/bin/acp-bridge" patch="$REPO_ROOT/editors/acp/acp-bridge.patch"
  if [[ ! -x "$acp_bin" ]]; then
    skip "acp-bridge built (ACP agents)" "not installed (optional; run ./scripts/setup.sh --editors)"
    return
  fi
  local name="acp-bridge built from pinned v${ACP_BRIDGE_VERSION:-<unset>} + editors/acp/acp-bridge.patch"
  if [[ -z "${ACP_BRIDGE_VERSION:-}" || -z "${ACP_BRIDGE_COMMIT:-}" ]]; then
    fail "$name" "ACP_BRIDGE_VERSION/ACP_BRIDGE_COMMIT missing in .env (copy both from .env.example)"
    return
  fi
  if [[ ! -f "$patch" ]]; then
    fail "$name" "editors/acp/acp-bridge.patch is missing from the repo -- restore it (e.g. git checkout -- editors/acp/acp-bridge.patch)"
    return
  fi
  local inputs bin_sha got installed_version
  inputs="version=$ACP_BRIDGE_VERSION commit=$ACP_BRIDGE_COMMIT patch_sha256=$(cat "$patch" "$REPO_ROOT/editors/acp/queue.patch" | shasum -a 256 | awk '{print $1}')"
  bin_sha="$(shasum -a 256 "$acp_bin" | awk '{print $1}')"
  got="$(cat "$REPO_ROOT/bin/acp-bridge.stamp" 2>/dev/null || true)"
  installed_version="$("$acp_bin" --version 2>/dev/null | awk '{print $2}')"
  if [[ -z "$got" ]]; then
    fail "$name" "bin/acp-bridge.stamp missing (old downloaded binary?) -- run ./scripts/setup.sh --editors"
  elif [[ "$got" == "$inputs" ]]; then
    fail "$name" "bin/acp-bridge.stamp is from an older setup.sh (no binary hash) -- run ./scripts/setup.sh --editors"
  elif [[ "$got" != "$inputs "* ]]; then
    fail "$name" "bin/acp-bridge.stamp does not match .env pins + patch (built from something else) -- run ./scripts/setup.sh --editors"
  elif [[ "$got" != "$inputs bin_sha256=$bin_sha" ]]; then
    fail "$name" "bin/acp-bridge is not the binary setup.sh built (sha256 differs from the stamp) -- run ./scripts/setup.sh --editors"
  elif [[ "$installed_version" != "$ACP_BRIDGE_VERSION" ]]; then
    fail "$name" "bin/acp-bridge --version reports: ${installed_version:-<nothing>}"
  else
    pass "$name"
  fi
}

check_acp_config() {
  # acp-bridge falls back to built-in defaults (no system prompt, MCP policy,
  # web search or persistence settings) when its config doesn't parse, and only
  # says so on stderr. Load it with the installed binary: persistence and MCP
  # off, a dead model URL and no stdin, so nothing is contacted or written.
  local out file name
  for file in config.toml config.android.toml config.vscode.toml; do
    name="$(agent_label "$file") agent config loads (editors/acp/$file)"
    if [[ "$(uname -s)" != "Darwin" ]]; then
      skip "$name" "not macOS"
      continue
    fi
    if [[ ! -x "$REPO_ROOT/bin/acp-bridge" ]]; then
      skip "$name" "acp-bridge not installed"
      continue
    fi
    out="$(env -i PATH="/usr/bin:/bin" HOME="$HOME" RUST_LOG=acp_bridge=info LLM_PERSIST=0 LLM_MCP=off \
      LLM_BASE_URL=http://127.0.0.1:9/v1 "$REPO_ROOT/bin/acp-bridge" "$REPO_ROOT/editors/acp/$file" </dev/null 2>&1)"
    if grep -q 'Loaded config file' <<<"$out" && ! grep -q 'Failed to parse config file' <<<"$out"; then
      pass "$name"
    else
      fail "$name" "$(grep -m1 -o 'Failed to parse config file.*' <<<"$out" | sed 's/\x1b\[[0-9;]*m//g' || echo 'no "Loaded config file" line from bin/acp-bridge')"
    fi
  done
}

check_mac_analytics() {
  # Read-only advisory. Xcode's mcpbridge (the Xcode agent's tool bridge) logs a
  # CoreAnalytics event per tool call; macOS uploads those to Apple only while
  # "Share Mac Analytics" (AutoSubmit) is on. System-wide, so WARN, not FAIL.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "macOS Share Mac Analytics off" "not macOS"
    return
  fi
  case "$(defaults read "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory" AutoSubmit 2>/dev/null)" in
    0) pass "macOS Share Mac Analytics off" ;;
    1) warn "macOS Share Mac Analytics off" "it is ON, so Xcode tool-use events may be sent to Apple -- turn it off in System Settings > Privacy & Security > Analytics & Improvements" ;;
    *) skip "macOS Share Mac Analytics off" "setting not readable" ;;
  esac
}

check_ollama
check_ollama_cache_limits
check_allowlist
check_webui_ocr_models
check_whisper_model
check_voice_cleanup
check_pins_match_example
check_model_built
check_gateway
check_chat_completion
check_openwebui
check_openwebui_tasks
check_brave
check_acp_web_search_url
check_localhost_binding
check_privacy_env
check_continue_retired
check_env_not_tracked
check_private_files
check_acp_bridge
check_acp_config
check_mac_analytics

echo
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAIL_COUNT check(s) failed."
  exit 1
fi
