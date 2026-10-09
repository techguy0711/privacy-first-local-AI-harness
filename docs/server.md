# Server mode — provisioning checklist

Same repo, same scripts, same configs as local mode — only `.env` differs (`MODE=server`, plus `SERVER_HOST`). This is a checklist for manually provisioning the shared machine; there's no Terraform or other IaC here by design.

## 1. Instance requirements

Target: AWS Linux with an NVIDIA GPU, or a high-memory Mac. The hard requirement is that `llama3.3:70b` plus a 16384-token context fits **entirely** in GPU memory — after setup, `ollama ps` must show `coder-server` at `100% GPU`, not a CPU/GPU split (a split silently tanks latency).

- `llama3.3:70b`'s default-quantization download is ~43GB (confirmed via `ollama.com/library/llama3.3`). Ollama has no official per-model VRAM table, but weights alone at ~43GB plus KV cache for a 16K context need comfortable headroom above that.
- **AWS**: an instance with ≥48GB of **GPU** memory on a single GPU (or a multi-GPU instance where Ollama's tensor split still keeps everything on-GPU) — e.g. `g6e.2xlarge` (1× L40S, 48GB VRAM) or `g5.12xlarge`-class if you need more headroom. Go bigger if you plan to raise `num_ctx` later (see the comment in `Modelfile.server`).
- **High-memory Mac** (Apple Silicon, unified memory): size so 70B weights + 16K context leaves comfortable headroom under total unified memory — in practice this means a Studio/Max-class machine with well above the ~48GB a single-GPU Linux box would need, since unified memory is shared with the OS and nothing else should be competing for it.
- Verify after setup with `ollama ps` — confirm `PROCESSOR` reads `100% GPU` for `coder-server`.

## 2. Security group / network rules

Expose **only** Open WebUI, and only over TLS, and only from the team's private network or VPN:

- Inbound 443/tcp from the VPN/office CIDR only (not `0.0.0.0/0`).
- No inbound rule for 11434 (Ollama) or the Brave MCP port — both stay bound to `127.0.0.1` and are only reachable from the reverse proxy running on the same box.
- Inbound 22/tcp (SSH) from the VPN/office CIDR only, for admin access.
- Outbound: 443/tcp to the Brave Search API at runtime; outbound to Ollama's model registry (and npm registry, for the Brave MCP package) only during setup — see `docs/privacy.md`.

## 3. Install (same scripts, Linux-native systemd)

```bash
git clone <this-repo> && cd <this-repo>
cp .env.example .env
# edit .env: MODE=server, BRAVE_API_KEY=..., SERVER_HOST=<the TLS hostname below>
./scripts/setup.sh
```

- Ollama: official Linux installer (`curl -fsSL https://ollama.com/install.sh | sh`) — this is systemd-managed out of the box. Default bind is already `127.0.0.1` (confirmed current default); no override needed unless something in your image sets `OLLAMA_HOST` otherwise. If it does, fix it with a drop-in, not a shell export (shell-exported vars don't reach the systemd-managed daemon):
  ```bash
  sudo systemctl edit ollama.service
  # [Service]
  # Environment="OLLAMA_HOST=127.0.0.1:11434"
  sudo systemctl daemon-reload && sudo systemctl restart ollama
  ```
- Cloud disable: `setup.sh` already merges `disable_ollama_cloud: true` into `~/.ollama/server.json` for whichever user runs it — run `setup.sh` as the same user/account that owns the `ollama` systemd service's home directory, or the setting won't apply to the service.

## 4. systemd units (Open WebUI, Brave MCP)

Ollama already ships its own unit. Open WebUI and the Brave MCP server don't — add these two. No Docker: both run fine natively via the same `uv`-managed venv and `npx` invocation `setup.sh`/`stack.sh` already use locally; Docker would only add an extra layer with no concrete benefit here.

`/etc/systemd/system/openwebui.service`:
```ini
[Unit]
Description=Open WebUI
After=network.target ollama.service

[Service]
Type=simple
User=openwebui
WorkingDirectory=/opt/coder-stack          # path to this repo on the server
EnvironmentFile=/opt/coder-stack/.env
Environment=DATA_DIR=/opt/coder-stack/data/openwebui
Environment=WEBUI_AUTH=true
Environment=DEFAULT_MODELS=coder-server:latest
Environment=RAG_EMBEDDING_ENGINE=ollama
Environment=ENABLE_RAG_HYBRID_SEARCH=false
Environment=OFFLINE_MODE=true
Environment=HF_HUB_OFFLINE=1
Environment=ENABLE_VERSION_UPDATE_CHECK=false
Environment=ENABLE_COMMUNITY_SHARING=false
Environment=DO_NOT_TRACK=true
Environment=SCARF_NO_ANALYTICS=true
Environment=ANONYMIZED_TELEMETRY=false
Environment=ENABLE_WEB_SEARCH=false
# `open-webui serve` ignores HOST/PORT env vars -- confirmed by running it;
# it's a Click CLI with its own --host/--port flags (default 0.0.0.0:8080).
# See docs/privacy.md. CLI flags are the only mechanism that actually works.
ExecStart=/opt/coder-stack/.venv/openwebui/bin/open-webui serve --host 127.0.0.1 --port 3000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
(`RAG_EMBEDDING_MODEL` and `WEBUI_SECRET_KEY` come from the `EnvironmentFile` since they're already in `.env`. `DEFAULT_MODELS` needs the `:latest` suffix -- confirmed via `GET /api/models` -- because `ollama create coder-server` with no explicit tag produces `coder-server:latest`.)

`/etc/systemd/system/brave-mcp.service`:
```ini
[Unit]
Description=Brave Search MCP server
After=network.target

[Service]
Type=simple
User=openwebui
WorkingDirectory=/opt/coder-stack
EnvironmentFile=/opt/coder-stack/.env
Environment=BRAVE_MCP_TRANSPORT=http
ExecStart=/usr/bin/npx -y @brave/brave-search-mcp-server@%BRAVE_MCP_VERSION% --transport http --host 127.0.0.1 --port 8765
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
(Replace `%BRAVE_MCP_VERSION%` with the pinned value from `.env` — systemd doesn't expand `EnvironmentFile` values inside `ExecStart`, so bake the version into the line, or wrap it in a one-line shell script that sources `.env` first.)

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now openwebui brave-mcp
```

Register the Brave MCP server in Open WebUI once, the same manual admin-panel step as local mode (Settings → Admin Settings → Integrations → Add Connection → MCP (Streamable HTTP) → `http://127.0.0.1:8765`).

## 5. TLS reverse proxy

Terminate TLS in front of Open WebUI only. Example (Caddy, for brevity — nginx works the same way):

```
<SERVER_HOST> {
    # Continue's OpenAI-compatible client
    reverse_proxy /api/* 127.0.0.1:3000

    # Xcode's "Internet Hosted" flow expects /v1/chat/completions; Open
    # WebUI's own OpenAI-compatible route is /api/chat/completions.
    handle /v1/chat/completions {
        rewrite * /api/chat/completions
        reverse_proxy 127.0.0.1:3000
    }

    # Continue's embed-role client, mapped straight to Ollama (never exposed
    # directly otherwise) since Open WebUI doesn't expose embeddings
    # externally. Network access here is already VPN-gated by the security
    # group above; add a bearer-token check in the proxy if you want
    # per-request auth on this path too.
    handle_path /ollama-embed/* {
        rewrite * /v1/embeddings
        reverse_proxy 127.0.0.1:11434
    }

    # Everything else: the normal Open WebUI chat UI
    reverse_proxy 127.0.0.1:3000
}
```

Issue the TLS cert however your team normally does (ACME/Let's Encrypt via the proxy, or an internal CA) — out of scope here beyond "terminate TLS before Open WebUI."

## 6. Editor access (per-user API keys)

- Each developer gets their own Open WebUI account and generates their own API key: Open WebUI → Settings → Account → API Keys.
- They set `OPENWEBUI_API_KEY` in their own Continue secrets file (`~/.continue/.env` or workspace `.continue/.env`) and `SERVER_HOST` in this repo's `.env` on their laptop, then run `./scripts/setup.sh --editors`.
- Xcode: "Internet Hosted" → URL `https://<SERVER_HOST>` → API Key = the same per-user `sk-...` key (see `docs/editors.md`).

## 7. Verification

- `ollama ps` → `coder-server` at `100% GPU`.
- `curl -s https://<SERVER_HOST>/v1/chat/completions -H "Authorization: Bearer sk-..." -d '{"model":"coder-server:latest","messages":[{"role":"user","content":"ping"}]}'` returns a completion (the `:latest` suffix is required here -- this goes through Open WebUI's own model registry, not Ollama directly).
- `./scripts/doctor.sh` with `MODE=server` in `.env` — same checks as local mode, run on the server itself.
- From a developer laptop with `MODE=server`: Continue chat and the Brave MCP tool both work against the proxied endpoint.
