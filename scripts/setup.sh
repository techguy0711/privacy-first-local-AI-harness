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
    *) echo "Unknown argument: $arg (only --editors is supported)" >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; }

if [[ ! -f "$ENV_FILE" ]]; then
  err ".env not found. Run: cp .env.example .env"
  exit 1
fi

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

# ---------- 3. Pull models for the current mode ----------
if [[ "$MODE" == "server" ]]; then
  BASE_MODEL="llama3.3:70b"
else
  BASE_MODEL="llama3.1:8b"
fi

log "Pulling $BASE_MODEL (no-op if already present)..."
ollama pull "$BASE_MODEL"

log "Pulling embedding model $EMBED_MODEL..."
ollama pull "$EMBED_MODEL"

# ---------- 4. Build the derived coder-${MODE} model ----------
MODELFILE="$REPO_ROOT/Modelfile.$MODE"
if [[ ! -f "$MODELFILE" ]]; then
  err "$MODELFILE not found in repo root"
  exit 1
fi
log "Building coder-$MODE from Modelfile.$MODE..."
ollama create "coder-$MODE" -f "$MODELFILE"

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
if [[ ! -d "$VENV_DIR" ]]; then
  log "Creating Open WebUI venv at .venv/openwebui (Python 3.11)..."
  uv venv --python 3.11 "$VENV_DIR"
fi

log "Installing open-webui==$OPEN_WEBUI_VERSION (no-op if already installed)..."
uv pip install --python "$VENV_DIR/bin/python" "open-webui==$OPEN_WEBUI_VERSION"

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

# ---------- 7. Data/run/log directories ----------
mkdir -p "$REPO_ROOT/data/openwebui" "$REPO_ROOT/run" "$REPO_ROOT/logs"

# ---------- 8. Optional: install editor configs (--editors) ----------
if $INSTALL_EDITORS; then
  log "Installing Continue config for MODE=$MODE into ~/.continue/ (--editors)..."
  mkdir -p "$HOME/.continue"

  SRC_CONFIG="$REPO_ROOT/editors/continue/config.$MODE.yaml"
  if [[ ! -f "$SRC_CONFIG" ]]; then
    err "$SRC_CONFIG not found"
    exit 1
  fi
  if [[ "$MODE" == "server" && -z "${SERVER_HOST:-}" ]]; then
    err "SERVER_HOST is empty in .env -- required in server mode for the Continue config (see docs/server.md)"
    exit 1
  fi

  DEST_CONFIG="$HOME/.continue/config.yaml"
  if [[ -f "$DEST_CONFIG" ]]; then
    BACKUP="$DEST_CONFIG.$(date +%Y%m%d%H%M%S).bak"
    cp "$DEST_CONFIG" "$BACKUP"
    log "Backed up existing $DEST_CONFIG to $BACKUP"
  fi
  sed \
    -e "s|__SYSTEM_PROMPT_PATH__|file://$REPO_ROOT/prompts/system.md|g" \
    -e "s|__SERVER_HOST__|${SERVER_HOST:-}|g" \
    "$SRC_CONFIG" > "$DEST_CONFIG"
  log "Wrote $DEST_CONFIG"

  CONTINUE_ENV_DIR="$REPO_ROOT/.continue"
  mkdir -p "$CONTINUE_ENV_DIR"
  CONTINUE_ENV_FILE="$CONTINUE_ENV_DIR/.env"
  if [[ -f "$CONTINUE_ENV_FILE" ]]; then
    cp "$CONTINUE_ENV_FILE" "$CONTINUE_ENV_FILE.$(date +%Y%m%d%H%M%S).bak"
  fi
  printf 'BRAVE_API_KEY=%s\n' "${BRAVE_API_KEY:-}" > "$CONTINUE_ENV_FILE"
  log "Wrote $CONTINUE_ENV_FILE (BRAVE_API_KEY synced from .env; gitignored)"
  log "Remaining manual step: disable telemetry in the IDE (see docs/editors.md) -- it's an IDE toggle, not a config.yaml key."

  # Xcode ACP agent (macOS only -- Xcode doesn't exist elsewhere)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -z "${ACP_BRIDGE_VERSION:-}" ]]; then
      err "ACP_BRIDGE_VERSION is empty in .env -- set a pinned version (e.g. 0.9.2)."
      exit 1
    fi
    case "$(uname -m)" in
      arm64) ACP_PLATFORM="darwin-arm64" ;;
      x86_64) ACP_PLATFORM="darwin-amd64" ;;
      *) err "Unsupported architecture for acp-bridge: $(uname -m)"; exit 1 ;;
    esac
    BIN_DIR="$REPO_ROOT/bin"
    mkdir -p "$BIN_DIR"
    ACP_BIN="$BIN_DIR/acp-bridge"
    CURRENT_ACP_VERSION=""
    if [[ -x "$ACP_BIN" ]]; then
      CURRENT_ACP_VERSION="$("$ACP_BIN" --version 2>/dev/null | awk '{print $2}')"
    fi
    if [[ "$CURRENT_ACP_VERSION" == "$ACP_BRIDGE_VERSION" ]]; then
      log "acp-bridge $ACP_BRIDGE_VERSION already installed at bin/acp-bridge"
    else
      log "Downloading acp-bridge $ACP_BRIDGE_VERSION ($ACP_PLATFORM)..."
      # Remove first: overwriting in place keeps a copied binary's quarantine
      # xattr, and macOS then kills it on launch (exit 137).
      rm -f "$ACP_BIN"
      curl -fsSL -o "$ACP_BIN" \
        "https://github.com/BlakeHung/acp-bridge/releases/download/v${ACP_BRIDGE_VERSION}/acp-bridge-${ACP_PLATFORM}"
      chmod +x "$ACP_BIN"
      log "Installed acp-bridge $ACP_BRIDGE_VERSION to bin/acp-bridge"
    fi

    if [[ "$MODE" == "server" ]]; then
      if [[ -z "${SERVER_HOST:-}" ]]; then
        err "SERVER_HOST is empty in .env -- required in server mode (see docs/server.md)"
        exit 1
      fi
      ACP_LLM_BASE_URL="https://$SERVER_HOST/api"
      ACP_LLM_MODEL="coder-server:latest"
      ACP_LLM_API_KEY_HINT="your personal Open WebUI API key (sk-...)"
    else
      ACP_LLM_BASE_URL="$OLLAMA_BASE_URL/v1"
      ACP_LLM_MODEL="coder-local"
      ACP_LLM_API_KEY_HINT="(leave unset -- not needed for local Ollama)"
    fi
    cat <<EOF

Xcode ACP agent ready at: $ACP_BIN
Register it manually in Xcode (Settings > Intelligence > Agents > Add an Agent):
  Name:        Coder ($MODE)
  Executable:  $ACP_BIN
  Interpreter: (leave empty)
  Arguments:   $REPO_ROOT/editors/acp/config.toml
  Environment Variables:
    LLM_BASE_URL      = $ACP_LLM_BASE_URL
    LLM_MODEL         = $ACP_LLM_MODEL
    LLM_MODEL_CONTEXT = 16384
    LLM_API_KEY       = $ACP_LLM_API_KEY_HINT
See docs/editors.md for details and the tool-access caveat (no Brave search or
Xcode-native tools in ACP mode -- acp-bridge brings its own file/bash/git tools).
EOF
  fi
fi

cat <<EOF

Setup complete for MODE=$MODE.
  Base model:     $BASE_MODEL
  Embed model:    $EMBED_MODEL
  Derived model:  coder-$MODE (from Modelfile.$MODE)
  Open WebUI:     $VENV_DIR (version $OPEN_WEBUI_VERSION)

Next: ./scripts/stack.sh up
EOF
