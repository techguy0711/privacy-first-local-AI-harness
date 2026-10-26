# CLAUDE.md

This repo is a self-hosted AI coding assistant stack (Ollama + inference gateway + Open WebUI + Brave MCP + acp-bridge agents for Xcode, Android Studio and VS Code), switchable between a local Mac and a shared server via `MODE` in `.env`. The rules below are non-negotiable for any future work here.

## Hard rules

1. **Model allowlist.** Only these models may be pulled, configured, or suggested anywhere (chat, embeddings, reranking, autocomplete, speech):
   `llama3.1:8b`, `llama3.3:70b` (Meta), `gemma4:12b` (Google DeepMind; approved 2026-10-07 as a stronger 16GB-Mac candidate), `nomic-embed-text` (Nomic), `starcoder2:3b` (BigCode, autocomplete only), Whisper small as `Systran/faster-whisper-small` (OpenAI's model in SYSTRAN's CTranslate2 build; Open WebUI speech-to-text only, pinned in `scripts/runtime.sh`; approved 2026-10-24), and our own derived `coder-local`/`coder-server`.
   No models of Chinese origin or anything derived from them (Qwen, DeepSeek incl. "R1-Distill-Llama", Yi, GLM, Baichuan, InternLM, MiniMax, Kimi, BGE, GTE). Watch for tools that default to these quietly (Continue's autocomplete docs recommended Qwen; VS Code's ACP Client extension lists Qwen Code among its built-in agents; many RAG setups default to BGE). Any addition to the allowlist needs explicit approval first.
2. **Nothing reports out.** Telemetry, analytics, update checks, and sharing features stay off in every component. At runtime the only allowed outbound traffic is Brave Search API calls. Model pulls/updates during setup are expected and documented in `docs/privacy.md`.
3. **Source code never goes into a search query.** Web search is for public information only (library/API docs, error patterns). Enforced via `prompts/system.md`, which the inference gateway adds to every chat request (Open WebUI and the IDEs), and in code by acp-bridge's guarded `web_search`.
4. **Local mode binds to loopback only** (127.0.0.1; the inference gateway also listens on ::1, the IPv6 loopback, because some clients try `localhost` as ::1 first). Ollama, Open WebUI, the gateway, and the Brave MCP server must never be reachable from the network in local mode.
5. **Secrets live only in `.env`** (gitignored). Never commit keys or hardcode them in configs — configs reference them. `.continue/.env`, the copy older `--editors` runs wrote for Continue, is gitignored too and `setup.sh` removes it.
6. **Keep it minimal.** No demo apps, sample projects, placeholder code, or extra abstractions beyond what's already built here. Ask before adding anything new.
7. **Verify against current docs** before changing how Ollama, Open WebUI, Brave's MCP server, acp-bridge, or the IDEs that run it (Xcode, Android Studio, VS Code's ACP Client) are configured — they change fast, and several of this stack's mechanisms (env var names, config schema, transport defaults) have already shifted once; see `docs/privacy.md` and `docs/editors.md` for the specific corrections found so far.
8. **Ask before** installing anything system-wide (Homebrew, Node, uv, Python) or writing outside the repo (`~/.ollama`, editor settings) — except the scripted exceptions below, which are the pre-approved mechanisms for exactly that.

## The three scripts

```
./scripts/setup.sh [--editors]   # idempotent install/config, incl. the pinned Whisper model for voice input (data/whisper/), Ollama's memory settings (OLLAMA_KV_CACHE_TYPE, OLLAMA_NUM_PARALLEL and LLAMA_ARG_* in .env: launchctl + ~/Library/LaunchAgents/local-ai-harness.ollama-env.plist on macOS; prints the systemd steps on Linux), the Brave MCP server from services/brave-mcp/package-lock.json into build/brave-mcp/ (only with BRAVE_API_KEY; npm ci, no install scripts), deletion of faster-whisper's bundled Silero VAD model (not on the allowlist), and build/sbom.cdx.json (CycloneDX, scripts/sbom.py); --editors prints the IDE registrations (Android Studio, Xcode, VS Code; nothing is written to editor settings) and, on macOS, builds bin/acp-bridge from the pinned source + editors/acp/acp-bridge.patch and queue.patch (needs Rust; never auto-installed)
./scripts/stack.sh up|down|status   # inference gateway + Open WebUI + Brave MCP server (skipped if BRAVE_API_KEY is empty); Ollama runs separately; MODE=server adds audit logs, 12-hour logins, 15-character passwords and HTTPS-only cookies unless .env overrides them (docs/compliance.md)
./scripts/doctor.sh               # PASS/FAIL per check; exits non-zero on any failure
```

Re-running `setup.sh` must change nothing on a second run. Changing `MODE` in `.env` must switch the model everywhere with no code changes.

`server-test/` runs `MODE=server` on a Mac for testing: a Debian container that runs these scripts as a server administrator would, behind Caddy on https://localhost:8443/, with Ollama on the Mac and `coder-server` built on `llama3.1:8b` (`server-test/Modelfile.server`). It is not a deployment method; see `docs/server.md`, "Test server mode on a Mac".
