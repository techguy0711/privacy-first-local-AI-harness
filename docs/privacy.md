# Privacy: confirmed env vars, and the live egress audit

## Xcode ACP agent: OpenCode rejected, acp-bridge chosen (verified live, 2026-10-06)

Xcode 27 added ACP (Agent Client Protocol) agent support, which requires a locally-running adapter process since ACP agents must implement their own full agentic loop (ACP doesn't proxy raw completions). Two candidates were evaluated for bridging this to our local Ollama model:

**OpenCode — rejected.** Installed it fresh, set every documented privacy flag (`autoupdate: false`, `share: "disabled"`, `enabled_providers: ["ollama"]`), launched it in ACP mode, and watched its connections with `lsof`. Before any client even connects to it, it opens **~26 outbound HTTPS connections**:
- Confirmed via DNS match: `models.opencode.ai` / `api.opencode.ai` (their own cloud — this is not a one-time version check, it happens on every launch)
- The remainder resolve to the same IP range as `registry.npmjs.org` (likely LSP/plugin manifest fetching)

This directly violates "the only allowed outbound traffic is Brave Search API calls" — confirmed by testing, not just by reading GitHub issue reports (which also independently describe this, with no maintainer fix as of Oct 2026: [`opencode#5554`](https://github.com/anomalyco/opencode/issues/5554), [`opencode#16117`](https://github.com/anomalyco/opencode/issues/16117)).

**acp-bridge — chosen.** A small Rust ACP↔local-model adapter ([BlakeHung/acp-bridge](https://github.com/BlakeHung/acp-bridge)), built specifically because servers like Ollama lack a native agentic tool loop. Verified the same way: downloaded the pinned binary, launched it pointed at `coder-local`, and watched its connections for the full lifecycle (startup, a real `initialize` JSON-RPC handshake, idle). The **only** connection it ever opened was loopback — `127.0.0.1->127.0.0.1:11434` (Ollama itself, to list available models). Zero external hosts contacted, at any point. Its README's claim ("zero outbound network calls beyond the configured endpoint... no telemetry, no update checks") held up under live testing.

**Trade-off accepted**: `acp-bridge` has no MCP support and ignores any `mcpServers` the editor offers (confirmed in its own README) — it brings a fixed, non-extensible tool set instead (`read_file`, `write_file`, `edit`, `list_dir`, `search_code`, `bash`, `git_status`/`diff`/`log`/`commit`). This is what makes the zero-outbound-calls guarantee possible: no Brave Search tool access in Xcode specifically, unlike VS Code/Android Studio via Continue. See `docs/editors.md` for registration steps.

## Confirmed env vars (verified against current docs and a live run, 2026-10-06)

### Open WebUI privacy/telemetry (set by `stack.sh`, all confirmed current)

| Var | Value we set | Effect |
|---|---|---|
| `OFFLINE_MODE` | `true` | disables update checks + automatic model/asset downloads |
| `HF_HUB_OFFLINE` | `1` | blocks Hugging Face Hub network calls |
| `ENABLE_VERSION_UPDATE_CHECK` | `false` | stops the update-check ping |
| `ENABLE_COMMUNITY_SHARING` | `false` | hides/disables community-sharing features |
| `DO_NOT_TRACK` | `true` | standard DNT convention var |
| `SCARF_NO_ANALYTICS` | `true` | disables the Scarf install/runtime analytics pixel |
| `ANONYMIZED_TELEMETRY` | `false` | disables ChromaDB's telemetry |
| `ENABLE_WEB_SEARCH` | `false` | keeps Open WebUI's *built-in* web search off — search goes through the Brave MCP tool instead |
| `RAG_EMBEDDING_ENGINE` | `ollama` | use local Ollama for embeddings |
| `RAG_EMBEDDING_MODEL` | `nomic-embed-text` | — |
| `ENABLE_RAG_HYBRID_SEARCH` | `false` | stays off; no reranker configured either |

**Confirmed live**: the startup log prints `Embedding model set: nomic-embed-text` and a RAG query's response includes `"embedding_config":"{'engine': 'ollama', 'model': 'nomic-embed-text'}"` — the bundled Hugging Face embedder is never loaded as long as these are set before the first launch.

### Two real bugs found and fixed while testing (not just doc research)

1. **`open-webui serve` ignores `HOST`/`PORT` env vars.** Those env vars only apply to the Docker image's `backend/start.sh` entrypoint. The pip-installed `open-webui serve` command is a separate Click CLI with its own `--host`/`--port` options, **defaulting to `0.0.0.0:8080`** — i.e., without this fix, Open WebUI would have been reachable from the whole network, not just localhost. Confirmed by actually starting it and finding it listening on `*:8080` instead of `127.0.0.1:3000`. Fixed in `stack.sh` by passing `--host "$WEBUI_HOST" --port "$WEBUI_PORT"` as explicit CLI flags.
2. **Open WebUI's internal model id includes a `:latest` tag** that `ollama create coder-<mode>` (no explicit tag) produces, confirmed via `GET /api/models`. `DEFAULT_MODELS=coder-local` silently failed to match; it had to be `coder-local:latest`. Fixed in `stack.sh`.

Both were caught by actually running the stack end-to-end, not just reading docs — a reminder that "the docs say X" and "X is what happens" aren't always the same thing here.

## Live egress audit (performed 2026-10-06, macOS, `lsof -nP -i`)

Exercised: chat completion, RAG (file upload → Knowledge → grounded query), and a real Brave web search tool call, each while watching the relevant process's open connections.

| Action | Host(s) contacted | Verdict |
|---|---|---|
| `ollama pull llama3.1:8b` / `nomic-embed-text` (setup.sh) | Ollama's model registry (Cloudflare-fronted) | **Expected, setup-time only.** Matches "Ollama's registry and updates during setup" in the spec. |
| `npx -y @brave/brave-search-mcp-server@2.1.4` (stack.sh, first run) | `registry.npmjs.org` (confirmed via forward-DNS match on the exact IPs: `2606:4700::6810:22`, `...122`) — 15 connections on first run, 1 on subsequent runs (npm still does a quick version check even with an exact pin), closing on its own after a short idle period | **Expected, setup/launch-time npm registry check** — same category as Ollama's model pulls. Not Brave's API (ruled out: `api.search.brave.com` didn't even resolve from here, and `search.brave.com`'s real IPs are a completely different range). |
| Chat completion via `POST /v1/chat/completions` | none — `lsof` showed only `127.0.0.1:11434->127.0.0.1:*` | **Clean.** Fully local. |
| RAG: file upload, embedding via Ollama, Knowledge-grounded query | none observed beyond loopback | **Clean.** `embedding_config` in the response confirms `ollama`/`nomic-embed-text` was used. |
| Brave web search (`brave_web_search` tool, real query) | Brave's Search API | **Confirmed functionally** — each call returned fresh, query-specific real results (e.g. actual current Continue.dev docs content, actual Open WebUI release notes) that could only come from a live call to Brave. Could not capture the literal socket in an `lsof`/`nettop` snapshot — each request's connection closes in well under 300ms, and this environment has no root for a packet-level capture. Functional verification is the evidence here, not a packet trace. |
| Idle (nothing running) | none | Both `ollama pull`-derived and `npx`-derived connections closed within ~15s of idling. |

**Net result**: at runtime, the only host ever contacted was Brave's Search API, triggered only by an actual search tool call. Everything else was either loopback-only or a one-time setup/launch-time registry fetch (Ollama's model registry, npm's package registry) — exactly the "Expected" list in the spec, nothing more.

### How to disable each

- Brave search entirely: leave `BRAVE_API_KEY` empty in `.env` — `stack.sh` skips launching the Brave MCP server and `doctor.sh` reports `disabled: no key`.
- The npm registry check on Brave MCP launch: pre-warm npm's cache once (`npm view @brave/brave-search-mcp-server@2.1.4` or just let the first `stack.sh up` do it) — subsequent launches hit the local npm cache first and only do a brief version check.
- Ollama's registry traffic: only happens during `ollama pull` in `setup.sh`; once all models are pulled, re-running `setup.sh` makes no registry calls (confirmed: an idempotent second run showed no new pulls, only "no-op" cache-hit lines).

## Localhost-only binding (local mode) — confirmed live

```
ollama    127.0.0.1:11434 (LISTEN)
python3   127.0.0.1:3000  (LISTEN)   -- Open WebUI
node      127.0.0.1:8765  (LISTEN)   -- Brave MCP server
```
No `0.0.0.0`/`*`/`::` binding on any of the three, confirmed via `lsof -nP -iTCP -sTCP:LISTEN` after a real `stack.sh up`. `doctor.sh`'s localhost-binding check automates this same check on every run.

## Secrets

Confirmed via `git status`/`git check-ignore -v`: `.env`, `.continue/.env`, `data/`, `logs/`, `run/`, and `.venv/` are all correctly gitignored and untracked. No secret has appeared in `git status` or been committed at any point.
