#!/usr/bin/env bash
# up | down | status for the inference gateway, Ollama, WebUI and Brave.
set -euo pipefail

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
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
WEBUI_HOST="${WEBUI_HOST:-127.0.0.1}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
BRAVE_MCP_HOST="${BRAVE_MCP_HOST:-127.0.0.1}"
BRAVE_MCP_PORT="${BRAVE_MCP_PORT:-8765}"
BRAVE_MCP_VERSION="${BRAVE_MCP_VERSION:-}"
BRAVE_MCP_ENABLED_TOOLS="${BRAVE_MCP_ENABLED_TOOLS:-brave_web_search brave_news_search}"

source "$REPO_ROOT/scripts/runtime.sh"

RUN_DIR="$REPO_ROOT/run"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

WEBUI_PID_FILE="$RUN_DIR/openwebui.pid"
BRAVE_PID_FILE="$RUN_DIR/brave-mcp.pid"
GATEWAY_PID_FILE="$RUN_DIR/gateway.pid"

is_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

start_openwebui() {
  if is_running "$WEBUI_PID_FILE"; then
    echo "Open WebUI already running (pid $(cat "$WEBUI_PID_FILE"))"
    return
  fi
  local venv_bin="$REPO_ROOT/.venv/openwebui/bin/open-webui"
  if [[ ! -x "$venv_bin" ]]; then
    echo "ERROR: Open WebUI not installed. Run ./scripts/setup.sh first." >&2
    exit 1
  fi
  if ! "$REPO_ROOT/.venv/openwebui/bin/python" -c '' >/dev/null 2>&1; then
    echo "ERROR: Open WebUI venv is broken (repo moved or copied?). Run ./scripts/setup.sh to rebuild it." >&2
    exit 1
  fi
  if [[ -z "${WEBUI_SECRET_KEY:-}" ]]; then
    echo "ERROR: WEBUI_SECRET_KEY is empty in .env. Run ./scripts/setup.sh first." >&2
    exit 1
  fi
  echo "Starting Open WebUI on $WEBUI_HOST:$WEBUI_PORT..."
  (
    # `open-webui serve` is a Click CLI with its own --host/--port flags
    # (default 0.0.0.0:8080) -- it does NOT read HOST/PORT env vars (those
    # only apply to the Docker-image's backend/start.sh entrypoint, not this
    # pip-installed CLI). Passing them as flags is the only way that's been
    # confirmed to actually bind to 127.0.0.1 instead of all interfaces.
    export DATA_DIR="$REPO_ROOT/data/openwebui"
    export WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY"
    export WEBUI_AUTH=true
    export OLLAMA_BASE_URL="$OLLAMA_BASE_URL"
    export ENABLE_OLLAMA_API=false
    export ENABLE_OPENAI_API=true
    export OPENAI_API_BASE_URLS="$GATEWAY_BASE_URL/v1"
    export OPENAI_API_KEYS="$GATEWAY_SERVICE_KEY"
    export ENABLE_FORWARD_USER_INFO_HEADERS=true
    # Environment is authoritative when MODE/backend changes.
    export ENABLE_PERSISTENT_CONFIG=false
    export AIOHTTP_CLIENT_TIMEOUT="$((EDITOR_TIMEOUT_MS / 1000))"
    # Open WebUI's internal model id includes the ":latest" tag that
    # `ollama create coder-<mode>` (no explicit tag) produces -- confirmed
    # via GET /api/models; "coder-<mode>" alone does not match.
    export DEFAULT_MODELS="$CHAT_MODEL"
    export RAG_EMBEDDING_ENGINE=openai
    export RAG_OPENAI_API_BASE_URL="$GATEWAY_BASE_URL/v1"
    export RAG_OPENAI_API_KEY="$GATEWAY_SERVICE_KEY"
    export RAG_EMBEDDING_MODEL="$EMBED_MODEL"
    export ENABLE_RAG_HYBRID_SEARCH=false
    export OFFLINE_MODE=true
    export HF_HUB_OFFLINE=1
    export ENABLE_VERSION_UPDATE_CHECK=false
    export ENABLE_COMMUNITY_SHARING=false
    export DO_NOT_TRACK=true
    export SCARF_NO_ANALYTICS=true
    export ANONYMIZED_TELEMETRY=false
    export ENABLE_WEB_SEARCH=false
    nohup "$venv_bin" serve --host "$WEBUI_HOST" --port "$WEBUI_PORT" >> "$LOG_DIR/openwebui.log" 2>&1 &
    echo $! > "$WEBUI_PID_FILE"
  )
  sleep 1
  if ! is_running "$WEBUI_PID_FILE"; then
    echo "ERROR: Open WebUI exited right after starting; see logs/openwebui.log" >&2
    exit 1
  fi
  echo "Open WebUI started (pid $(cat "$WEBUI_PID_FILE")); logs at logs/openwebui.log"
}

start_inference() {
  local python="$REPO_ROOT/.venv/openwebui/bin/python"
  if [[ ! -x "$python" || -z "${GATEWAY_SERVICE_KEY:-}" ]]; then
    echo "ERROR: Run ./scripts/setup.sh to prepare the gateway runtime and service key." >&2
    exit 1
  fi
  if ! is_running "$GATEWAY_PID_FILE"; then
    nohup "$python" -m uvicorn services.gateway:create_app --factory --host 127.0.0.1 \
      --port "${GATEWAY_PORT:-8787}" --workers 1 --no-access-log >> "$LOG_DIR/gateway.log" 2>&1 &
    echo $! > "$GATEWAY_PID_FILE"
    sleep 1
    if ! is_running "$GATEWAY_PID_FILE"; then
      echo "ERROR: Gateway failed; see logs/gateway.log" >&2
      exit 1
    fi
  fi
}

start_brave() {
  if [[ -z "${BRAVE_API_KEY:-}" ]]; then
    echo "Brave MCP server: disabled (no BRAVE_API_KEY set)"
    return
  fi
  if is_running "$BRAVE_PID_FILE"; then
    echo "Brave MCP server already running (pid $(cat "$BRAVE_PID_FILE"))"
    return
  fi
  if ! command -v npx >/dev/null 2>&1; then
    echo "ERROR: npx not found; Node.js is required to run the Brave MCP server." >&2
    exit 1
  fi
  local pkg="@brave/brave-search-mcp-server"
  if [[ -n "$BRAVE_MCP_VERSION" ]]; then
    pkg="$pkg@$BRAVE_MCP_VERSION"
  fi
  echo "Starting Brave MCP server on $BRAVE_MCP_HOST:$BRAVE_MCP_PORT..."
  (
    export BRAVE_API_KEY="$BRAVE_API_KEY"
    export BRAVE_MCP_ENABLED_TOOLS="$BRAVE_MCP_ENABLED_TOOLS"
    nohup npx -y "$pkg" --transport http --host "$BRAVE_MCP_HOST" --port "$BRAVE_MCP_PORT" \
      >> "$LOG_DIR/brave-mcp.log" 2>&1 &
    echo $! > "$BRAVE_PID_FILE"
  )
  sleep 1
  echo "Brave MCP server started (pid $(cat "$BRAVE_PID_FILE")); logs at logs/brave-mcp.log"
}

stop_proc() {
  local pid_file="$1" name="$2"
  if is_running "$pid_file"; then
    local pid
    pid="$(cat "$pid_file")"
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
    echo "$name stopped (was pid $pid)"
  else
    rm -f "$pid_file"
    echo "$name not running"
  fi
}

status_proc() {
  local pid_file="$1" name="$2"
  if is_running "$pid_file"; then
    echo "$name: UP (pid $(cat "$pid_file"))"
  else
    echo "$name: DOWN"
  fi
}

case "${1:-}" in
  up)
    current_hash="$(shasum -a 256 "$ENV_FILE" | awk '{print $1}')"
    if is_running "$GATEWAY_PID_FILE" && [[ "$(cat "$RUN_DIR/stack.env.sha256" 2>/dev/null || true)" != "$current_hash" ]]; then
      echo "ERROR: .env changed while running. Run ./scripts/stack.sh down, then up." >&2
      exit 1
    fi
    start_inference
    start_openwebui
    start_brave
    printf '%s' "$current_hash" > "$RUN_DIR/stack.env.sha256"
    ;;
  down)
    stop_proc "$GATEWAY_PID_FILE" "Inference gateway"
    stop_proc "$WEBUI_PID_FILE" "Open WebUI"
    stop_proc "$BRAVE_PID_FILE" "Brave MCP server"
    ;;
  status)
    status_proc "$GATEWAY_PID_FILE" "Inference gateway"
    status_proc "$WEBUI_PID_FILE" "Open WebUI"
    if [[ -z "${BRAVE_API_KEY:-}" ]]; then
      echo "Brave MCP server: disabled (no BRAVE_API_KEY set)"
    else
      status_proc "$BRAVE_PID_FILE" "Brave MCP server"
    fi
    ;;
  *)
    echo "Usage: $0 {up|down|status}" >&2
    exit 1
    ;;
esac
