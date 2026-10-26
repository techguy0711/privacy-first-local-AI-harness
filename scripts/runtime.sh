# Sourced after .env. All callers use the same backend/model/endpoint resolution.
# python3 is already a setup requirement; no installations happen here.
RUNTIME_CONFIG="$(python3 "$REPO_ROOT/services/config.py")" || exit 1
eval "$RUNTIME_CONFIG"
unset RUNTIME_CONFIG
export OLLAMA_HOST="$OLLAMA_BASE_URL"

# Upstream versions this repo is built and verified against. They live here,
# not in .env, so a git pull brings each one with the code that depends on it;
# a line for one left in an older .env is overridden (doctor.sh warns). The
# Brave MCP server is pinned by services/brave-mcp/package-lock.json.
# Open WebUI: stack.sh and the gateway are verified against this version, and
# setup.sh rebuilds the venv when it changes (data/ is kept).
OPEN_WEBUI_VERSION=0.12.3
# acp-bridge (the Xcode, Android Studio and VS Code agents, macOS only), a
# minimal Rust ACP<->local-model adapter, used instead of larger agent CLIs
# that phone home even with telemetry disabled (see docs/privacy.md). setup.sh
# --editors builds it from this tag, refuses to build unless the tag is this
# exact commit, and applies editors/acp/acp-bridge.patch + queue.patch (needs
# Rust: https://rustup.rs).
ACP_BRIDGE_VERSION=0.9.2
ACP_BRIDGE_COMMIT=abadae136c6cab4ae085c050675b16e4599ca676

# Speech-to-text for Open WebUI's voice input: OpenAI's Whisper small (MIT) in
# SYSTRAN's CTranslate2 build, pinned to a Hugging Face commit and to each
# file's SHA-256 (approved 2026-10-24). setup.sh downloads it once; Open WebUI
# then reads it from this folder and never asks the Hub (stack.sh).
WHISPER_REPO=Systran/faster-whisper-small
WHISPER_REVISION=536b0662742c02347bc0e980a01041f333bce120
WHISPER_DIR="$REPO_ROOT/data/whisper/faster-whisper-small"
WHISPER_SHA256="b55496ac7940a7ae47d2c01eab40edfd8701feec1229d9cce3b40014383fb828  config.json
3e305921506d8872816023e4c273e75d2419fb89b24da97b4fe7bce14170d671  model.bin
fb7b63191e9bb045082c79fd742a3106a12c99513ab30df4a0d47fa6cb6fd0ab  tokenizer.json
34ce3fe1c5041027b3f8d42912270993f986dbc4bb34cf27f951e34a1e453913  vocabulary.txt"

# True when every pinned file is in $1 (default: WHISPER_DIR) with its hash.
whisper_model_ok() {
  (cd "${1:-$WHISPER_DIR}" 2>/dev/null && shasum -a 256 -c --status <<<"$WHISPER_SHA256" 2>/dev/null)
}
