#!/usr/bin/env bash
# Verification checks for the AI coding stack. Prints PASS/FAIL/SKIP per
# check; exits non-zero if any check fails.
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
  local resp
  resp="$(curl -fsS --max-time 30 -X POST "$OLLAMA_BASE_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"coder-$MODE\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}],\"max_tokens\":10}" \
    2>/dev/null || true)"
  if grep -q '"choices"' <<<"$resp"; then
    pass "POST /v1/chat/completions (coder-$MODE) returns a completion"
  else
    fail "POST /v1/chat/completions (coder-$MODE) returns a completion" "no 'choices' in response"
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

check_brave() {
  if [[ -z "${BRAVE_API_KEY:-}" ]]; then
    pass "Brave MCP server: disabled: no key"
    return
  fi
  local code
  code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://$BRAVE_MCP_HOST:$BRAVE_MCP_PORT/" 2>/dev/null || echo "000")"
  if [[ "$code" != "000" ]]; then
    pass "Brave MCP server reachable on $BRAVE_MCP_HOST:$BRAVE_MCP_PORT (HTTP $code)"
  else
    fail "Brave MCP server reachable on $BRAVE_MCP_HOST:$BRAVE_MCP_PORT" "no response (run ./scripts/stack.sh up)"
  fi
}

# Only a TCP/HTTP reachability probe -- not a full MCP Streamable HTTP
# handshake, which would need a real MCP client. Good enough to prove the
# process is up and listening on the right interface.

check_localhost_binding() {
  if [[ "$MODE" != "local" ]]; then
    skip "Ollama/Open WebUI/Brave MCP bind to 127.0.0.1 only" "MODE=server (binding is the reverse proxy's job, see docs/server.md)"
    return
  fi

  local ports=(11434 "$WEBUI_PORT")
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
    pass "Ollama/Open WebUI/Brave MCP bind to 127.0.0.1 only"
  else
    fail "Ollama/Open WebUI/Brave MCP bind to 127.0.0.1 only" "listening on all interfaces: ports ${bad[*]}"
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
  # Optional, macOS + Xcode only -- installed via `setup.sh --editors`.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "acp-bridge installed (Xcode ACP agent)" "not macOS"
    return
  fi
  local acp_bin="$REPO_ROOT/bin/acp-bridge"
  if [[ ! -x "$acp_bin" ]]; then
    skip "acp-bridge installed (Xcode ACP agent)" "not installed (optional; run ./scripts/setup.sh --editors)"
    return
  fi
  local installed_version
  installed_version="$("$acp_bin" --version 2>/dev/null | awk '{print $2}')"
  if [[ -n "${ACP_BRIDGE_VERSION:-}" && "$installed_version" == "$ACP_BRIDGE_VERSION" ]]; then
    pass "acp-bridge installed at pinned version $ACP_BRIDGE_VERSION"
  else
    fail "acp-bridge installed at pinned version ${ACP_BRIDGE_VERSION:-<unset>}" "found: ${installed_version:-<unknown>}"
  fi
}

check_ollama
check_allowlist
check_model_built
check_chat_completion
check_openwebui
check_brave
check_localhost_binding
check_privacy_env
check_env_not_tracked
check_acp_bridge

echo
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAIL_COUNT check(s) failed."
  exit 1
fi
