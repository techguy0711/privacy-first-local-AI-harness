# Privacy: what leaves the machine

Hard rule 2 ([AGENTS.md](../AGENTS.md#hard-rules)): no telemetry, analytics, update checks or sharing in any component, and at runtime no outbound traffic except Brave Search API calls. This page first sums up what the stack sends today and what keeps it that way, then gives the details for each component, and ends with the [evidence and history](#evidence-and-history): how and when each point was checked, and what changed along the way.

## Summary

### At runtime

| Component | Outside hosts | What keeps it that way |
|---|---|---|
| Ollama | none | Listens on `127.0.0.1:11434` only. Contacts its registry only when someone runs `ollama pull`. |
| Inference gateway | none | Its destinations are fixed loopback addresses (Ollama, Open WebUI's sign-in check), enforced in `services/config.py`. It ignores proxy variables, follows no redirects and never fetches an image link. |
| Open WebUI | none in normal use | Telemetry, update checks, sharing and its built-in web search are off ([settings](#settings-stacksh-starts-it-with)). Embeddings and speech-to-text run on the machine. A user can still make it fetch a URL ([below](#where-it-rests-on-people-or-network-rules)). |
| Open WebUI in the browser | none | Every page resource, fonts included, comes from Open WebUI itself. |
| Brave MCP server | `api.search.brave.com`, during a search | Holds the Brave key; Open WebUI and the agents reach Brave only through it. Installed from a pinned lockfile and started with only the variables it needs ([supply chain](#supply-chain)). |
| IDE agent (`acp-bridge`) | none of its own | Talks only to the gateway and to MCP servers on loopback, checked in code. Its web searches go through the Brave server and are filtered in code. Its `bash` tool is the exception ([below](#the-bash-tool)). |

### Where it rests on people or network rules

In these places code doesn't enforce the rule. Each is described further down.

- **The IDE agents' `bash` tool** runs any shell command the model writes, in the project folder, with no sandbox. The agent asks you before each one, but a command you allow, or one an "Always allow" prefix you saved covers, runs as written: a `curl`, a `git pull` or a package install there reaches the network without passing the search filter. The agent's prompt forbids network commands. This is the largest gap ([details](#the-bash-tool)).
- **The agents' automatic build of a `package.json` project** runs the project's own `npm run build`, which does whatever that script does ([details](#the-build-after-each-change)).
- **Search queries from Open WebUI** are kept free of source code by `prompts/system.md` alone; the IDE agents' queries are also filtered in code. Switch Brave Search off in Open WebUI chats about private code.
- **URL fetches in Open WebUI.** Any signed-in user can make the Open WebUI server fetch a public URL ([details](#user-started-url-fetches)). Only network egress rules stop that.
- **Each user's audio settings in Open WebUI** can send audio or reply text to Google, Apple or Hugging Face, and there's no admin switch for them ([details](#voice-input-and-spoken-replies)). Users keep **Default**.

### The IDEs, macOS and the browser

These contact their vendors whichever model is selected. This repo can't switch that off; the settings below limit it.

- **Xcode and macOS**: a build may resolve Swift packages and, with automatic signing, contact Apple's developer services, as for any Xcode build. Xcode's agent and tool-use analytics go to Apple only while **Share Mac Analytics** is on; `doctor.sh` warns when it is ([details](#xcode)).
- **Android Studio** fetches server flags and experiments from Google, downloads an Android docs index and lint jars, and checks a signed-in Google account's Gemini quota. Keep **Data Sharing** off ([details](#android-studio-the-agent-tab-through-the-local-provider)).
- **VS Code** checks for updates and reaches its Marketplace. The ACP Client extension's telemetry follows `telemetry.telemetryLevel`, which setup prints as `"off"` ([details](#vs-code-the-acp-client-extension)).
- **Chrome's "Google …" voices** send reply text to Google. Open WebUI lists them only while **Allow non-local voices** is on.

### During setup

`setup.sh` downloads each of these once, and only what isn't installed yet:

- models from Ollama's registry (`ollama pull`, only for a model that isn't installed);
- Open WebUI, at the version pinned in `scripts/runtime.sh`, and its Python dependencies from PyPI, through `uv`, which also downloads Python 3.11 if the Mac has none;
- Whisper small from Hugging Face, checked against pinned SHA-256 hashes ([details](#voice-input-and-spoken-replies));
- the Brave MCP server's npm packages from npm's registry, pinned to exact versions and hashes by `services/brave-mcp/package-lock.json` (only with a `BRAVE_API_KEY`);
- with `--editors` on macOS, acp-bridge's source from GitHub and its crates from crates.io, only when the pins or patches change ([details](#setup-time-traffic-for-the-agents)).

You install the prerequisites yourself (Ollama, Homebrew, uv, Node.js, Rust); `setup.sh` only checks for them.

### Not yet verified live

These points come from reading code or binaries and from tests, not from watching connections:

- the patched acp-bridge inside Xcode, with a real Brave search;
- the Android Studio agent host and VS Code's ACP Client, each running acp-bridge;
- inside Android Studio: the removal of its web search tool (checked through the gateway only), whether its Android docs tools reach Google while the Local Provider is selected, and whether the Local Provider works with the Google account signed out;
- a voice recording made in the browser.

The [release capture](#release-capture) is meant to close these.

### How to turn each off

- **Brave Search entirely**: leave `BRAVE_API_KEY` empty in `.env`. `stack.sh` then doesn't start the Brave MCP server, and `doctor.sh` reports `disabled: no key`. For an IDE agent alone: `LLM_WEB_SEARCH=off` in its environment values. For one Open WebUI chat: the wrench icon in the message box.
- **Ollama's registry**: contacted only by `ollama pull`, which `setup.sh` runs only for a model that isn't installed. A tag re-published upstream (e.g. `gemma4:12b`) changes nothing here until you pull it yourself; then rebuild the derived model on it with `ollama create coder-<mode> -f Modelfile.<mode>`.
- **Saved agent conversations**: `LLM_PERSIST=0` in the agent's environment values, or delete its folder under `data/`.

## Inference gateway

The gateway binds only to loopback (127.0.0.1 and ::1), ignores proxy environment variables and does not follow upstream redirects. Its destinations are fixed loopback inference and Open WebUI authentication endpoints; clients cannot select arbitrary URLs or models. Messages carry text, plus inline PNG, JPEG or WebP images in user messages; image links and other media are refused and never fetched ([images and files](#images-and-files)).

It drops web search tools that aren't Brave-backed from every chat request, so whatever tools an IDE offers, the model can only search through Brave. A tool is dropped when its name contains "search" plus "web", "internet", "google" or "bing", and neither the name nor the description mentions Brave. The model never sees it, so it can't call it. Documentation and code tools (`search_android_docs`, `fetch_android_docs`, Xcode's `docs_search`, `grep_search`, …) don't match and pass through.

The shared privacy/system prompt (`prompts/system.md`) is added server-side to every chat request, followed by today's date (the gateway machine's local date, computed per request) so the model knows its training data may be out of date.

Job bodies and retained results are in RAM only, never written by the gateway. Access logging is disabled; backend errors return a generic message rather than prompt-bearing response bodies. Memory and retention limits are configurable. Open WebUI and the IDE agents keep their own conversation storage, with its own retention.

Open WebUI forwards user identity only on requests authenticated with its private service credential. IDE users have personal Open WebUI keys. Public TLS and private-network access rules still apply.

## Open WebUI

### Settings `stack.sh` starts it with

Each was checked against the 0.12.3 source and in a live run (2026-10-23, [evidence](#open-webui-0123-verified-live-2026-10-23); the voice settings 2026-10-24, [voice input](#voice-input-and-spoken-replies)). `doctor.sh` checks that `stack.sh` still sets the privacy flags.

| Var | Value we set | Effect |
|---|---|---|
| `OFFLINE_MODE` | `true` | disables update checks, automatic model and asset downloads, and installs of tool and function requirements |
| `HF_HUB_OFFLINE` | `1` | blocks Hugging Face Hub network calls |
| `ENABLE_VERSION_UPDATE_CHECK` | `false` | stops the update-check ping |
| `ENABLE_COMMUNITY_SHARING` | `false` | hides/disables community-sharing features |
| `DO_NOT_TRACK` | `true` | standard DNT convention var |
| `SCARF_NO_ANALYTICS` | `true` | disables the Scarf install/runtime analytics pixel |
| `ANONYMIZED_TELEMETRY` | `false` | disables ChromaDB's telemetry |
| `ENABLE_WEB_SEARCH` | `false` | keeps Open WebUI's *built-in* web search off, and with it the model's `fetch_url` and `search_web` tools; search goes through the Brave MCP tool instead |
| `TOOL_SERVER_CONNECTIONS` | one MCP connection to `http://$BRAVE_MCP_HOST:$BRAVE_MCP_PORT/mcp`, auth none (`[]` without `BRAVE_API_KEY`) | registers the Brave MCP server as Open WebUI's only tool server, so users don't add it by hand. The key stays in the Brave process; Open WebUI only talks to it on loopback. The entry grants read access to user `*` (`config.access_grants`), because a connection without grants is admin-only |
| `ENABLE_USER_WEBHOOKS` | `false` | also the default. When on, a user can set a notification webhook URL, and Open WebUI POSTs each reply's title and full text there. Open WebUI checks the setting when sending, not only in the UI (`utils/notifications.py`), and offers the model its `notify` tool only while it is on |
| `CORS_ALLOW_ORIGIN` | Open WebUI's own origin(s): `http://$WEBUI_HOST:$WEBUI_PORT`, `http://localhost:$WEBUI_PORT`, plus `https://$SERVER_HOST` in server mode | the default, `*`, answers credentialed requests from any origin (checked live: `Access-Control-Allow-Origin` echoed a foreign origin with `Allow-Credentials: true`), so a page on another local port, or another internal subdomain in server mode, could read a signed-in user's chats with their `SameSite=Lax` cookie. The UI itself is same-origin. The Socket.IO server checks the same list (a foreign origin gets "not an accepted origin"), so the list must hold every address people open the UI with |
| `ENABLE_PROFILE_IMAGE_URL_FORWARDING` | `false` | profile pictures are served by Open WebUI instead of sending browsers on to an outside address (Gravatar, an identity provider); the default is `true` |
| `RAG_EMBEDDING_ENGINE` | `openai` | embeddings through the inference gateway's OpenAI-compatible `/v1/embeddings` (`RAG_OPENAI_API_BASE_URL`), which sends them to Ollama on loopback |
| `RAG_EMBEDDING_MODEL` | `nomic-embed-text` | — |
| `ENABLE_RAG_HYBRID_SEARCH` | `false` | stays off; no reranker configured either |
| `AUDIO_STT_ENGINE` | `''` | Open WebUI's local Whisper transcribes voice input; the other engines (OpenAI, Deepgram, Azure, Mistral, the browser's Web API) send the audio elsewhere |
| `WHISPER_MODEL` | `data/whisper/faster-whisper-small` (absolute path) | the folder `setup.sh` downloads; a folder is loaded without the Hugging Face Hub ([voice input](#voice-input-and-spoken-replies)) |
| `WHISPER_VAD_FILTER` | `false` | also the default: keeps Silero's VAD model (not on the allowlist) unloaded |
| `AUDIO_TTS_ENGINE` | `''` | also the default: spoken replies use the browser's own voices, with no server-side model |

`stack.sh` also turns on `ENABLE_FORWARD_USER_INFO_HEADERS`, so the gateway knows which user sent each request. Open WebUI 0.12.3 sends the same details (name, e-mail, role, chat ID) to tool servers too, with no per-server switch; the local Brave server doesn't pass them on (its code sends Brave only the query and its own key).

### Settings `stack.sh` keeps in Open WebUI's database

Open WebUI has no env var for these, so `stack.sh up` writes them to the chat model's entry at every start. If no entry exists, it creates a private one, which keeps the model visible to admins only.

- **Brave Search is on by default** in chats with the chat model (the model's Tools setting, `toolIds`). With search on, Open WebUI first asks the model whether to search and what to search for, on every message. Unlike the IDE agents, Open WebUI has no code-level check on that query, so hard rule 3 (no source code in searches) rests on `prompts/system.md` alone. For chats about private code, switch Brave Search off in that chat (the wrench icon in the message box).
- **Open WebUI's built-in tools are off** (the model's `builtin_tools` capability). Open WebUI 0.12 adds its own tools to every chat started in the browser, all local: search of Knowledge, chats and notes, writing notes, calendar events, scheduled automations, tasks, memory, the time, asking the user. In a test-server chat that was 23 tools, 16,400 characters of definitions (about 4,000 tokens) on every message, and asked how to build a SwiftUI split view, the model searched Knowledge that didn't exist, then wrote a made-up tool call out as its answer. Files attached to a chat and Knowledge still reach the model, through Open WebUI's retrieval (the `file_context` capability, unchanged).

### User-started URL fetches

Any signed-in user can make the Open WebUI server fetch a public URL: `#` followed by a URL in the message box, `POST /api/v1/retrieval/process/web`, the YouTube loader, and an `http(s)` image URL inside a message's content, which only Open WebUI's API produces, not the upload button ([images and files](#images-and-files)). `ENABLE_WEB_SEARCH=false` doesn't gate these, and `ENABLE_LOCAL_WEB_FETCH` (default off; the older name `ENABLE_RAG_LOCAL_WEB_FETCH` is still read) only blocks private addresses. The model's own `fetch_url` tool is offered only with web search on, so these fetches are always started by a user. They are runtime traffic other than Brave, and they rest on network egress rules rather than on this stack's settings. Still so in 0.12.3 (checked 2026-10-23).

## IDE agents (acp-bridge)

Xcode, Android Studio and VS Code run the same agent: acp-bridge 0.9.2 ([BlakeHung/acp-bridge](https://github.com/BlakeHung/acp-bridge)), built from source by `setup.sh --editors` with `editors/acp/acp-bridge.patch` and `queue.patch`, each IDE with its own config (`editors/acp/config*.toml`). Why acp-bridge and not a larger agent: [components rejected](#components-rejected). Registration steps: `docs/editors.md`.

### What acp-bridge sends

- **Only to the model endpoint and loopback.** acp-bridge talks to the model endpoint (`LLM_BASE_URL`, the gateway) and to MCP servers on loopback (`127.0.0.1`, `::1`, `localhost`), checked in code. `HTTP(S)_PROXY` and `ALL_PROXY` are ignored, and it follows no redirects off the endpoint's origin. The endpoint's certificate is checked on the Mac, against Mozilla's roots and the keychains' (or `SSL_CERT_FILE`), with no revocation lookups (OCSP, CRL) to certificate authorities (`docs/editors.md`, "Server certificates").
- **Its one path off the Mac is the guarded `web_search` tool**: acp-bridge → the Brave server `stack.sh` starts on `127.0.0.1:8765` (which holds the key) → Brave's Search API, the same path Open WebUI uses. Every query is checked in code before it goes out: refused if it holds code, paths, file names, URLs, key-like strings or names declared in the project; at most 12 words; at most 3 per turn and 20 per conversation; logged (`web_search query=...`). acp-bridge's own `web_fetch` stays off (no `LLM_WEB_ALLOWLIST`).
- **Saved conversations stay local.** acp-bridge stores each conversation (history, notes, metadata) in the repo's gitignored `data/` folder so the IDE can resume it: `data/acp-bridge/` for Xcode, `data/acp-bridge-android/` and `data/acp-bridge-vscode/` for the others. Dirs are `0700` and files `0600`; the values of `LLM_API_KEY`/`BRAVE_API_KEY` and other `*_KEY`/`*_TOKEN`/`*_SECRET` env vars, plus common token formats, are redacted before writing; each is deleted 30 days after last use. They do contain prompts and the source excerpts the model saw. Delete the folder to clear them; `LLM_PERSIST=0` in the agent's environment turns saving off.
- **Checked**: upstream 0.9.2 in a live connection audit ([evidence](#components-rejected)); the patch from its code and its tests against mock MCP and Brave servers (non-loopback URLs never contacted, only the fixed Brave arguments sent, refused queries never arriving). The patched build hasn't yet been audited live inside an IDE.

### The `bash` tool

As in upstream acp-bridge, the model's `bash` tool runs any shell command it writes, in the project folder, with no sandbox. Since 2026-10-27 the agent asks before each one: Allow, Always allow (a saved prefix such as `cargo test`), or Deny ([Approving commands](editors.md#approving-commands)). A `curl`/`wget`, `git clone`/`fetch`/`pull`/`push`, or a package install you allow can reach the network and does **not** pass the `web_search` guard. So for the agents, hard rules 2 and 3 rest on the model following its prompt (which forbids network commands in `bash`) and on you reading what you approve, not on code. Don't "Always allow" a command that can reach the network, and press Stop (it kills the running command) if one reaches out. `LLM_CONFIRM_BASH=0` removes the question and leaves only the prompt.

### The build after each change

After a turn that changed files, the agent builds the project and gives the model the errors to fix. These builds run offline for Xcode/SwiftPM, Cargo, Gradle and Go projects (`-disableAutomaticPackageResolution`, `--disable-automatic-resolution`, `--offline`, `GOPROXY=off`). For a `package.json` project it runs the project's own `npm run build` script, which can do anything that script does; some frameworks send build telemetry by default (Next.js unless `NEXT_TELEMETRY_DISABLED=1`; add it to the agent's `env` for such projects). Xcode's own build is covered under [Xcode](#xcode).

### Setup-time traffic for the agents

Only when `bin/acp-bridge.stamp` doesn't match the pins, the patches or the installed binary: a `git clone` of `github.com/BlakeHung/acp-bridge` at tag `v0.9.2` (built only if it is the pinned commit) and cargo's crates.io index and crate downloads (exact versions from the upstream `Cargo.lock`, `--locked`). Cargo caches them in `~/.cargo/registry`, outside the repo and shared with any other Rust builds on the Mac; with the crates already cached, a build fetches nothing (checked 2026-10-11). You install the Rust toolchain itself (1.86 or newer) with rustup (`sh.rustup.rs`, `static.rust-lang.org`); `setup.sh` never installs it.

### Xcode

- **xcode-tools is a local XPC bridge.** Xcode passes its tool server in `session/new` as `/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge`, which per static analysis of Xcode 27 (2026-10-09) is a stdio↔XPC bridge to the running Xcode with no URL or host strings of its own. acp-bridge starts it only because that canonical path is on its command allowlist (`[mcp] allowed_commands`; any other server an editor passes is ignored) and calls only the curated tools in `[mcp.tools."xcode-tools"] allow`: `DocumentationSearch`, `XcodeRefreshCodeIssuesInFile`, `BuildProject`, `XcodeGlob`. The model sees only `DocumentationSearch` (as `docs_search`), which searches a documentation database installed on the Mac; the query never leaves it. Refused in code whatever the config says: Xcode's Organizer tools that fetch crash and field-performance data from Apple's servers / App Store Connect (IDEAnalyticsKit `GetTopCrashIssues`, `GetCrashIssueLogs`, `GetTopFieldPerformanceIssues`, `GetFieldPerformanceIssueLogs`), `XcodeMessageSend`, and any other open-world tool.
- **BuildProject is Xcode's own build.** When the project's package dependencies changed, Xcode may resolve and fetch Swift packages, and with automatic signing it may contact Apple's developer services for code signing/provisioning, exactly as for a build you start in Xcode. The `xcodebuild` fallback runs with `-disableAutomaticPackageResolution` and `CODE_SIGNING_ALLOWED=NO`, so it neither fetches packages nor signs.
- **Apple analytics.** mcpbridge records a CoreAnalytics event (`com.apple.dt.Xcode.IntelligenceToolUse`: process name, Xcode build, the tool used) per tool use (unless Xcode's own telemetry is off). These stay in macOS's local analytics store and are sent to Apple only while **Share Mac Analytics** is on (System Settings → Privacy & Security → Analytics & Improvements); keep it off. Xcode's own agent/chat telemetry (`com.apple.dt.Xcode.IntelligencePrompt`, `IntelligenceContentDownloads`, `ChatMessageTelemetry`, per the Xcode 27 binaries) is CoreAnalytics too, so the same switch covers it. `doctor.sh` reads that setting (`AutoSubmit` in `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, read-only) and prints a WARN when it's on.

### Android Studio: the Agent tab through the Local Provider

Android Studio talks to the gateway through its own **Local Provider** (or **Third-Party Remote Provider** in server mode).

- **Model traffic stays local.** Every prompt sent from the Agent tab with `coder-local:latest` selected went to `127.0.0.1:8787` (the gateway) and from there to Ollama. Android Studio first tries `/v1/responses`, gets 404, and falls back to `/v1/chat/completions`.
- **Android Studio's own Google traffic is separate from the model.** It keeps a connection open to Google, fetches server flags and experiment state, and downloads an Android docs index and lint jars from `maven.google.com`. With a Google account signed in to Gemini, it also sent a Gemini `RetrieveUserQuota` request while the Agent tab was in use. None of that carries prompts, but it is outbound traffic this repo can't switch off. Keep **Data Sharing** (usage statistics) off in Android Studio's settings.
- **Its built-in web search is removed by the gateway** ([inference gateway](#inference-gateway)). The agent's `web_search` runs through a Gemini model, not Brave, and the prompt alone didn't stop the local model from calling a tool like it (2 of 3 test runs). Checked through the gateway with the local model and a tool defined like Android Studio's, not yet inside Android Studio.
- **Not verified**: whether `search_android_docs`/`fetch_android_docs` reach Google while a local provider is selected (the test's turn using them ran after the connection sampling had stopped), and whether the local provider works with the Google account signed out.
- **Checked** in Android Studio Rabbit 1 | 2026.2.1 (2026-10-15): one-second `lsof` samples of Android Studio's TCP connections for 15 minutes, plus Android Studio's `idea.log`/`gemini-backend.log` and Ollama's request log.

### Android Studio: the ACP agent host

Android Studio Rabbit 2 | 2026.2.2 runs an external ACP agent ("Bring Your Own Agent", which Google calls a preview); Rabbit 1 | 2026.2.1 has it behind the flag `studiobot.acp.client.enabled`. `docs/editors.md` registers `acp-bridge` there.

- **Agent process**: Android Studio starts the `command` with the `args` and `env` from `acp.json` (`~/.android/studio/agent/acp.json`; it also reads `~/.jetbrains/acp.json` and `~/.acp/acp.json`). The model traffic is acp-bridge's own, so it goes only to `LLM_BASE_URL` (the gateway) and the loopback Brave server.
- **Its agent prompt rides on every message**: for an agent that isn't Claude, Codex or Antigravity, Android Studio prepends its own agent prompt to every message (`PER_TURN_PREFIX`). The prompt holds a persona, tool rules, skills, the project structure and your own rules. It goes only to acp-bridge and from there to the gateway, so it stays on the Mac.
- **Its tools are not used**: Android Studio starts an MCP server on 127.0.0.1 (bearer token) with its agent tools and offers it in `session/new`. With `client_servers = "off"` in `editors/acp/config.android.toml`, acp-bridge ignores it (log: "Ignoring the client's MCP servers"). So none of those tools run, including the Android docs tools whose Google traffic is unverified.
- **Chat titles stay local in 2026.2.2**: Rabbit 2 titles an agent conversation from its first message on the Mac (`AcpConversationImpl.computeFallbackConversationTitle`, no model call). Rabbit 1 instead asks a model for the title (its "Fast" model slot, else the conversation's model), which could be Gemini. That was never verified there, and it's one more reason to use 2026.2.2.
- **Agent supervisor (2026.2.2), not triggered**: Android Studio sets up a "Fast"-slot model (`AgentSupervisorService`, `OneShotModelRunner`) that judges an external agent's permission requests (`session/request_permission`). If that model is Gemini, those requests (command, file) would go to Google. acp-bridge never sends a permission request (its source has none; it runs its tools itself), so the supervisor never runs for it.
- **Agent registry**: the Agents page downloads `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, the list of installable agents, with no project data. Installing an agent from that list downloads it through `npx`/`uvx`, and those agents talk to their vendors' clouds. Don't install any.
- **Reporting**: no usage-reporting calls were found in the host's own classes. The rest of Android Studio's reporting follows **Data Sharing** (keep it off).
- **Checked** from the code only (2026-10-21/22): the host's classes in `plugins/gemini/lib/aiplugin.jar` (`com.google.aiplugin.acp`, `com.google.studiobot.agentsdk.acp`, `…agentsdk.conversations`), read with the bundled `javap`, first in 2026.2.1 and then compared with 2026.2.2 (build `AI-262.10968.63`). No connection audit yet.

### VS Code: the ACP Client extension

VS Code runs acp-bridge through the **ACP Client** extension (`formulahendry.acp-client`, MIT, 0.2.0).

- **Agent process and model traffic**: the same acp-bridge as the other IDEs (`editors/acp/config.vscode.toml`), started through your login shell with `command`/`args`/`env` from `acp.agents` (arguments shell-quoted). It talks only to `LLM_BASE_URL` and the loopback Brave server. `session/new` carries the first workspace folder and no MCP servers, and the extension's file and terminal capabilities go unused: acp-bridge runs its own tools.
- **No network calls of its own** in the code read: the registry list is fetched only by the **ACP: Browse Agent Registry** command. Its 11 built-in agents start `npx …@latest` packages that talk to their vendors' clouds; the `acp.agents` setup prints replaces that list.
- **Telemetry**: `@vscode/extension-telemetry` (Application Insights) with events such as `extension/activated` (version), `chat/messageSent` (agent name and message length, no text), agent connect/disconnect (agent name, duration, error message), the shell name, and `permission/requested` / `permission/responded` for the agent's permission questions (the question's title, which for a shell command is the command itself, and the option picked). The library follows VS Code's `telemetry.telemetryLevel`, so `"off"` (printed by setup) stops them, and VS Code's own telemetry with them.
- **Local copies**: with `acp.logTraffic` on (its default) every protocol message, prompts, file contents and images included, goes to the **ACP Traffic** output panel; setup prints `"acp.logTraffic": false`. Its chat view sets a `default-src 'none'` content security policy and loads nothing remote.
- **VS Code itself** checks for updates and reaches its Marketplace, as Android Studio contacts Google. With `extensions.autoUpdate` on, a new extension version (unreviewed) installs by itself; turning it off keeps 0.2.0 until you choose to update.
- **Checked** from the source on GitHub, then the installed build (2026-10-23): `formulahendry.acp-client@0.2.0`, installed from the Marketplace into VS Code 1.141.0. The only hosts in its `dist/extension.js` are Microsoft's telemetry endpoints (`mobile.events.data.microsoft.com`, `dc.services.visualstudio.com` and other Application Insights hosts, from `@vscode/extension-telemetry`, which sends through VS Code's `createTelemetryLogger`, so `telemetry.telemetryLevel: off` gates it), `cdn.agentclientprotocol.com` (fetched only by the registry command), and documentation links. It declares no `untrustedWorkspaces` support, so VS Code runs it only in trusted folders. No live connection audit of a session yet.

## Images and files

- **Gateway**: chat requests may carry images as inline PNG, JPEG or WebP data URLs in user messages. Each is checked (valid base64, the format's file signature) and passed to Ollama as the bare data URL. GIF (Ollama answers "invalid image input"), image links (http(s), file paths) and other content types (`input_audio`, `file`) are refused, so the gateway never fetches anything. Images have their own budget, `QUEUE_MAX_IMAGE_BYTES` (16 MiB decoded per request; `0` refuses images), on top of `QUEUE_MAX_BODY_BYTES`, and like prompts they stay in RAM only until the request ends.
- **Ollama**: base64 images on `/v1/chat/completions` are in Ollama's OpenAI-compatibility docs (docs.ollama.com, read 2026-10-23); image URLs are not supported there. Checked live through the gateway: `coder-local` read the text and colors of a test screenshot sent as PNG, JPEG and WebP.
- **Open WebUI**: an uploaded image is inlined from Open WebUI's own storage as a data URL (`convert_url_images_to_base64` → `get_image_base64_from_file_id`, owner-checked), with no network. But an `http(s)` image URL inside a message's content, which only Open WebUI's API (not the upload button) produces, is downloaded by the Open WebUI server (`get_image_base64_from_url`, which refuses private addresses) before the gateway sees the request: one of the [user-started URL fetches](#user-started-url-fetches). Documents (PDF, text, code) are extracted by Open WebUI on this machine and sent as text.
- **Agents**: acp-bridge advertises image input to Xcode, Android Studio and VS Code (`supports_image = true`); an attached image is stored with the conversation under `data/` (`0600`, deleted after 30 days).
- **Audio stays out of the gateway**: Ollama 0.35 accepts `input_audio` and has `/v1/audio/transcriptions`, but neither is in its OpenAI-compatibility docs, and in a short test clip both heard "nine" as something else ("2:00", "10"). The gateway refuses audio parts. Open WebUI's voice input is transcribed by Open WebUI itself (next section).

## Voice input and spoken replies

- **Speech-to-text runs in Open WebUI, on this machine.** The microphone (dictation) and call (voice mode) buttons send the recording to Open WebUI, where faster-whisper 1.2.1 (CTranslate2, CPU, int8) transcribes it with Whisper small from `data/whisper/faster-whisper-small/`. `stack.sh` passes that folder as `WHISPER_MODEL`. Given a folder, faster-whisper loads it without asking the Hugging Face Hub, and `HF_HUB_OFFLINE=1` stays on, so any other model name (Open WebUI's default `base`, or one typed in Admin Settings > Audio) fails ("Cannot find an appropriate cached snapshot folder… outgoing traffic has been disabled") instead of downloading. The model loads on first use and stays in RAM (about 0.5 GB) until Open WebUI restarts.
- **Setup-time download**: `setup.sh` fetches the 4 files of `huggingface.co/Systran/faster-whisper-small` (OpenAI's Whisper small, MIT, converted by SYSTRAN) at commit `536b066`, with the 483 MB `model.bin` served from Hugging Face's CDN, and checks each against its SHA-256 in `scripts/runtime.sh` before using the folder. `doctor.sh` checks the hashes again. This is the same kind of traffic as Ollama's model pulls, and it happens once.
- **Recordings are deleted once transcribed.** Open WebUI 0.12.3 keeps each recording (`<id>.wav`, plus the `.mp3` it converts it to) and its transcript (`<id>.json`) in `data/openwebui/cache/audio/transcriptions/` and never deletes them; in server mode that would be every user's voice on the shared box. `stack.sh up` therefore installs `services/voice_cleanup.py` as an Open WebUI event function (Admin Settings > Functions, "Delete voice recordings") and turns it back on if an admin turned it off. Open WebUI runs it after each successful transcription with the recording's ID, and it deletes that recording's files, plus any file in the folder untouched for an hour (a failed transcription publishes no event). `stack.sh` also empties the folder before starting Open WebUI, and `doctor.sh` checks that the function is installed, active and the same as the repo's file. Audio files attached to a chat are uploads, not recordings, and are kept like other uploads.
- **Spoken replies use the browser's own voices** (`AUDIO_TTS_ENGINE` empty: the Web Speech API's `speechSynthesis`), so no model is installed for them. Open WebUI lists only the voices the browser marks as on-device (`localService`) unless **Allow non-local voices** is switched on. Chrome's "Google …" voices are network voices that send the reply text to Google.
- **Per-user settings that send data out** (Settings > Audio). These are each user's own, and Open WebUI has no admin switch for them, so they rest on users keeping **Default**:
  - Speech-to-Text Engine **Web API** uses the browser's speech recognition, which in Chrome sends the audio to Google (in Safari, to Apple unless dictation runs on-device).
  - Text-to-Speech Engine **Kokoro.js (Browser)** downloads the Kokoro-82M model and voices from `huggingface.co` into the browser, and its ONNX runtime from `cdn.jsdelivr.net`. Kokoro is not on the allowlist.
  - **Allow non-local voices**, as above.
- **Voice activity detection stays off** (`WHISPER_VAD_FILTER=false`): it would load Silero's VAD model, which ships inside faster-whisper and is not on the allowlist. `setup.sh` also deletes that model file ([supply chain](#supply-chain)).
- **Checked 2026-10-24**: a clip spoken by macOS `say` ("…add nine unit tests…") came back as "add 9 unit tests" in 2.0 s (0.4 s load) on CPU, using Open WebUI's own faster-whisper arguments, with a Python audit hook recording no connection or name lookup outside loopback. The running Open WebUI had `WHISPER_MODEL`, `AUDIO_STT_ENGINE=''` and `HF_HUB_OFFLINE=1` in its process environment. The cleanup function was checked in a throwaway Open WebUI 0.12.3 (its own temporary data folder, the real `/api/v1/audio/transcriptions` route): without the function a recording left 3 files, with it none, with no outside connections. **Not verified yet**: a recording made in the browser.

## Loopback-only binding (local mode)

```
ollama    127.0.0.1:11434 (LISTEN)
python3   127.0.0.1:3000  (LISTEN)   -- Open WebUI
node      127.0.0.1:8765  (LISTEN)   -- Brave MCP server
```

No `0.0.0.0`/`*`/`::` binding on any of the three, confirmed with `lsof -nP -iTCP -sTCP:LISTEN` after a real `stack.sh up`. `doctor.sh`'s binding check repeats this on every run: it accepts only `127.0.0.1` and `[::1]` and fails any other address, including a LAN IP, not just wildcard binds.

The inference gateway (`127.0.0.1:8787`) also listens on `[::1]:8787`, the IPv6 loopback, which is just as unreachable from the network. Android Studio connects to `localhost`. After one request timed out, its OpenAI client (OkHttp with `retryOnConnectionFailure(false)`) tried only `[::1]` and got "Connection refused" until Android Studio was restarted. `doctor.sh` checks that the gateway answers on `[::1]`.

## Supply chain

- **The Brave MCP server is installed once, from a lockfile.** `setup.sh` installs it into `build/brave-mcp/` with `npm ci --ignore-scripts` from `services/brave-mcp/package-lock.json`, which pins all 97 packages to exact versions and sha512 hashes, and `stack.sh` runs it with `node`. npm is contacted only by that install. Checked with `lsof` after `stack.sh up`: the server's only socket was its listener on `127.0.0.1:8765`.
- **It sees only its own key.** The server calls `dotenv.config()` (`dist/config.js`), which reads a `.env` from the working directory, so `stack.sh` starts it in `build/brave-mcp/`, not in the repo, with only `PATH`, `HOME`, `BRAVE_API_KEY` and `BRAVE_MCP_ENABLED_TOOLS` (checked with `ps eww`). The other values in `.env` (`WEBUI_SECRET_KEY`, `GATEWAY_SERVICE_KEY`, …) never reach it.
- **No models outside the allowlist ship in Open WebUI's venv.** `rapidocr`, an open-webui dependency, bundles Baidu's PaddleOCR models (`PP-OCRv6_det/rec`, `ch_ppocr_cls`) and points at `modelscope.cn` for more. It only serves OCR of images in PDFs (`PDF_EXTRACT_IMAGES`, off), so `setup.sh` installs Open WebUI without it (hard rule 1) and `doctor.sh` checks. Silero's VAD model, `faster_whisper/assets/silero_vad_v6.onnx` (1.2 MB), was then the only model file left in the venv (a search for `.onnx`, `.safetensors`, `.pt`, `.gguf` and similar). Open WebUI never loads it with `WHISPER_VAD_FILTER=false` (it calls plain `WhisperModel.transcribe`), and `setup.sh` deletes it after each install; `doctor.sh` fails if it is back.
- **SBOM.** `setup.sh` writes `build/sbom.cdx.json` (CycloneDX 1.6, `scripts/sbom.py`): every Python package in Open WebUI's venv, the Brave server's npm packages with their sha512, acp-bridge's commit, patches and crates, Ollama's version and each model's digest and license, and the Whisper files' SHA-256. It reads only local files and Ollama's API on loopback.

## Secrets and logs

- **Secrets**: `.env`, `.continue/.env`, `data/`, `logs/`, `run/` and `.venv/` are gitignored and untracked (checked with `git status` and `git check-ignore -v`); no secret has been committed. `.continue/.env` was a copy of `BRAVE_API_KEY` that older `--editors` runs kept for Continue, with timestamped backups readable by every account on the Mac (`0644`). `setup.sh` deletes them, and `doctor.sh` fails while any are left.
- **Audit logs** (server mode by default): the gateway writes `logs/gateway-audit.log` and Open WebUI `data/openwebui/audit.log` (`docs/compliance.md`, "Audit logs"). Neither holds prompts, code or replies, but both identify people: account IDs in the gateway's, and names, email addresses and source IPs in Open WebUI's. They stay on the server, owner-only, and are never deleted by the stack; they leave the machine only if an operator forwards them.

## Evidence and history

### Release capture

The checks below were made one change at a time between 2026-10-06 and 2026-10-26, mostly with `lsof` samples, which miss short connections, and several points are [not yet verified live](#not-yet-verified-live). Before tagging a release, run one packet capture on the release commit, with every client in use, and record the result here.

Capture everything that isn't loopback, with the sending process attached (macOS `tcpdump` on the `pktap` interface, run in a separate terminal; it needs `sudo`):

```bash
sudo tcpdump -i pktap,all -w ~/egress.pcapng 'not host 127.0.0.1 and not host ::1'
```

While it runs, on the release commit (`git rev-parse HEAD`):

1. `./scripts/stack.sh up`, then `./scripts/doctor.sh`.
2. Open WebUI in the browser: a chat with Brave Search off; one with it on, asking about a recent release of a tool; a PDF uploaded and asked about; an attached screenshot; one dictation with the microphone and one turn in call mode. Afterwards `data/openwebui/cache/audio/transcriptions/` should be empty.
3. Xcode agent: a session that edits a file, builds, and runs one `web_search`.
4. Android Studio: a prompt in the Agent tab through the Local Provider that would tempt it to search the web, and one that uses the Android docs tools; a session with the ACP agent that runs a Gradle build.
5. VS Code: an ACP Client session that runs a build.
6. Leave everything open and idle for 10 minutes, `./scripts/stack.sh down`, then stop the capture (Ctrl-C).

Read it with process names, then the names looked up:

```bash
tcpdump -nn -k NP -r ~/egress.pcapng | less
tcpdump -nn -r ~/egress.pcapng port 53
```

**Pass**: the stack's own processes (Ollama, the venv's Python running Open WebUI and the gateway, `node` running the Brave server, `acp-bridge`) reach only `api.search.brave.com`, from `node`, during searches. Any other host from them fails the release. Traffic from the IDEs and the browser to their vendors is expected; compare it with [the IDEs, macOS and the browser](#the-ides-macos-and-the-browser) and add any new host there.

Record the date, the commit and the versions in `build/sbom.cdx.json`, with a table like the ones below, and update [not yet verified live](#not-yet-verified-live) and the "Checked" notes the run covers. The capture holds everything the Mac sent in that time: keep it out of the repo and delete it once recorded.

### Open WebUI 0.12.3 (verified live, 2026-10-23)

0.6.31 (September 2025) was replaced by 0.12.3 (16 October 2026), which fixes published advisories affecting 0.6.31, among them CVE-2026-54010 (CVSS 8.3: any signed-in user could read or delete another user's uploaded files). Don't settle on a version from 0.7.0 to 0.11.3: GHSA-vpq8-f445-hcq7 (any website could take a signed-in user's session token, CVSS 8.1) is fixed only in 0.11.4.

**Method**: every setting `stack.sh` relies on was traced in the 0.12.3 source. Then a staging copy of this repo (its own `.env`, ports 3999/8797/8775, a copy of real data) ran the real `setup.sh`, `stack.sh` and `doctor.sh` on 0.12.3; the database migrated from 0.6.31's revision with users, chats and the model entry intact. Outbound traffic was recorded three ways for 18 minutes of startup, API calls, a chat, a 45-chunk document upload and a question about it, a Brave search from the UI, idle time and a restart: a Python audit hook in Open WebUI and the gateway (every socket connect, name lookup and subprocess; for this run uvloop and aiodns were off, so their connections went through Python sockets), `lsof` every 0.5 s on every process of the stack including the Node Brave server, and the browser's list of loaded resources.

| Source | Outside connections | Verdict |
|---|---|---|
| Open WebUI and gateway (39 hook events) | none: loopback only, no outside name lookups (the other events: `uname -p` and `file -b` at startup, Python's platform detection) | clean |
| Brave MCP server (`node`, lsof) | `registry.npmjs.org` when `npx` started it (the launch-time check in the 2026-10-06 audit, gone since 2026-10-25); `api.search.brave.com` (15.197.138.111:443) during the search | as expected |
| Browser, UI (237 requests) | none: everything from `127.0.0.1:3999`, fonts included | clean |

A regular account listed the Brave tool server (`server:mcp:brave`), and a chat in the UI ran `brave_web_search` and answered with a cited source.

**What 0.12.3 changed for this stack**, each handled in `stack.sh`, `setup.sh` or the gateway:
- `GET /api/v1/auths/` answers browser sessions only ("A human session is required." for an API key), so the gateway checks personal keys with `GET /api/v1/users/user/status` (needs `ENABLE_USER_STATUS`, on by default). API keys are off by default (`ENABLE_API_KEYS`, renamed from `ENABLE_API_KEY`) and non-admins also need the `features.api_keys` permission; `stack.sh` turns both on in server mode only. Checked live: a regular account's key works through the gateway, and without the permission the gateway answers 403 "Open WebUI does not allow API keys for this account".
- A tool server without access grants is admin-only, hence the grant in `TOOL_SERVER_CONNECTIONS`; the old `access_control: null` migrates to no grants.
- Open WebUI embeds a document by sending all its chunks at once (`RAG_EMBEDDING_CONCURRENT_REQUESTS=0`), which the gateway's per-account limit refuses (10 simultaneous requests from one account: 8 got 429). `stack.sh` sets one request at a time, 32 chunks each; the 45-chunk document then embedded in 3 s.
- Open WebUI's model API is async, so `stack.sh`'s default-tools step awaits it.
- `rapidocr` bundles PaddleOCR models; 0.6.31 shipped them as well (`rapidocr_onnxruntime`, PP-OCRv4). `setup.sh` now leaves it out ([supply chain](#supply-chain)).
- `ENABLE_USER_WEBHOOKS` defaults to `false` (`true` in 0.6.31); `stack.sh` sets it either way.

**New in 0.12.3, checked**: the model's built-in `fetch_url` and `search_web` tools exist only with `ENABLE_WEB_SEARCH` on, and `notify` only with user webhooks on; the version check needs `ENABLE_VERSION_UPDATE_CHECK`, the license check a `LICENSE_KEY`; tool and function requirement installs are skipped under `OFFLINE_MODE`; terminals need configured terminal servers (none). `ENABLE_FORWARD_USER_INFO_HEADERS` now also sends user details to tool servers ([settings](#settings-stacksh-starts-it-with)).

### Live egress audit (2026-10-06, macOS, `lsof -nP -i`)

This audit predates Open WebUI 0.12.3, the pinned Brave server, voice input, the VS Code and Android Studio agents, and embeddings through the gateway; the [release capture](#release-capture) replaces it.

Exercised: chat completion, RAG (file upload → Knowledge → grounded query), and a real Brave web search tool call, each while watching the relevant process's open connections.

| Action | Host(s) contacted | Verdict |
|---|---|---|
| `ollama pull llama3.1:8b` / `nomic-embed-text` (setup.sh) | Ollama's model registry (Cloudflare-fronted) | **Expected, setup-time only**, as hard rule 2 allows. |
| `npx -y @brave/brave-search-mcp-server@2.1.4` (stack.sh, first run) | `registry.npmjs.org` (confirmed via forward-DNS match on the exact IPs: `2606:4700::6810:22`, `...122`): 15 connections on first run, 1 on subsequent runs (npm still did a quick version check even with an exact pin), closing on its own after a short idle period | **Expected, a launch-time npm registry check**, the same category as Ollama's model pulls. Not Brave's API (ruled out: `api.search.brave.com` didn't even resolve from here, and `search.brave.com`'s real IPs are a completely different range). Gone since 2026-10-25: npm is contacted only by `setup.sh`. |
| Chat completion via `POST /v1/chat/completions` | none: `lsof` showed only `127.0.0.1:11434->127.0.0.1:*` | **Clean.** Fully local. |
| RAG: file upload, embedding via Ollama, Knowledge-grounded query | none observed beyond loopback | **Clean.** The startup log printed `Embedding model set: nomic-embed-text`, and the response's `embedding_config` was `{'engine': 'ollama', 'model': 'nomic-embed-text'}`: the bundled Hugging Face embedder is never loaded while these are set before the first launch. |
| Brave web search (`brave_web_search` tool, real query) | Brave's Search API | **Confirmed functionally**: each call returned fresh, query-specific real results (e.g. actual current Continue.dev docs content, actual Open WebUI release notes) that could only come from a live call to Brave. The socket itself wasn't captured: each request's connection closes in well under 300 ms, and this run had no root for a packet capture. |
| Idle (nothing running) | none | Both `ollama pull`-derived and `npx`-derived connections closed within ~15 s of idling. |

**Net result**: at runtime, the only host contacted was Brave's Search API, and only for an actual search tool call. Everything else was loopback-only or a one-time setup or launch-time registry fetch (Ollama's model registry, npm's package registry), as hard rule 2 allows.

### Components rejected

**OpenCode, as the Xcode agent (2026-10-06).** Xcode 27 added ACP (Agent Client Protocol) agent support, which needs a locally running adapter process, since ACP agents implement their own agentic loop (ACP doesn't proxy raw completions). OpenCode was installed fresh with every documented privacy flag set (`autoupdate: false`, `share: "disabled"`, `enabled_providers: ["ollama"]`), launched in ACP mode, and watched with `lsof`. Before any client even connected, it opened **~26 outbound HTTPS connections**:
- confirmed via DNS match: `models.opencode.ai` / `api.opencode.ai`, its own cloud, on every launch, not as a one-time version check;
- the rest resolved to the same IP range as `registry.npmjs.org` (likely LSP/plugin manifest fetching).

GitHub issue reports describe the same independently, with no maintainer fix as of October 2026 ([`opencode#5554`](https://github.com/anomalyco/opencode/issues/5554), [`opencode#16117`](https://github.com/anomalyco/opencode/issues/16117)).

**acp-bridge was chosen instead**, a small Rust ACP↔local-model adapter built because servers like Ollama lack a native agentic tool loop. It was verified the same way: the pinned binary, launched against `coder-local` and watched for its full lifecycle (startup, a real `initialize` JSON-RPC handshake, idle). The **only** connection it opened was loopback, `127.0.0.1->127.0.0.1:11434` (Ollama, to list the models); no external host at any point. Its README's claim ("zero outbound network calls beyond the configured endpoint... no telemetry, no update checks") held up. Upstream 0.9.2 has no MCP support and ignores the `mcpServers` an editor offers, so it had a fixed tool set (`read_file`, `write_file`, `edit`, `list_dir`, `search_code`, `bash`, `git_status`/`diff`/`log`/`commit`) with no Brave search and none of Xcode's own tools. Since 2026-10-11 `setup.sh --editors` builds it from source with `editors/acp/acp-bridge.patch`, which adds a small MCP client for exactly those two ([what acp-bridge sends](#what-acp-bridge-sends)).

**ACP Patchbay, as the VS Code client (2026-10-23).** When Continue was retired (its repository is read-only and 2.0.0 was its last release), two ACP client extensions were read on GitHub. ACP Patchbay (Apache-2.0, 0.88.3) downloads the agent registry from `cdn.agentclientprotocol.com` on every window start and every new chat, with no setting to stop it (`orchestrator.ts`: `acpRegistry.read("startup")`, `read("new-session")`), which breaks "nothing reports out". ACP Client was chosen.

### Bugs found by running the stack (2026-10-06)

Both were caught by running the stack end to end, not by reading docs.

1. **`open-webui serve` ignores the `HOST`/`PORT` env vars.** Those apply only to the Docker image's `backend/start.sh` entrypoint. The pip-installed `open-webui serve` command is a separate Click CLI with its own `--host`/`--port` options, **defaulting to `0.0.0.0:8080`**: without the fix, Open WebUI would have been reachable from the whole network. Found by starting it and seeing it listen on `*:8080` instead of `127.0.0.1:3000`. `stack.sh` passes `--host "$WEBUI_HOST" --port "$WEBUI_PORT"` explicitly.
2. **Open WebUI's internal model ID includes a `:latest` tag**, which `ollama create coder-<mode>` (no explicit tag) produces, confirmed with `GET /api/models`. `DEFAULT_MODELS=coder-local` silently failed to match; `stack.sh` uses `coder-local:latest`.

### Changes since the first audit

- **2026-10-11**: the IDE agent is built from source with `editors/acp/acp-bridge.patch` (Brave search, Xcode's tools).
- **2026-10-14**: `setup.sh` pulls a model only when it isn't installed; before, every run checked each model's manifest with Ollama's registry.
- **2026-10-16**: Brave Search on by default in Open WebUI chats with the chat model. Android Studio moved from the Continue JetBrains plugin (deprecated and hidden from every JetBrains IDE; `docs/editors.md`) to its own Local Provider.
- **2026-10-17**: the gateway drops web search tools that aren't Brave-backed.
- **2026-10-18**: `doctor.sh`'s binding check accepts only `127.0.0.1` and `[::1]`, not just "no wildcard".
- **2026-10-23**: Open WebUI 0.6.31 → 0.12.3; `ENABLE_USER_WEBHOOKS`, `CORS_ALLOW_ORIGIN` and `ENABLE_PROFILE_IMAGE_URL_FORWARDING` set. Continue retired; VS Code runs acp-bridge through ACP Client, and `setup.sh` deletes Continue's copies of the Brave key.
- **2026-10-24**: voice input (local Whisper small) and the deletion of recordings.
- **2026-10-25**: the Brave server is installed from its lockfile instead of started with `npx`, which contacted `registry.npmjs.org` on every start and fetched whatever the package's dependency ranges resolved to on first use. It also stopped seeing the rest of `.env`: it used to start in the repo, where `dotenv` read every value in `.env`, and `stack.sh`'s `set -a` exported them to it as well (nothing suggests it sent them anywhere). Silero's VAD model is deleted from the venv.
- **2026-10-26**: Open WebUI's built-in tools off for the chat model; acp-bridge checks the endpoint's certificate on the Mac without revocation lookups.
- **2026-10-27**: the IDE agents ask before each `bash` command (Allow / Always allow / Deny); "Always allow" prefixes stay in the agent's data folder. ACP Client's telemetry includes each question's command, which `telemetry.telemetryLevel: off` stops; setup also prints `"acp.autoApprovePermissions": "ask"`.
