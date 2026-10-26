#!/usr/bin/env bash
# up | down | status for the inference gateway, Open WebUI and Brave (Ollama runs separately).
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
WEBUI_PORT="${WEBUI_PORT:-3000}"
BRAVE_MCP_PORT="${BRAVE_MCP_PORT:-8765}"
BRAVE_MCP_ENABLED_TOOLS="${BRAVE_MCP_ENABLED_TOOLS:-brave_web_search brave_news_search}"

# Also sets WEBUI_HOST, BRAVE_MCP_HOST (always 127.0.0.1) and EMBED_MODEL,
# which are fixed in services/config.py, not settings.
source "$REPO_ROOT/scripts/runtime.sh"

RUN_DIR="$REPO_ROOT/run"
LOG_DIR="$REPO_ROOT/logs"
# Owner-only, for everything the services write here too: Open WebUI keeps
# every chat, upload and API key under data/.
umask 077
mkdir -p "$RUN_DIR" "$LOG_DIR" "$REPO_ROOT/data"
chmod 700 "$RUN_DIR" "$LOG_DIR" "$REPO_ROOT/data"

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
  if [[ ! -f "$WHISPER_DIR/model.bin" ]]; then
    echo "WARNING: voice input won't work until ./scripts/setup.sh downloads its model (data/whisper/)" >&2
  fi
  # Recordings that failed transcriptions left behind (nothing is in flight
  # while Open WebUI is down). New ones are deleted by services/voice_cleanup.py
  # (installed by set_webui_defaults).
  find "$REPO_ROOT/data/openwebui/cache/audio/transcriptions" -type f -delete 2>/dev/null || true
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
    # One embedding request at a time, 32 chunks each. Open WebUI otherwise
    # sends all of a document's chunks at once, and the gateway refuses more
    # than QUEUE_PER_USER per account, which failed the upload.
    export RAG_EMBEDDING_CONCURRENT_REQUESTS=1
    export RAG_EMBEDDING_BATCH_SIZE=32
    export ENABLE_RAG_HYBRID_SEARCH=false
    # Voice input (microphone and call buttons) is transcribed here by
    # faster-whisper with the model setup.sh downloaded. Given a folder it
    # never contacts the Hugging Face Hub; any other model name would need a
    # download, which HF_HUB_OFFLINE refuses. VAD stays off: it would load
    # Silero's model, bundled with faster-whisper and not on the allowlist.
    # Spoken replies use the browser's own voices (docs/privacy.md).
    export AUDIO_STT_ENGINE='' WHISPER_MODEL="$WHISPER_DIR" WHISPER_VAD_FILTER=false
    export AUDIO_TTS_ENGINE=''
    # One utterance per paragraph: per sentence (the default, "punctuation")
    # paused after every sentence while the reply was still being written.
    export AUDIO_TTS_SPLIT_ON=paragraphs
    # Titles and tags without thinking: gemma4 thinks by default, and each of
    # these took 1-2 minutes and evicted the chat from the model's cache.
    # TASK_MODEL_PARAMS reaches only Open WebUI's task calls, so chat replies
    # keep thinking; the gateway passes reasoning_effort on to Ollama, where
    # "none" turns thinking off.
    export TASK_MODEL_PARAMS='{"reasoning_effort":"none"}'
    # No suggestions: no starter prompts on a new chat (an empty list; unset
    # shows Open WebUI's built-in ones), no suggested next messages after each
    # reply (the server then skips that model call), and no completion of
    # what's being typed (already off by default).
    export DEFAULT_PROMPT_SUGGESTIONS='[]'
    export ENABLE_FOLLOW_UP_GENERATION=false
    export ENABLE_AUTOCOMPLETE_GENERATION=false
    export OFFLINE_MODE=true
    export HF_HUB_OFFLINE=1
    export ENABLE_VERSION_UPDATE_CHECK=false
    export ENABLE_COMMUNITY_SHARING=false
    export DO_NOT_TRACK=true
    export SCARF_NO_ANALYTICS=true
    export ANONYMIZED_TELEMETRY=false
    export ENABLE_WEB_SEARCH=false
    # User notification webhooks POST each reply (title and full text) to a
    # URL any user can set in their own settings: an egress path for chats.
    export ENABLE_USER_WEBHOOKS=false
    # Same-origin only. The default '*' also answers credentialed requests
    # from any origin, so a page on another local port (or another internal
    # subdomain in server mode) could read a signed-in user's chats.
    CORS_ALLOW_ORIGIN="http://$WEBUI_HOST:$WEBUI_PORT;http://localhost:$WEBUI_PORT"
    if [[ "$MODE" == "server" && -n "${SERVER_HOST:-}" ]]; then
      CORS_ALLOW_ORIGIN+=";https://$SERVER_HOST"
    fi
    export CORS_ALLOW_ORIGIN
    # Profile pictures are served from here, never by sending browsers on to
    # an outside address (Gravatar, an identity provider).
    export ENABLE_PROFILE_IMAGE_URL_FORWARDING=false
    if [[ "$MODE" == "server" ]]; then
      # IDEs reach the gateway with personal API keys, which the gateway checks
      # through /api/v1/users/user/status (needs ENABLE_USER_STATUS). Keys are
      # off by default since 0.12, and an Admin-panel change would not survive
      # a restart with ENABLE_PERSISTENT_CONFIG=false.
      export ENABLE_API_KEYS=true USER_PERMISSIONS_FEATURES_API_KEYS=true ENABLE_USER_STATUS=true
      # Shared-server defaults, each overridable in .env (docs/compliance.md):
      # - an audit log of sign-in attempts and every change (who, what, when,
      #   outcome) without request bodies, in data/openwebui/audit.log
      #   (rotated at 10 MB, never deleted); the gateway logs inference;
      # - logins that expire after 12 hours instead of 4 weeks;
      # - passwords of at least 15 characters and no other composition rules
      #   (NIST SP 800-63B), checked when one is set;
      # - login cookies sent over HTTPS only (the TLS proxy in docs/server.md).
      export AUDIT_LOG_LEVEL="${AUDIT_LOG_LEVEL:-METADATA}"
      export JWT_EXPIRES_IN="${JWT_EXPIRES_IN:-12h}"
      export ENABLE_PASSWORD_VALIDATION="${ENABLE_PASSWORD_VALIDATION:-true}"
      if [[ -z "${PASSWORD_VALIDATION_REGEX_PATTERN:-}" ]]; then
        PASSWORD_VALIDATION_REGEX_PATTERN='^.{15,}$'
        PASSWORD_VALIDATION_HINT="${PASSWORD_VALIDATION_HINT:-At least 15 characters.}"
      fi
      export PASSWORD_VALIDATION_REGEX_PATTERN PASSWORD_VALIDATION_HINT
      export WEBUI_SESSION_COOKIE_SECURE="${WEBUI_SESSION_COOKIE_SECURE:-true}"
    fi
    # Brave Search reaches Open WebUI as an MCP tool server: the local Brave
    # MCP server started below holds BRAVE_API_KEY, so Open WebUI never sees
    # the key. Set here on every start because ENABLE_PERSISTENT_CONFIG=false
    # drops connections added in Admin Settings at the next restart. Shape
    # matches the Admin Settings > External Tools form in 0.12.3; the grant
    # to user "*" lets every signed-in user turn it on per chat (a connection
    # without grants is admin-only since 0.12).
    if [[ -n "${BRAVE_API_KEY:-}" ]]; then
      printf -v TOOL_SERVER_CONNECTIONS '[{"type":"mcp","url":"http://%s:%s/mcp","path":"","auth_type":"none","key":"","config":{"enable":true,"access_grants":[{"principal_type":"user","principal_id":"*","permission":"read"}]},"info":{"id":"brave","name":"Brave Search","description":"Public web search through the local Brave MCP server"}}]' \
        "$BRAVE_MCP_HOST" "$BRAVE_MCP_PORT"
      export TOOL_SERVER_CONNECTIONS
    else
      export TOOL_SERVER_CONNECTIONS='[]'
    fi
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

# Two settings that 0.12.3 keeps only in its database, not in env vars:
# - The chat model's tools (Admin Settings > Models): Brave Search on by
#   default in new chats (off again without a key), and Open WebUI's own
#   built-in tools off. Those are ~25 tools (search of Knowledge, chats and
#   notes; calendar, automations, memory, tasks, time...) added to every chat
#   from the browser: their definitions filled most of each prompt, and the
#   model searched Knowledge that doesn't exist instead of answering, then
#   made up tools of its own. Attached files and Knowledge still reach the
#   model through Open WebUI's retrieval (the file_context capability). A
#   model with no entry yet gets a private one (no access grants), which is
#   what Open WebUI does for models without one: only admins see it.
# - services/voice_cleanup.py as an active event function (Admin Settings >
#   Functions): Open WebUI keeps every voice recording and its transcript,
#   and this deletes them as soon as they are transcribed.
# Open WebUI's own (async) APIs are used so the schema matches the pinned
# version, and only those fields change. Importing Open WebUI empties
# STATIC_DIR and refills it from the frontend build, so it gets a scratch
# STATIC_DIR (the running server's stays intact) and FROM_INIT_PY=true, which
# `open-webui serve` sets to find that build. Each step prints "<step>: ok"
# on stdout; anything else goes to the log.
set_webui_defaults() {
  local i out out_file static_tmp
  for i in $(seq 1 60); do
    curl -fsS --max-time 2 "http://$WEBUI_HOST:$WEBUI_PORT/health" >/dev/null 2>&1 && break
    sleep 1
  done
  static_tmp="$(mktemp -d)"
  out_file="$(mktemp)"
  DATA_DIR="$REPO_ROOT/data/openwebui" STATIC_DIR="$static_tmp" FROM_INIT_PY=true \
    WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" OFFLINE_MODE=true HF_HUB_OFFLINE=1 \
    CHAT_MODEL="$CHAT_MODEL" BRAVE_ON="$([[ -n "${BRAVE_API_KEY:-}" ]] && echo 1 || echo 0)" \
    VOICE_CLEANUP="$REPO_ROOT/services/voice_cleanup.py" \
    "$REPO_ROOT/.venv/openwebui/bin/python" - > "$out_file" 2>> "$LOG_DIR/openwebui.log" <<'PYEOF' || true
import asyncio, os, traceback
from open_webui.models.functions import FunctionForm, FunctionMeta, Functions
from open_webui.models.models import ModelForm, ModelMeta, ModelParams, Models
from open_webui.models.users import Users


async def default_tools():
    model_id, tool, want = os.environ['CHAT_MODEL'], 'server:mcp:brave', os.environ['BRAVE_ON'] == '1'
    model = await Models.get_model_by_id(model_id)
    if model is None:
        admin = await Users.get_super_admin_user()
        form = ModelForm(id=model_id, name=model_id, params=ModelParams(), access_grants=[],
                         meta=ModelMeta(toolIds=[tool] if want else [], capabilities={'builtin_tools': False}))
        if await Models.insert_new_model(form, admin.id if admin else '') is None:
            raise RuntimeError(f'could not add {model_id}')
    else:
        meta = model.meta.model_dump()
        tool_ids = list(meta.get('toolIds') or [])
        if want != (tool in tool_ids):
            meta['toolIds'] = tool_ids + [tool] if want else [t for t in tool_ids if t != tool]
        # Other capabilities stay as they are; a missing one counts as on.
        capabilities = meta.get('capabilities') or {}
        if capabilities.get('builtin_tools', True):
            meta['capabilities'] = {**capabilities, 'builtin_tools': False}
        if meta != model.meta.model_dump():
            # Without access_grants the update leaves the model's sharing as it is.
            form = ModelForm(**{**model.model_dump(exclude={'access_grants'}), 'meta': meta})
            if await Models.update_model_by_id(model_id, form) is None:
                raise RuntimeError(f'could not update {model_id}')


async def voice_cleanup():
    function_id = 'delete_voice_recordings'
    with open(os.environ['VOICE_CLEANUP']) as f:
        content = f.read()
    function = await Functions.get_function_by_id(function_id)
    if function is None:
        admin = await Users.get_super_admin_user()
        form = FunctionForm(id=function_id, name='Delete voice recordings', content=content,
                            meta=FunctionMeta(description='Deletes each voice recording once it is transcribed'))
        function = await Functions.insert_new_function(admin.id if admin else '', 'event', form)
    if function.content != content or not function.is_active:
        await Functions.update_function_by_id(function_id, {'content': content, 'is_active': True})


async def main():
    for name, step in (('tools', default_tools), ('voice cleanup', voice_cleanup)):
        try:
            await step()
            print(f'{name}: ok')
        except Exception:
            traceback.print_exc()

asyncio.run(main())
PYEOF
  out="$(cat "$out_file")"
  cat "$out_file" >> "$LOG_DIR/openwebui.log"
  rm -rf "$static_tmp" "$out_file"
  if [[ "$out" != *'tools: ok'* ]]; then
    echo "WARNING: could not set Open WebUI's default tools for $CHAT_MODEL; see logs/openwebui.log" >&2
  else
    echo "Open WebUI's built-in tools: off for $CHAT_MODEL"
    if [[ -n "${BRAVE_API_KEY:-}" ]]; then
      echo "Brave Search: on by default in new $CHAT_MODEL chats"
    fi
  fi
  if [[ "$out" != *'voice cleanup: ok'* ]]; then
    echo "WARNING: could not install the voice-recording cleanup in Open WebUI, so recordings are kept; see logs/openwebui.log" >&2
  else
    echo "Voice recordings: deleted as soon as they are transcribed"
  fi
}

start_inference() {
  local python="$REPO_ROOT/.venv/openwebui/bin/python"
  if [[ ! -x "$python" || -z "${GATEWAY_SERVICE_KEY:-}" ]]; then
    echo "ERROR: Run ./scripts/setup.sh to prepare the gateway runtime and service key." >&2
    exit 1
  fi
  if ! is_running "$GATEWAY_PID_FILE"; then
    # Listens on 127.0.0.1 and ::1 (loopback only); see loopback_sockets().
    nohup "$python" -m services.gateway >> "$LOG_DIR/gateway.log" 2>&1 &
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
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node not found; Node.js is required to run the Brave MCP server." >&2
    exit 1
  fi
  # Installed by setup.sh from services/brave-mcp/package-lock.json.
  local brave_dir="$REPO_ROOT/build/brave-mcp"
  local server="$brave_dir/node_modules/@brave/brave-search-mcp-server/dist/index.js"
  if [[ ! -f "$server" ]]; then
    echo "ERROR: the Brave MCP server is not installed (build/brave-mcp/). Run ./scripts/setup.sh first." >&2
    exit 1
  fi
  echo "Starting Brave MCP server on $BRAVE_MCP_HOST:$BRAVE_MCP_PORT..."
  (
    # Its own folder, not the repo: the server loads a .env from its working
    # directory (dotenv), and this repo's holds every other secret.
    cd "$brave_dir"
    # Only what it needs; the rest of .env (set -a above) stays out of it.
    nohup env -i PATH="$PATH" HOME="$HOME" BRAVE_API_KEY="$BRAVE_API_KEY" \
      BRAVE_MCP_ENABLED_TOOLS="$BRAVE_MCP_ENABLED_TOOLS" \
      node "$server" --transport http --host "$BRAVE_MCP_HOST" --port "$BRAVE_MCP_PORT" \
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
    set_webui_defaults
    printf '%s' "$current_hash" > "$RUN_DIR/stack.env.sha256"
    echo
    echo "Web UI: http://$WEBUI_HOST:$WEBUI_PORT/"
    if [[ "$MODE" == "server" && -n "${SERVER_HOST:-}" ]]; then
      echo "Team URL (through the HTTPS proxy in docs/server.md): https://$SERVER_HOST/"
    fi
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
