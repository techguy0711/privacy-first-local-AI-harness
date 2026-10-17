# Privacy: confirmed env vars, and the live egress audit

## Xcode ACP agent: OpenCode rejected, acp-bridge chosen (verified live, 2026-10-06)

Xcode 27 added ACP (Agent Client Protocol) agent support, which requires a locally-running adapter process since ACP agents must implement their own full agentic loop (ACP doesn't proxy raw completions). Two candidates were evaluated for bridging this to our local Ollama model:

**OpenCode — rejected.** Installed it fresh, set every documented privacy flag (`autoupdate: false`, `share: "disabled"`, `enabled_providers: ["ollama"]`), launched it in ACP mode, and watched its connections with `lsof`. Before any client even connects to it, it opens **~26 outbound HTTPS connections**:
- Confirmed via DNS match: `models.opencode.ai` / `api.opencode.ai` (their own cloud — this is not a one-time version check, it happens on every launch)
- The remainder resolve to the same IP range as `registry.npmjs.org` (likely LSP/plugin manifest fetching)

This directly violates "the only allowed outbound traffic is Brave Search API calls" — confirmed by testing, not just by reading GitHub issue reports (which also independently describe this, with no maintainer fix as of Oct 2026: [`opencode#5554`](https://github.com/anomalyco/opencode/issues/5554), [`opencode#16117`](https://github.com/anomalyco/opencode/issues/16117)).

**acp-bridge — chosen.** A small Rust ACP↔local-model adapter ([BlakeHung/acp-bridge](https://github.com/BlakeHung/acp-bridge)), built specifically because servers like Ollama lack a native agentic tool loop. Verified the same way: downloaded the pinned binary, launched it pointed at `coder-local`, and watched its connections for the full lifecycle (startup, a real `initialize` JSON-RPC handshake, idle). The **only** connection it ever opened was loopback — `127.0.0.1->127.0.0.1:11434` (Ollama itself, to list available models). Zero external hosts contacted, at any point. Its README's claim ("zero outbound network calls beyond the configured endpoint... no telemetry, no update checks") held up under live testing.

**Trade-off accepted then**: upstream 0.9.2 has no MCP support and ignores any `mcpServers` the editor offers — a fixed tool set (`read_file`, `write_file`, `edit`, `list_dir`, `search_code`, `bash`, `git_status`/`diff`/`log`/`commit`), so no Brave search and none of Xcode's own tools. Since 2026-10-11 `setup.sh --editors` builds 0.9.2 from source with `editors/acp/acp-bridge.patch`, which adds a small MCP client for exactly those two; the next section covers what that changes. See `docs/editors.md` for registration steps.

## Xcode agent (patched acp-bridge): what can leave the Mac

- **acp-bridge's own traffic stays Brave-only.** acp-bridge itself talks only to the model endpoint and to MCP servers on loopback (`127.0.0.1`, `::1`, `localhost` — checked in code; `HTTP(S)_PROXY`/`ALL_PROXY` are ignored; no redirects off the endpoint's origin). Its one built-in path off the Mac is the guarded `web_search` tool: acp-bridge → the Brave server `stack.sh` starts on `127.0.0.1:8765` (which holds the key) → Brave's Search API, the same path Open WebUI and Continue use. Every query is checked in code before it goes out (refused if it holds code, paths, file names, URLs, key-like strings or names declared in the project; at most 12 words), capped at 3 per turn and 20 per conversation, and logged (`web_search query=...`). acp-bridge's own `web_fetch` stays off (no `LLM_WEB_ALLOWLIST`).
- **Not covered by that: the `bash` tool.** As in upstream acp-bridge, the model's `bash` tool runs any shell command it writes, in the project folder, with no sandbox and no confirmation step (Xcode shows each command as it runs). A `curl`/`wget`, `git clone`/`fetch`/`pull`/`push`, or a package install run there can reach the network and does **not** pass the `web_search` guard — so for the Xcode agent, hard rules 2 and 3 rest on the model following its prompt (which forbids network commands in `bash`), not on code. Watch the commands it runs and press Stop (it kills the running command) if one reaches out. The build-and-fix loop's own builds run offline for Xcode/SwiftPM, Cargo, Gradle and Go projects (`-disableAutomaticPackageResolution`, `--disable-automatic-resolution`, `--offline`, `GOPROXY=off`); for a `package.json` project it runs the project's own `npm run build` script, which can do anything that script does.
- **xcode-tools is a local XPC bridge.** Xcode passes its tool server in `session/new` as `/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge` — per static analysis of Xcode 27 (2026-10-09) a stdio↔XPC bridge to the running Xcode with no URL or host strings of its own. acp-bridge starts it only because that canonical path is on its command allowlist (`[mcp] allowed_commands`; any other server an editor passes is ignored) and calls only the curated tools in `[mcp.tools."xcode-tools"] allow`: `DocumentationSearch`, `XcodeRefreshCodeIssuesInFile`, `BuildProject`, `XcodeGlob`. The model sees only `DocumentationSearch` (as `docs_search`), which searches a documentation database installed on the Mac — the query never leaves it. Refused in code whatever the config says: Xcode's Organizer tools that fetch crash and field-performance data from Apple's servers / App Store Connect (IDEAnalyticsKit `GetTopCrashIssues`, `GetCrashIssueLogs`, `GetTopFieldPerformanceIssues`, `GetFieldPerformanceIssueLogs`), `XcodeMessageSend`, and any other open-world tool.
- **BuildProject is Xcode's own build.** When the project's package dependencies changed, Xcode may resolve and fetch Swift packages, and with automatic signing it may contact Apple's developer services for code signing/provisioning — exactly as for a build you start in Xcode. The `xcodebuild` fallback runs with `-disableAutomaticPackageResolution` and `CODE_SIGNING_ALLOWED=NO`, so it neither fetches packages nor signs.
- **Apple analytics.** mcpbridge records a CoreAnalytics event (`com.apple.dt.Xcode.IntelligenceToolUse`: process name, Xcode build, the tool used) per tool use (unless Xcode's own telemetry is off). These stay in macOS's local analytics store and are sent to Apple only while **Share Mac Analytics** is on (System Settings → Privacy & Security → Analytics & Improvements) — keep it off. Xcode's own agent/chat telemetry (`com.apple.dt.Xcode.IntelligencePrompt`, `IntelligenceContentDownloads`, `ChatMessageTelemetry`, per the Xcode 27 binaries) is CoreAnalytics too, so the same switch covers it. `doctor.sh` reads that setting (`AutoSubmit` in `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, read-only) and prints a WARN when it's on.
- **Continue's built-in web tools are off.** Continue's own `search_web` sends queries to Continue's cloud proxy (not Brave) and `fetch_url_content` fetches arbitrary URLs; both are disabled in both Continue configs (`chatOptions.toolOverrides`), and `doctor.sh` checks the repo configs and `~/.continue/config.yaml`.
- **Saved conversations stay local.** acp-bridge stores each conversation (history, notes, metadata) under the repo's gitignored `data/acp-bridge/sessions/` so Xcode can resume it: dirs `0700`, files `0600`, the values of `LLM_API_KEY`/`BRAVE_API_KEY` and other `*_KEY`/`*_TOKEN`/`*_SECRET` env vars plus common token formats redacted before writing, deleted 30 days after last use. They do contain prompts and the source excerpts the model saw — delete the folder to clear them; `LLM_PERSIST=0` in the agent's env turns saving off.
- **Setup-time traffic** (only when `bin/acp-bridge.stamp` doesn't match the pins, the patches or the installed binary): a `git clone` of `github.com/BlakeHung/acp-bridge` at tag `v0.9.2` (built only if it is the pinned commit) and cargo's crates.io index/crate downloads (exact versions from the upstream `Cargo.lock`, `--locked`), which cargo caches in `~/.cargo/registry` (outside the repo, shared with any other Rust builds on the Mac); with the crates already cached there, the build here fetched nothing (2026-10-11). The Rust toolchain itself (1.86 or newer) is a prerequisite you install with rustup (`sh.rustup.rs`, `static.rust-lang.org`) — `setup.sh` never installs it. The local model pull is now `gemma4:12b` (Ollama's registry, as before).
- **Not yet re-audited live.** The points above come from the patch's code and its tests against mock MCP/Brave servers (non-loopback URLs never contacted, only the fixed Brave arguments sent, refused queries never arriving). A live connection audit of the patched build inside Xcode with a real Brave query, like the 2026-10-06 one below, is still to do.

## Android Studio built-in model providers (partly verified live, 2026-10-15)

The Continue JetBrains plugin was dropped (deprecated and hidden from every JetBrains IDE; see `docs/editors.md`). Android Studio Rabbit 1 | 2026.2.1 now talks to the gateway through its own **Local Provider** (or **Third-Party Remote Provider** in server mode). Method: one second `lsof` samples of Android Studio's TCP connections for 15 minutes, plus Android Studio's `idea.log`/`gemini-backend.log` and Ollama's request log.

- **Model traffic stays local.** Every prompt sent from the Agent tab with `coder-local:latest` selected went to `127.0.0.1:8787` (the gateway) and from there to Ollama. Android Studio first tries `/v1/responses`, gets 404, and falls back to `/v1/chat/completions`.
- **Android Studio's own Google traffic is separate from the model.** It keeps a connection open to Google, fetches server flags and experiment state, and downloads an Android docs index and lint jars from `maven.google.com`. With a Google account signed in to Gemini, it also sent a Gemini `RetrieveUserQuota` request while the Agent tab was in use. None of that carries prompts, but it is outbound traffic this repo can't switch off. Keep **Data Sharing** (usage statistics) off in Android Studio's settings.
- **Its built-in web search is removed (since 2026-10-17).** The agent's `web_search` runs through a Gemini model, not Brave, and the prompt alone didn't stop the local model from calling a tool like it (2 of 3 test runs). The gateway now drops web search tools that aren't Brave-backed from every chat request: the name contains "search" plus "web", "internet", "google" or "bing", and neither the name nor the description mentions Brave. The model never sees the tool, so it can't call it. Documentation and code tools (`search_android_docs`, `fetch_android_docs`, Xcode's `docs_search`, `grep_search`, …) don't match and pass through. Checked through the gateway with the local model and a tool defined like Android Studio's, not yet inside Android Studio.
- **Not verified**: whether `search_android_docs`/`fetch_android_docs` reach Google while a local provider is selected (the test's turn using them ran after the connection sampling had stopped), and whether the local provider works with the Google account signed out.

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
| `TOOL_SERVER_CONNECTIONS` | one MCP connection to `http://$BRAVE_MCP_HOST:$BRAVE_MCP_PORT/mcp`, auth none (`[]` without `BRAVE_API_KEY`) | registers the Brave MCP server as Open WebUI's only tool server, so users don't add it by hand. The key stays in the Brave process; Open WebUI only talks to it on loopback. Verified 2026-10-16 on 0.6.31: tool `server:mcp:brave` listed, and a chat with it on ran `brave_web_search` |

**Brave Search is on by default in Open WebUI chats with the chat model** (since 2026-10-16). Open WebUI has no env var for default tools, so `stack.sh up` sets the model's Tools setting (`toolIds`) in Open WebUI's database. It creates a private entry if none exists, which keeps the model visible to admins only, as before. With search on, Open WebUI first asks the model whether to search and what to search for, on every message. Unlike the Xcode agent, Open WebUI has no code-level check on that query, so hard rule 3 (no source code in searches) rests on `prompts/system.md` alone. For chats about private code, switch Brave Search off in that chat (the wrench icon in the message box).
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

- Brave search entirely: leave `BRAVE_API_KEY` empty in `.env` — `stack.sh` skips launching the Brave MCP server and `doctor.sh` reports `disabled: no key`. For the Xcode agent alone: `LLM_WEB_SEARCH=off` in its env vars in Xcode.
- The npm registry check on Brave MCP launch: pre-warm npm's cache once (`npm view @brave/brave-search-mcp-server@2.1.4` or just let the first `stack.sh up` do it) — subsequent launches hit the local npm cache first and only do a brief version check.
- Ollama's registry traffic: only happens during `ollama pull` in `setup.sh`. Each run still checks every model's manifest with the registry (`pulling manifest`) and downloads nothing while the model is unchanged (confirmed: an idempotent second run fetched no layers and left the model digests as they were). If upstream moves a tag (e.g. re-publishes `gemma4:12b`), a re-run downloads the new version and rebuilds `coder-<mode>` from it.

## Localhost-only binding (local mode) — confirmed live

```
ollama    127.0.0.1:11434 (LISTEN)
python3   127.0.0.1:3000  (LISTEN)   -- Open WebUI
node      127.0.0.1:8765  (LISTEN)   -- Brave MCP server
```
No `0.0.0.0`/`*`/`::` binding on any of the three, confirmed via `lsof -nP -iTCP -sTCP:LISTEN` after a real `stack.sh up`. `doctor.sh`'s localhost-binding check automates this same check on every run.

## Secrets

Confirmed via `git status`/`git check-ignore -v`: `.env`, `.continue/.env`, `data/`, `logs/`, `run/`, and `.venv/` are all correctly gitignored and untracked. No secret has appeared in `git status` or been committed at any point.

## Inference gateway

The gateway binds only to loopback, ignores proxy environment variables and does
not follow upstream redirects. Its destinations are fixed loopback inference and
Open WebUI authentication endpoints; clients cannot select arbitrary URLs or
models. Only text messages are accepted; remote media is refused.
It also drops web search tools that aren't Brave-backed from chat requests (see the Android Studio section above), so whatever tools an IDE offers, the model can only search through Brave.
The shared privacy/system prompt is added server-side for Ollama, followed by today's date (the gateway machine's local date, computed per request) so the model knows its training data may be out of date.

Job bodies and retained results are in RAM only, never written by the gateway.
Access logging is disabled; backend errors return a generic message rather than
prompt-bearing response bodies. Memory and retention limits are configurable.
WebUI/editor conversation storage still has its own existing retention policy.

Open WebUI forwards user identity only on requests authenticated with its private
service credential. IDE users have personal WebUI keys. The old unauthenticated
embedding proxy is removed. Public TLS and private-network access rules still
apply. No new runtime internet service or model family is enabled.
