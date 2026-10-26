#!/usr/bin/env bash
# Idempotent install/configure for the local AI coding stack. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.env"

INSTALL_EDITORS=false
for arg in "$@"; do
  case "$arg" in
    --editors) INSTALL_EDITORS=true ;;
    *) echo "Unknown argument: $arg (supported: --editors)" >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; }

if [[ ! -f "$ENV_FILE" ]]; then
  err ".env not found. Run: cp .env.example .env"
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
  *)
    err "MODE must be 'local' or 'server' in .env (got: '${MODE:-}')"
    exit 1
    ;;
esac

source "$REPO_ROOT/scripts/runtime.sh"


# --editors on macOS builds acp-bridge from a pinned upstream commit (step 8).
# Everything that would stop that build is checked up front -- an older .env,
# a missing patch, no Rust -- so it fails before the model pulls, not after.
# bin/acp-bridge.stamp records the pins, the patch hash and the installed
# binary's hash; a full match (and a binary that runs) skips the rebuild,
# which also keeps Xcode from asking "Allow acp-bridge to access Xcode?" again.
ACP_BUILD_NEEDED=false
if $INSTALL_EDITORS && [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -z "${ACP_BRIDGE_VERSION:-}" || -z "${ACP_BRIDGE_COMMIT:-}" ]]; then
    err "ACP_BRIDGE_VERSION and ACP_BRIDGE_COMMIT must both be set in .env for --editors (acp-bridge is built from that pinned commit) -- copy both lines from .env.example."
    exit 1
  fi
  ACP_BIN="$REPO_ROOT/bin/acp-bridge"
  ACP_STAMP="$REPO_ROOT/bin/acp-bridge.stamp"
  ACP_PATCH="$REPO_ROOT/editors/acp/acp-bridge.patch"
  ACP_BUILD="$REPO_ROOT/build/acp-bridge"
  if [[ ! -f "$ACP_PATCH" || ! -f "$REPO_ROOT/editors/acp/queue.patch" ]]; then
    err "An editor patch (acp-bridge.patch or queue.patch) is missing -- it is part of this repo and acp-bridge is built with it. Restore it (e.g. git checkout -- editors/acp/acp-bridge.patch) and re-run."
    exit 1
  fi
  ACP_STAMP_INPUTS="version=$ACP_BRIDGE_VERSION commit=$ACP_BRIDGE_COMMIT patch_sha256=$(cat "$ACP_PATCH" "$REPO_ROOT/editors/acp/queue.patch" | shasum -a 256 | awk '{print $1}')"
  if [[ -x "$ACP_BIN" && -f "$ACP_STAMP" ]] \
    && [[ "$(cat "$ACP_STAMP")" == "$ACP_STAMP_INPUTS bin_sha256=$(shasum -a 256 "$ACP_BIN" | awk '{print $1}')" ]] \
    && "$ACP_BIN" --version >/dev/null 2>&1; then
    ACP_BUILD_NEEDED=false
  else
    ACP_BUILD_NEEDED=true
    CARGO="$(command -v cargo || true)"
    if [[ -z "$CARGO" && -x "$HOME/.cargo/bin/cargo" ]]; then
      CARGO="$HOME/.cargo/bin/cargo"
    fi
    if [[ -z "$CARGO" ]]; then
      err "Rust (cargo) is not installed -- needed to build acp-bridge for the Xcode, Android Studio and VS Code agents (--editors). This script will not auto-install it."
      cat >&2 <<'EOF'
Install it yourself first (rustup, https://rustup.rs; Rust 1.86 or newer):
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
Then open a new terminal and re-run: ./scripts/setup.sh --editors
EOF
      exit 1
    fi
  fi
fi

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

# ---------- 1. Ollama presence/reachability ----------
if ! command -v ollama >/dev/null 2>&1; then
  err "Ollama is not installed. This script will not auto-install it."
  cat >&2 <<'EOF'
Install it yourself first:
  macOS: https://ollama.com/download  (or: brew install ollama)
  Linux: curl -fsSL https://ollama.com/install.sh | sh
Then re-run this script.
EOF
  exit 1
fi

if ! curl -fsS "$OLLAMA_BASE_URL/api/version" >/dev/null 2>&1; then
  err "Ollama is installed but not reachable at $OLLAMA_BASE_URL."
  cat >&2 <<'EOF'
Start it first:
  macOS: open the Ollama app, or run: ollama serve
  Linux: sudo systemctl start ollama
Then re-run this script.
EOF
  exit 1
fi
log "Ollama reachable at $OLLAMA_BASE_URL"

# ---------- 2. Disable Ollama Cloud (read-merge-write server.json) ----------
SERVER_JSON="$HOME/.ollama/server.json"
mkdir -p "$HOME/.ollama"

python3 - "$SERVER_JSON" <<'PYEOF'
import json, os, sys, time

path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path) as f:
        content = f.read().strip()
    if content:
        try:
            data = json.loads(content)
        except json.JSONDecodeError:
            backup = f"{path}.{int(time.time())}.bak"
            os.rename(path, backup)
            print(f"WARNING: {path} was not valid JSON; backed up to {backup}")
            data = {}

if data.get("disable_ollama_cloud") is True:
    print("Ollama Cloud already disabled in server.json")
else:
    if os.path.exists(path):
        backup = f"{path}.{int(time.time())}.bak"
        with open(path) as f:
            orig = f.read()
        with open(backup, "w") as f:
            f.write(orig)
        print(f"Backed up existing {path} to {backup}")
    data["disable_ollama_cloud"] = True
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Set disable_ollama_cloud=true in {path}")
    print("Restart Ollama for this to take effect:")
    print("  macOS: quit and reopen the Ollama app (or: killall Ollama; open -a Ollama)")
    print("  Linux: sudo systemctl restart ollama")
PYEOF

# ---------- 2b. Ollama's memory settings ----------
# Ollama runs models through llama-server, which by default keeps up to 32
# context checkpoints per conversation and an 8 GiB prompt cache in RAM. On a
# 16 GB Mac that reached 6.9 GiB and pushed it deep into swap (2026-10-17).
# llama-server reads LLAMA_ARG_* from its environment, which it inherits from
# Ollama. OLLAMA_KV_CACHE_TYPE and OLLAMA_NUM_PARALLEL are Ollama's own (FAQ):
# q8_0 halves the KV cache and its checkpoints; a second slot keeps a
# conversation's cache while Open WebUI's background tasks run in the other
# (docs/server.md). Values come from .env via runtime.sh; empty leaves the
# tool's own default.
OLLAMA_CACHE_ENV=()
for var in OLLAMA_KV_CACHE_TYPE OLLAMA_NUM_PARALLEL LLAMA_ARG_CTX_CHECKPOINTS LLAMA_ARG_CACHE_RAM; do
  if [[ -n "${!var}" ]]; then OLLAMA_CACHE_ENV+=("$var=${!var}"); fi
done
if [[ ${#OLLAMA_CACHE_ENV[@]} -gt 0 && "$(uname -s)" == "Darwin" ]]; then
  # The Ollama app takes its environment from launchd (Ollama FAQ): set it for
  # this login session, and keep a LaunchAgent that sets it again at each
  # login, since launchctl setenv doesn't survive a reboot.
  agent_cmd="" pending=false
  for kv in "${OLLAMA_CACHE_ENV[@]}"; do
    agent_cmd+="launchctl setenv ${kv%%=*} ${kv#*=}; "
    if [[ "$(launchctl getenv "${kv%%=*}")" != "${kv#*=}" ]]; then
      launchctl setenv "${kv%%=*}" "${kv#*=}"
      pending=true
    fi
  done
  agent="$HOME/Library/LaunchAgents/local-ai-harness.ollama-env.plist"
  new_agent="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local-ai-harness.ollama-env</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>${agent_cmd% }</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
)"
  if [[ "$(cat "$agent" 2>/dev/null)" != "$new_agent" ]]; then
    mkdir -p "$(dirname "$agent")"
    printf '%s\n' "$new_agent" > "$agent"
    log "Wrote $agent (sets ${OLLAMA_CACHE_ENV[*]} at login)"
  fi
  running="$(ps eww -p "$(pgrep -f 'ollama serve' | head -1)" 2>/dev/null || true)"
  for kv in "${OLLAMA_CACHE_ENV[@]}"; do
    if [[ " $running " != *" $kv "* ]]; then pending=true; fi
  done
  if $pending; then
    log "Ollama memory settings set (${OLLAMA_CACHE_ENV[*]}). Quit and reopen the Ollama app to apply them."
  else
    log "Ollama memory settings already applied (${OLLAMA_CACHE_ENV[*]})"
  fi
elif [[ "$(uname -s)" != "Darwin" ]]; then
  # The Linux service runs as the `ollama` user, whose home is not this
  # account's, so the server.json above never reaches it: Ollama Cloud is
  # switched off there with OLLAMA_NO_CLOUD (Ollama FAQ) in the service's env.
  service_env=(OLLAMA_NO_CLOUD=1 ${OLLAMA_CACHE_ENV[@]+"${OLLAMA_CACHE_ENV[@]}"})
  current="$(systemctl show ollama --property=Environment 2>/dev/null || true)"
  missing=()
  for kv in "${service_env[@]}"; do
    if [[ " ${current#Environment=} " != *" $kv "* ]]; then missing+=("$kv"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "The ollama service lacks ${missing[*]} (Ollama Cloud off, memory settings). Add them (needs sudo):"
    echo "  sudo systemctl edit ollama.service    # then under [Service]:"
    for kv in "${missing[@]}"; do echo "    Environment=\"$kv\""; done
    echo "  sudo systemctl daemon-reload && sudo systemctl restart ollama"
  else
    log "Ollama service environment already applied (${service_env[*]})"
  fi
fi

# ---------- 3. Pull models for the current mode ----------
if [[ "$MODE" == "server" ]]; then
  BASE_MODEL="llama3.3:70b"
else
  BASE_MODEL="gemma4:12b"
fi

if ! ollama show "$BASE_MODEL" >/dev/null 2>&1; then
  log "Pulling $BASE_MODEL..."
  ollama pull "$BASE_MODEL"
fi
MODELFILE="$REPO_ROOT/Modelfile.$MODE"
MODEL_HASH="$(shasum -a 256 "$MODELFILE" | awk '{print $1}')"
MODEL_STAMP="$REPO_ROOT/run/model-$MODE.sha256"
if [[ "$(cat "$MODEL_STAMP" 2>/dev/null || true)" != "$MODEL_HASH" ]] || ! ollama show "coder-$MODE" >/dev/null 2>&1; then
  ollama create "coder-$MODE" -f "$MODELFILE"
  mkdir -p "$REPO_ROOT/run"
  printf '%s' "$MODEL_HASH" > "$MODEL_STAMP"
fi
# Ollama serves both chat and embeddings.
if ! ollama show "$EMBED_MODEL" >/dev/null 2>&1; then
  ollama pull "$EMBED_MODEL"
fi

# ---------- 5. Install Open WebUI natively via uv (repo-local venv) ----------
if ! command -v uv >/dev/null 2>&1; then
  err "'uv' is not installed (needed to install Open WebUI natively). This script will not auto-install it."
  cat >&2 <<'EOF'
Install it yourself first:
  curl -LsSf https://astral.sh/uv/install.sh | sh
Then re-run this script.
EOF
  exit 1
fi

if [[ -z "${OPEN_WEBUI_VERSION:-}" ]]; then
  err "OPEN_WEBUI_VERSION is empty in .env -- set a pinned version (e.g. 0.6.31)."
  exit 1
fi

VENV_DIR="$REPO_ROOT/.venv/openwebui"
# venvs hardcode their absolute path, so one copied or moved from another
# folder/machine exists but can't run -- rebuild it (DATA_DIR lives outside it).
if [[ -d "$VENV_DIR" ]] && ! "$VENV_DIR/bin/python" -c '' >/dev/null 2>&1; then
  log "Open WebUI venv is broken (repo moved or copied?) -- rebuilding..."
  rm -rf "$VENV_DIR"
fi
# Another version gets a fresh venv too: installing over the old one keeps
# packages the new one no longer uses. data/ (chats, settings) is kept, and
# Open WebUI migrates its database on the next start.
INSTALLED_WEBUI="$("$VENV_DIR/bin/python" -c 'import importlib.metadata as m; print(m.version("open-webui"))' 2>/dev/null || true)"
if [[ -n "$INSTALLED_WEBUI" && "$INSTALLED_WEBUI" != "$OPEN_WEBUI_VERSION" ]]; then
  log "Open WebUI $INSTALLED_WEBUI -> $OPEN_WEBUI_VERSION: rebuilding the venv (data/ is kept)..."
  rm -rf "$VENV_DIR"
fi
if [[ ! -d "$VENV_DIR" ]]; then
  log "Creating Open WebUI venv at .venv/openwebui (Python 3.11)..."
  uv venv --python 3.11 "$VENV_DIR"
fi

# rapidocr, an open-webui dependency, bundles Baidu's PaddleOCR models and
# fetches more from modelscope.cn. It only serves OCR of images in PDFs
# (PDF_EXTRACT_IMAGES, off), so it is never installed: hard rule 1.
if ! uv pip install --help 2>/dev/null | grep -q -- '--excludes'; then
  err "This uv has no --excludes option (needed to leave out rapidocr). Update it: brew upgrade uv (or: uv self update)"
  exit 1
fi
UV_EXCLUDES="$(mktemp)"
printf 'rapidocr\nrapidocr-onnxruntime\n' > "$UV_EXCLUDES"
log "Installing open-webui==$OPEN_WEBUI_VERSION without rapidocr (no-op if already installed)..."
uv pip install --python "$VENV_DIR/bin/python" --excludes "$UV_EXCLUDES" "open-webui==$OPEN_WEBUI_VERSION"
rm -f "$UV_EXCLUDES"
# faster-whisper (voice input) bundles Silero's voice-activity model. It is
# not on the allowlist and never loaded (stack.sh keeps WHISPER_VAD_FILTER
# off), so it is deleted rather than left installed: hard rule 1.
if [[ -n "$(find "$VENV_DIR/lib" -path '*/faster_whisper/assets/silero_vad*.onnx' 2>/dev/null)" ]]; then
  find "$VENV_DIR/lib" -path '*/faster_whisper/assets/silero_vad*.onnx' -delete
  log "Removed faster-whisper's bundled Silero VAD model (not on the allowlist; voice input doesn't use it)"
fi

# ---------- 5b. Speech-to-text model (Open WebUI voice input) ----------
# Fetched here, once, from the pinned commit and checked file by file (pins in
# runtime.sh). At runtime Open WebUI only reads it (HF_HUB_OFFLINE=1).
if whisper_model_ok; then
  log "Whisper small (voice input) already in data/whisper/"
else
  log "Downloading Whisper small for voice input (~485 MB, $WHISPER_REPO at ${WHISPER_REVISION:0:7})..."
  WHISPER_TMP="$WHISPER_DIR.partial"
  rm -rf "$WHISPER_TMP"
  mkdir -p "$WHISPER_TMP"
  while read -r _ file; do
    curl -fL --progress-bar --retry 3 --proto '=https' -o "$WHISPER_TMP/$file" \
      "https://huggingface.co/$WHISPER_REPO/resolve/$WHISPER_REVISION/$file"
  done <<<"$WHISPER_SHA256"
  if ! whisper_model_ok "$WHISPER_TMP"; then
    rm -rf "$WHISPER_TMP"
    err "The downloaded Whisper model doesn't match the pinned SHA-256 hashes in scripts/runtime.sh -- not using it."
    exit 1
  fi
  rm -rf "$WHISPER_DIR"
  mv "$WHISPER_TMP" "$WHISPER_DIR"
fi

# ---------- 5c. Brave Search MCP server (only with BRAVE_API_KEY) ----------
# Installed here with npm ci from services/brave-mcp/package-lock.json: every
# package at an exact version, checked against its sha512, no install scripts.
# stack.sh then starts it with node and never contacts the npm registry, as
# npx did on every start.
BRAVE_DIR="$REPO_ROOT/build/brave-mcp"
BRAVE_LOCK="$REPO_ROOT/services/brave-mcp/package-lock.json"
if [[ -n "${BRAVE_API_KEY:-}" ]]; then
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    err "Node.js (node and npm) is not installed -- needed for the Brave Search MCP server, since BRAVE_API_KEY is set. This script will not auto-install it."
    echo "Install it yourself (brew install node), or leave BRAVE_API_KEY empty to skip web search, then re-run." >&2
    exit 1
  fi
  BRAVE_PINNED="$(node -p "require(process.argv[1]).packages['node_modules/@brave/brave-search-mcp-server'].version" "$BRAVE_LOCK")"
  if [[ "$BRAVE_PINNED" != "${BRAVE_MCP_VERSION:-}" ]]; then
    err "BRAVE_MCP_VERSION=${BRAVE_MCP_VERSION:-<unset>} in .env, but services/brave-mcp/package-lock.json pins $BRAVE_PINNED -- set BRAVE_MCP_VERSION=$BRAVE_PINNED in .env (an upgrade changes the lockfile)."
    exit 1
  fi
  BRAVE_STAMP="lock_sha256=$(shasum -a 256 "$BRAVE_LOCK" | awk '{print $1}')"
  if [[ "$(cat "$BRAVE_DIR/.stamp" 2>/dev/null || true)" == "$BRAVE_STAMP" \
    && -f "$BRAVE_DIR/node_modules/@brave/brave-search-mcp-server/dist/index.js" ]]; then
    log "Brave Search MCP server $BRAVE_PINNED already installed in build/brave-mcp/"
  else
    log "Installing Brave Search MCP server $BRAVE_PINNED into build/brave-mcp/ (npm ci from the pinned lockfile)..."
    rm -rf "$BRAVE_DIR"
    mkdir -p "$BRAVE_DIR"
    cp "$REPO_ROOT/services/brave-mcp/package.json" "$BRAVE_LOCK" "$BRAVE_DIR/"
    (cd "$BRAVE_DIR" && npm ci --ignore-scripts --omit=dev --no-audit --no-fund --no-update-notifier)
    printf '%s\n' "$BRAVE_STAMP" > "$BRAVE_DIR/.stamp"
  fi
fi

# ---------- 6. Generate WEBUI_SECRET_KEY if empty ----------
if [[ -z "${WEBUI_SECRET_KEY:-}" ]]; then
  log "Generating WEBUI_SECRET_KEY..."
  NEW_KEY="$(openssl rand -hex 32)"
  TMP_ENV="$(mktemp)"
  if grep -q '^WEBUI_SECRET_KEY=' "$ENV_FILE"; then
    sed "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$NEW_KEY|" "$ENV_FILE" > "$TMP_ENV"
  else
    cp "$ENV_FILE" "$TMP_ENV"
    printf 'WEBUI_SECRET_KEY=%s\n' "$NEW_KEY" >> "$TMP_ENV"
  fi
  mv "$TMP_ENV" "$ENV_FILE"
  log "WEBUI_SECRET_KEY generated and saved to .env"
else
  log "WEBUI_SECRET_KEY already set (leaving unchanged)"
fi

# A private service credential authenticates Open WebUI to the queue.
# It is never printed or copied to editor configs.
if [[ -z "${GATEWAY_SERVICE_KEY:-}" ]]; then
  NEW_KEY="$(openssl rand -hex 32)"
  TMP_ENV="$(mktemp)"
  if grep -q '^GATEWAY_SERVICE_KEY=' "$ENV_FILE"; then
    sed "s|^GATEWAY_SERVICE_KEY=.*|GATEWAY_SERVICE_KEY=$NEW_KEY|" "$ENV_FILE" > "$TMP_ENV"
  else
    cat "$ENV_FILE" > "$TMP_ENV"
    printf '\nGATEWAY_SERVICE_KEY=%s\n' "$NEW_KEY" >> "$TMP_ENV"
  fi
  chmod 600 "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
fi

# ---------- 7. Data/run/log directories ----------
# Owner-only: .env holds the keys and data/ every chat, upload and API key
# (Open WebUI's webui.db); other accounts on this machine must not read them.
mkdir -p "$REPO_ROOT/data/openwebui" "$REPO_ROOT/run" "$REPO_ROOT/logs"
chmod 700 "$REPO_ROOT/data" "$REPO_ROOT/run" "$REPO_ROOT/logs"
chmod 600 "$ENV_FILE"
# Continue is no longer set up (its repository is read-only; VS Code uses the
# ACP agent instead). Earlier --editors runs kept a copy of BRAVE_API_KEY for
# it in .continue/, the backups world-readable: remove them.
if [[ -n "$(find "$REPO_ROOT/.continue" -maxdepth 1 -type f -name '.env*' 2>/dev/null)" ]]; then
  find "$REPO_ROOT/.continue" -maxdepth 1 -type f -name '.env*' -delete
  rmdir "$REPO_ROOT/.continue" 2>/dev/null || true
  log "Removed .continue/.env and its backups (Continue's copy of BRAVE_API_KEY; Continue is no longer used)"
fi

# ---------- 8. Optional: editor setup (--editors) ----------
if $INSTALL_EDITORS; then
  # ~/.continue is outside this repo, so setup only points at what an earlier
  # run wrote there.
  if grep -qs -e 'coder-local' -e 'coder-server' "$HOME/.continue/config.yaml"; then
    log "Continue is no longer used: VS Code now runs the ACP agent printed below. Uninstall the Continue extension and delete ~/.continue/config.yaml (and its .bak copies) yourself."
  fi

  # Android Studio: its own model providers setting replaces the deprecated
  # Continue JetBrains plugin. Nothing is written to its settings; these are
  # the values to enter (see docs/editors.md).
  if [[ "$MODE" == "server" ]]; then
    cat <<EOF

Android Studio (Settings > Tools > AI > Model Providers > + > Third-Party Remote Provider):
  Description: Llama 3.3 70B (Server)
  URL:         https://$SERVER_HOST/v1
  URL Schema:  OpenAI
  API key:     your personal Open WebUI API key (sk-...)
Then Refresh, enable coder-server:latest and pick it in the model picker of the
Agent tab (right sidebar).
EOF
  else
    cat <<EOF

Android Studio (Settings > Tools > AI > Model Providers > + > Local Provider):
  Description: Gemma 4 12B (Local)
  Port:        ${GATEWAY_PORT:-8787}
Then click Refresh (coder-local:latest appears only after that; the gateway must be
running: ./scripts/stack.sh up), enable it, and pick it in the model picker of the
Agent tab (right sidebar).
EOF
  fi

  # Xcode ACP agent (macOS only -- Xcode doesn't exist elsewhere). Built from
  # source: upstream tag v$ACP_BRIDGE_VERSION (must be commit $ACP_BRIDGE_COMMIT)
  # plus editors/acp/acp-bridge.patch (Xcode tools, guarded Brave search,
  # build-and-fix loop, saved sessions -- see docs/editors.md). Pins, patch,
  # cargo and the stamp were checked at the top (ACP_BUILD_NEEDED).
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if ! $ACP_BUILD_NEEDED; then
      log "acp-bridge $ACP_BRIDGE_VERSION (+ editors/acp/acp-bridge.patch) already built at bin/acp-bridge"
    else
      log "Fetching acp-bridge v$ACP_BRIDGE_VERSION source into build/acp-bridge/ (gitignored)..."
      rm -rf "$ACP_BUILD/src"
      mkdir -p "$ACP_BUILD"
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$ACP_BRIDGE_VERSION" \
        https://github.com/BlakeHung/acp-bridge "$ACP_BUILD/src"
      ACP_HEAD="$(git -C "$ACP_BUILD/src" rev-parse HEAD)"
      if [[ "$ACP_HEAD" != "$ACP_BRIDGE_COMMIT" ]]; then
        err "acp-bridge tag v$ACP_BRIDGE_VERSION is commit $ACP_HEAD, not the pinned ACP_BRIDGE_COMMIT=$ACP_BRIDGE_COMMIT -- refusing to build."
        exit 1
      fi
      git -C "$ACP_BUILD/src" apply --whitespace=nowarn "$ACP_PATCH"
      git -C "$ACP_BUILD/src" apply --whitespace=nowarn "$REPO_ROOT/editors/acp/queue.patch"
      log "Building acp-bridge with $("$CARGO" --version) (cargo build --release --locked; needs Rust 1.86+; the first build takes a few minutes)..."
      "$CARGO" build --release --locked \
        --manifest-path "$ACP_BUILD/src/Cargo.toml" --target-dir "$ACP_BUILD/target"
      mkdir -p "$REPO_ROOT/bin"
      # Replace, never overwrite in place: macOS may kill a running acp-bridge
      # (Xcode keeps one open) whose executable file changed under it.
      rm -f "$ACP_BIN"
      cp "$ACP_BUILD/target/release/acp-bridge" "$ACP_BIN"
      printf '%s bin_sha256=%s\n' "$ACP_STAMP_INPUTS" "$(shasum -a 256 "$ACP_BIN" | awk '{print $1}')" > "$ACP_STAMP"
      log "Installed acp-bridge $ACP_BRIDGE_VERSION + patch to bin/acp-bridge (Xcode will ask to allow it again)"
    fi

    if [[ "$MODE" == "server" ]]; then
      if [[ -z "${SERVER_HOST:-}" ]]; then
        err "SERVER_HOST is empty in .env -- required in server mode (see docs/server.md)"
        exit 1
      fi
      ACP_LLM_BASE_URL="https://$SERVER_HOST/v1"
      ACP_LLM_MODEL="coder-server:latest"
      ACP_AGENT_NAME="Llama 3.3 70B (Server)"
      ACP_API_KEY_LINE=$'\n    LLM_API_KEY       = your personal Open WebUI API key (sk-...)'
    else
      ACP_LLM_BASE_URL="$GATEWAY_BASE_URL/v1"
      ACP_LLM_MODEL="coder-local"
      ACP_AGENT_NAME="Gemma 4 12B (Local)"
      ACP_API_KEY_LINE=""
    fi
    cat <<EOF

Xcode ACP agent ready at: $ACP_BIN
Register it manually in Xcode (Settings > Intelligence > Agents > Add an Agent):
  Name:        $ACP_AGENT_NAME
  Executable:  $ACP_BIN
  Interpreter: (leave empty -- Xcode sandboxes script agents, and the sandbox
               can't read a repo under ~/Downloads, ~/Desktop or ~/Documents)
  Arguments:   one argument, pasted as is (no quotes):
               $REPO_ROOT/editors/acp/config.toml
  Environment Variables:
    LLM_BASE_URL      = $ACP_LLM_BASE_URL
    LLM_MODEL         = $ACP_LLM_MODEL
    LLM_MODEL_CONTEXT = $MODEL_CONTEXT$ACP_API_KEY_LINE
    LLM_QUEUE         = 1
    LLM_TIMEOUT       = $((EDITOR_TIMEOUT_MS / 1000))
Xcode then asks "Allow acp-bridge to access Xcode?" -- once per Xcode launch and
again after every rebuild of acp-bridge. Allow it: that gives the agent Xcode's
documentation search, diagnostics and builds. If it never asks, turn on Xcode
Settings > Intelligence > Model Context Protocol. If this repo is in a protected
folder (e.g. ~/Downloads), macOS may also ask whether acp-bridge may access it --
allow that too, or the agent cannot read this repo.
Web search needs the local Brave server: set BRAVE_API_KEY in .env and run
./scripts/stack.sh up (http://${BRAVE_MCP_HOST:-127.0.0.1}:${BRAVE_MCP_PORT:-8765}/mcp); without it the agent has no web search.
Saved agent conversations: $REPO_ROOT/data/acp-bridge/
See docs/editors.md for details.
EOF

    # Android Studio agent: the same binary with editors/acp/config.android.toml,
    # for its Gradle build-and-fix loop. Needs Android Studio 2026.2.2 (Rabbit
    # 2) or later. Nothing is written to Android Studio's settings; the JSON
    # goes into its Agents page. JAVA_HOME: an app started from the Dock has
    # none, and the bundled JDK is the one Android Studio's Gradle uses.
    ACP_JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    [[ -x "$ACP_JAVA_HOME/bin/java" ]] || ACP_JAVA_HOME="<Android Studio.app>/Contents/jbr/Contents/Home"
    ACP_API_KEY_JSON=""
    [[ "$MODE" == "server" ]] && ACP_API_KEY_JSON=$',\n        "LLM_API_KEY": "your personal Open WebUI API key (sk-...)"'
    cat <<EOF

Android Studio agent (preview, Android Studio 2026.2.2 Rabbit 2 or later): same
acp-bridge, which builds with Gradle after each change and sends the compiler
errors back to the model.
  1. Settings > Tools > AI > Agents > Add via JSON..., paste:
{
  "agent_servers": {
    "$ACP_AGENT_NAME agent": {
      "command": "$ACP_BIN",
      "args": ["$REPO_ROOT/editors/acp/config.android.toml"],
      "env": {
        "LLM_BASE_URL": "$ACP_LLM_BASE_URL",
        "LLM_MODEL": "$ACP_LLM_MODEL",
        "LLM_MODEL_CONTEXT": "$MODEL_CONTEXT",
        "LLM_QUEUE": "1",
        "LLM_TIMEOUT": "$((EDITOR_TIMEOUT_MS / 1000))",
        "JAVA_HOME": "$ACP_JAVA_HOME"$ACP_API_KEY_JSON
      }
    }
  }
}
  2. Pick "$ACP_AGENT_NAME agent" in the agent window. Don't install agents from
     the registry list there: they are downloaded and talk to their own clouds.
Privacy notes and what is still unverified: docs/editors.md (Android Studio agent).
EOF

    # VS Code agent: the same binary with editors/acp/config.vscode.toml, run
    # by the ACP Client extension. Nothing is written to VS Code's settings;
    # these lines go into the user's settings.json. acp.agents replaces the
    # extension's built-in agent list (npx packages that talk to their
    # vendors' clouds).
    cat <<EOF

VS Code agent (replaces Continue): same acp-bridge, run by the "ACP Client"
extension (formulahendry.acp-client). After each change it builds the project
when it has a build and sends the errors back to the model.
  1. Install "ACP Client" (publisher formulahendry) from the Extensions view.
  2. Command Palette > "Preferences: Open User Settings (JSON)", and add inside
     the outer braces (put a comma after the setting before it):
  "acp.agents": {
    "$ACP_AGENT_NAME agent": {
      "command": "$ACP_BIN",
      "args": ["$REPO_ROOT/editors/acp/config.vscode.toml"],
      "env": {
        "LLM_BASE_URL": "$ACP_LLM_BASE_URL",
        "LLM_MODEL": "$ACP_LLM_MODEL",
        "LLM_MODEL_CONTEXT": "$MODEL_CONTEXT",
        "LLM_QUEUE": "1",
        "LLM_TIMEOUT": "$((EDITOR_TIMEOUT_MS / 1000))"$ACP_API_KEY_JSON
      }
    }
  },
  "acp.logTraffic": false,
  "telemetry.telemetryLevel": "off"
     The agent list replaces the extension's built-in agents (npx packages that
     talk to their own clouds). logTraffic off keeps prompts and code out of
     VS Code's output panel; telemetry off also stops the extension's usage events.
  3. Open "ACP Client" in the activity bar and connect to "$ACP_AGENT_NAME agent".
Saved agent conversations: $REPO_ROOT/data/acp-bridge-vscode/
Details: docs/editors.md (VS Code).
EOF
  fi
fi

# ---------- 9. Software bill of materials ----------
# CycloneDX JSON of what is installed here (Python and npm packages,
# acp-bridge and its crates, the models with their digests), for supply-chain
# review. Rewritten only when something changed.
if SBOM_MSG="$(WHISPER_REPO="$WHISPER_REPO" WHISPER_REVISION="$WHISPER_REVISION" WHISPER_SHA256="$WHISPER_SHA256" \
  "$VENV_DIR/bin/python" -I "$REPO_ROOT/scripts/sbom.py" "$REPO_ROOT/build/sbom.cdx.json")"; then
  log "SBOM: $SBOM_MSG"
else
  err "Could not write build/sbom.cdx.json (error above); doctor.sh reports it until a re-run of ./scripts/setup.sh succeeds."
fi

cat <<EOF

Setup complete for MODE=$MODE.
  Base model:     $BASE_MODEL
  Embed model:    $EMBED_MODEL
  Chat backend:   $INFERENCE_BACKEND ($CHAT_MODEL)
  Open WebUI:     $VENV_DIR (version $OPEN_WEBUI_VERSION)
  SBOM:           build/sbom.cdx.json

Next: ./scripts/stack.sh up
EOF
