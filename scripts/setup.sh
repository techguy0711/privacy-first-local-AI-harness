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
      err "Rust (cargo) is not installed -- needed to build acp-bridge for the Xcode agent (--editors). This script will not auto-install it."
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

  # Writes $1's content to $2 ($3 = what to log) only if it differs, backing
  # up the old $2 first, so a re-run with nothing changed writes nothing and
  # leaves no new backup. Called as a plain command, never as an `if`
  # condition (bash ignores set -e there); each step also stops the script
  # itself, so a failed backup never lets the original be overwritten.
  replace_if_changed() {
    local new="$1" dest="$2" what="$3" backup
    if [[ -f "$dest" ]] && cmp -s "$new" "$dest"; then
      rm -f "$new"
      log "$dest already up to date"
      return 0
    fi
    if [[ -f "$dest" ]]; then
      backup="$dest.$(date +%Y%m%d%H%M%S).bak"
      if ! cp "$dest" "$backup"; then
        err "could not back up $dest to $backup -- left $dest unchanged"
        rm -f "$new"
        exit 1
      fi
      log "Backed up existing $dest to $backup"
    fi
    if ! cat "$new" > "$dest"; then
      err "could not write $dest"
      rm -f "$new"
      exit 1
    fi
    rm -f "$new"
    log "Wrote $dest$what"
  }

  DEST_CONFIG="$HOME/.continue/config.yaml"
  NEW_CONFIG="$(mktemp)"
  sed \
    -e "s|__SYSTEM_PROMPT_PATH__|file://$REPO_ROOT/prompts/system.md|g" \
    -e "s|__SERVER_HOST__|${SERVER_HOST:-}|g" \
    -e "s|__GATEWAY_BASE_URL__|$GATEWAY_BASE_URL/v1|g" \
    -e "s|__EDITOR_TIMEOUT_MS__|$EDITOR_TIMEOUT_MS|g" \
    "$SRC_CONFIG" > "$NEW_CONFIG"
  replace_if_changed "$NEW_CONFIG" "$DEST_CONFIG" ""

  CONTINUE_ENV_DIR="$REPO_ROOT/.continue"
  mkdir -p "$CONTINUE_ENV_DIR"
  CONTINUE_ENV_FILE="$CONTINUE_ENV_DIR/.env"
  NEW_CONTINUE_ENV="$(mktemp)"
  printf 'BRAVE_API_KEY=%s\n' "${BRAVE_API_KEY:-}" > "$NEW_CONTINUE_ENV"
  replace_if_changed "$NEW_CONTINUE_ENV" "$CONTINUE_ENV_FILE" " (BRAVE_API_KEY synced from .env; gitignored)"
  log "Remaining manual step: disable telemetry in the IDE (see docs/editors.md) -- it's an IDE toggle, not a config.yaml key."

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
    LLM_MODEL_CONTEXT = 16384$ACP_API_KEY_LINE
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
  fi
fi

cat <<EOF

Setup complete for MODE=$MODE.
  Base model:     $BASE_MODEL
  Embed model:    $EMBED_MODEL
  Chat backend:   $INFERENCE_BACKEND ($CHAT_MODEL)
  Open WebUI:     $VENV_DIR (version $OPEN_WEBUI_VERSION)

Next: ./scripts/stack.sh up
EOF
