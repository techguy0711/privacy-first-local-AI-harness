# Sourced after .env. All callers use the same backend/model/endpoint resolution.
# python3 is already a setup requirement; no installations happen here.
RUNTIME_CONFIG="$(python3 "$REPO_ROOT/services/config.py")" || exit 1
eval "$RUNTIME_CONFIG"
unset RUNTIME_CONFIG
export OLLAMA_HOST="$OLLAMA_BASE_URL"
