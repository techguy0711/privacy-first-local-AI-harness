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

  local server_json="$HOME/.ollama/server.json"
  if [[ -f "$server_json" ]] && grep -Eq '"disable_ollama_cloud"[[:space:]]*:[[:space:]]*true' "$server_json"; then
    pass "Ollama Cloud disabled"
  else
    fail "Ollama Cloud disabled" "disable_ollama_cloud:true not found in $server_json (run ./scripts/setup.sh)"
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

check_model_built() {
  local expect_ctx=16384
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
}

check_openwebui() {
  if curl -fsS --max-time 3 "http://$WEBUI_HOST:$WEBUI_PORT/health" >/dev/null 2>&1 \
    || curl -fsS --max-time 3 "http://$WEBUI_HOST:$WEBUI_PORT/" >/dev/null 2>&1; then
    pass "Open WebUI responds on $WEBUI_HOST:$WEBUI_PORT"
  else
    fail "Open WebUI responds on $WEBUI_HOST:$WEBUI_PORT" "no response (run ./scripts/stack.sh up)"
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

check_acp_web_search_url() {
  # editors/acp/config.toml can't read .env, so the Xcode agent's Brave URL is a
  # literal there -- it must point at the server stack.sh starts.
  local cfg="$REPO_ROOT/editors/acp/config.toml" want="http://$BRAVE_MCP_HOST:$BRAVE_MCP_PORT/mcp" got
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "Xcode agent's web search URL matches .env" "not macOS (no Xcode agent here)"
    return
  fi
  got="$(awk '/^\[\[mcp\.servers\]\]/ {s = 1; next} /^\[/ {s = 0} s && /^[[:space:]]*url[[:space:]]*=/' "$cfg" 2>/dev/null \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
  if [[ "$got" == "$want" ]]; then
    pass "Xcode agent's web search URL matches .env ($want)"
  else
    fail "Xcode agent's web search URL matches .env ($want)" "editors/acp/config.toml has: ${got:-<none>}"
  fi
}

check_localhost_binding() {
  local ports=(11434 "$WEBUI_PORT" "${GATEWAY_PORT:-8787}")
  [[ -n "${BRAVE_API_KEY:-}" ]] && ports+=("$BRAVE_MCP_PORT")

  local bad=() port listen_lines
  for port in "${ports[@]}"; do
    if [[ "$(uname -s)" == "Darwin" ]]; then
      listen_lines="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    else
      listen_lines="$(ss -tlnp 2>/dev/null | awk -v p=":$port" '$4 ~ p')"
    fi
    [[ -z "$listen_lines" ]] && continue
    if grep -Eq '(^|[^0-9.])(0\.0\.0\.0|\*|::):'"$port"'([^0-9]|$)' <<<"$listen_lines"; then
      bad+=("$port")
    fi
  done

  if [[ ${#bad[@]} -eq 0 ]]; then
    pass "Internal services bind to 127.0.0.1 only"
  else
    fail "Internal services bind to 127.0.0.1 only" "listening on all interfaces: ports ${bad[*]}"
  fi
}

check_privacy_env() {
  # Checks the flags stack.sh launches Open WebUI with, not a live /proc
  # read of the running process -- see docs/privacy.md for why.
  local stack_script="$REPO_ROOT/scripts/stack.sh"
  local required=(
    'OFFLINE_MODE=true'
    'ENABLE_VERSION_UPDATE_CHECK=false'
    'ENABLE_COMMUNITY_SHARING=false'
    'DO_NOT_TRACK=true'
    'SCARF_NO_ANALYTICS=true'
    'ANONYMIZED_TELEMETRY=false'
    'ENABLE_WEB_SEARCH=false'
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

# True if YAML file $1 has "<$2>:" followed by "disabled: true" (Continue's
# chatOptions.toolOverrides.<tool>.disabled); trailing "# ..." comments allowed.
tool_disabled() {
  awk -v t="$2" '
    $0 ~ "^[[:space:]]*" t ":[[:space:]]*(#.*)?$" { want = 1; next }
    want && NF { if ($0 ~ /^[[:space:]]*disabled:[[:space:]]*true[[:space:]]*(#.*)?$/) found = 1; want = 0 }
    END { exit !found }' "$1"
}

check_continue_web_tools_off() {
  # Continue's built-in search_web sends queries to Continue's own cloud proxy
  # and fetch_url_content fetches arbitrary URLs -- both must stay disabled, in
  # the repo configs and in the ~/.continue/config.yaml Continue actually reads.
  local files=("$REPO_ROOT/editors/continue/config.local.yaml" "$REPO_ROOT/editors/continue/config.server.yaml")
  [[ -f "$HOME/.continue/config.yaml" ]] && files+=("$HOME/.continue/config.yaml")
  local missing=() f label tool
  for f in "${files[@]}"; do
    label="${f#"$REPO_ROOT"/}"
    [[ "$f" == "$HOME"/.continue/* ]] && label="~/${f#"$HOME"/}"
    for tool in search_web fetch_url_content; do
      tool_disabled "$f" "$tool" || missing+=("$label:$tool")
    done
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "Continue's search_web/fetch_url_content disabled"
  else
    fail "Continue's search_web/fetch_url_content disabled" "not disabled in: ${missing[*]} (re-run ./scripts/setup.sh --editors)"
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

check_acp_bridge() {
  # Optional, macOS + Xcode only -- built via `setup.sh --editors`, which writes
  # bin/acp-bridge.stamp: the version, commit and patch hash it was built from,
  # plus the hash of the binary it installed.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "acp-bridge built (Xcode ACP agent)" "not macOS"
    return
  fi
  local acp_bin="$REPO_ROOT/bin/acp-bridge" patch="$REPO_ROOT/editors/acp/acp-bridge.patch"
  if [[ ! -x "$acp_bin" ]]; then
    skip "acp-bridge built (Xcode ACP agent)" "not installed (optional; run ./scripts/setup.sh --editors)"
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
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "Xcode agent config loads (editors/acp/config.toml)" "not macOS"
    return
  fi
  if [[ ! -x "$REPO_ROOT/bin/acp-bridge" ]]; then
    skip "Xcode agent config loads (editors/acp/config.toml)" "acp-bridge not installed"
    return
  fi
  local out
  out="$(env -i PATH="/usr/bin:/bin" HOME="$HOME" RUST_LOG=acp_bridge=info LLM_PERSIST=0 LLM_MCP=off \
    LLM_BASE_URL=http://127.0.0.1:9/v1 "$REPO_ROOT/bin/acp-bridge" "$REPO_ROOT/editors/acp/config.toml" </dev/null 2>&1)"
  if grep -q 'Loaded config file' <<<"$out" && ! grep -q 'Failed to parse config file' <<<"$out"; then
    pass "Xcode agent config loads (editors/acp/config.toml)"
  else
    fail "Xcode agent config loads (editors/acp/config.toml)" "$(grep -m1 -o 'Failed to parse config file.*' <<<"$out" | sed 's/\x1b\[[0-9;]*m//g' || echo 'no "Loaded config file" line from bin/acp-bridge')"
  fi
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
check_allowlist
check_model_built
check_gateway
check_chat_completion
check_openwebui
check_brave
check_acp_web_search_url
check_localhost_binding
check_privacy_env
check_continue_web_tools_off
check_env_not_tracked
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
