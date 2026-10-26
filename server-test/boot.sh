#!/usr/bin/env bash
# Start of the test server (server-test/compose.yaml): what the OS and an
# administrator do on a real Linux server, in order (docs/server.md).
set -euo pipefail

# Ollama runs on the Mac, as it runs separately on a real server. This box's
# 127.0.0.1:11434, where .env expects it, forwards there.
socat TCP-LISTEN:11434,bind=127.0.0.1,fork,reuseaddr TCP:host.docker.internal:11434 &
for _ in $(seq 1 10); do
  curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
  sleep 1
done
if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  echo "ERROR: Ollama is not reachable on the Mac (127.0.0.1:11434 there). Open the Ollama app, then: docker compose restart server" >&2
  exit 1
fi

# The server's checkout, updated from the image's copy of the repo. Its .env
# and the gitignored state (data/, logs/, run/, build/, .venv/) stay.
rsync -a --delete --exclude=/.env --exclude=/.venv/ --exclude=/data/ --exclude=/logs/ \
  --exclude=/run/ --exclude=/build/ --exclude=/bin/ /opt/harness/ ~/stack/
cd ~/stack

# First start: `cp .env.example .env` and the settings of docs/server.md step 1.
if [[ ! -f .env ]]; then
  sed -e 's/^MODE=.*/MODE=server/' -e 's/^SERVER_HOST=.*/SERVER_HOST=localhost:8443/' .env.example > .env
  echo "Created .env for MODE=server (edit it with: docker compose exec server nano .env)"
fi
# Nothing from the previous start is running; its pid files could now name
# unrelated processes.
rm -f run/*.pid

stop() {
  ./scripts/stack.sh down || true
  kill $(jobs -p) 2>/dev/null || true
  exit "${1:-0}"
}
trap stop TERM INT

./scripts/setup.sh --editors
./scripts/stack.sh up

# The TLS proxy of docs/server.md step 3, the only port published.
caddy run --config server-test/Caddyfile --adapter caddyfile &
echo "Test server: https://localhost:8443/ (API: https://localhost:8443/v1)"

# Ends the container if the proxy or the Ollama forward stops.
wait -n
echo "ERROR: the TLS proxy or the Ollama forward stopped" >&2
stop 1
