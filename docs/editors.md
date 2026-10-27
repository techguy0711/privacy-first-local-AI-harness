# Editors

Covers the ACP agent (`acp-bridge`) in VS Code, Android Studio and Xcode, Android Studio's built-in model providers, and Xcode's built-in chat provider. Chat and embeddings use the inference gateway: loopback in local mode, private TLS with personal Open WebUI API keys in server mode. The gateway sends inference requests to Ollama. Chat requests may carry images: inline PNG, JPEG or WebP (`data:image/...;base64`) in user messages, up to `QUEUE_MAX_IMAGE_BYTES` (16 MiB decoded) per request. GIF and image links are refused, so the gateway never fetches anything.

## VS Code (ACP agent)

VS Code runs the same `acp-bridge` as Xcode and Android Studio, through the **ACP Client** extension (`formulahendry.acp-client`, MIT; 0.2.0 read 2026-10-23), with `editors/acp/config.vscode.toml`. It replaces Continue, whose repository is read-only since its final 2.0.0 release (see "Why not Continue" below), so Continue gets no more fixes.

**Setup** (macOS, after `./scripts/setup.sh --editors`, which prints the exact lines for your `MODE`):
1. Install **ACP Client** (publisher formulahendry) from the Extensions view. Uninstall Continue and delete the `~/.continue/config.yaml` (and its `.bak` copies) that earlier `--editors` runs wrote; `setup.sh` removes the copy of `BRAVE_API_KEY` it kept for Continue in this repo's `.continue/`, and `doctor.sh` reports anything left.
2. Command Palette → **Preferences: Open User Settings (JSON)**, and add the lines setup printed:
   - `"acp.agents"` with one entry, **Gemma 4 12B (Local) agent** or **Llama 3.3 70B (Server) agent**: `command` (absolute path to `bin/acp-bridge`), `args` (absolute path to `editors/acp/config.vscode.toml`) and `env` (`LLM_BASE_URL`, `LLM_MODEL`, `LLM_MODEL_CONTEXT`, `LLM_QUEUE=1`, `LLM_TIMEOUT`, and in server mode `LLM_API_KEY`, your personal Open WebUI key). This list replaces the extension's 11 built-in agents, which run `npx` packages (Claude Code, Gemini CLI, Codex CLI, Qwen Code, …) that talk to their vendors' clouds.
   - `"acp.logTraffic": false`. Otherwise the extension copies every protocol message, with your prompts, file contents and images, into its **ACP Traffic** output panel.
   - `"telemetry.telemetryLevel": "off"`. The extension reports usage events (agent name, message length, connect errors) through VS Code's telemetry library, which follows this setting; it also turns off VS Code's own telemetry.
3. Start the stack (`./scripts/stack.sh up`; the gateway serves the model and web search needs the local Brave server), open **ACP Client** in the activity bar and connect to the agent.

Don't use the extension's **ACP: Browse Agent Registry** command: it downloads the agent list from `cdn.agentclientprotocol.com`, and its agents talk to their own clouds. Other AI extensions (Copilot, Gemini Code Assist, …) send code to their vendors; disable them in workspaces you use with this stack.

**What the agent does**: the tools, guards, notes and guarded Brave `web_search` described under Xcode below. The extension starts it through your login shell with the first workspace folder as its working directory, so build tools on your shell's `PATH` are found. After a turn that changed files it builds the project and sends the errors back, up to 3 builds per turn: `cargo check --offline`, `./gradlew --offline …`, `go build` with `GOPROXY=off`, `swift build --disable-automatic-resolution`, `tsc --noEmit`, or `xcodebuild`. A `package.json` with a `build` script runs `npm run build` instead, which does whatever that script does (see `docs/privacy.md`); a project with none of these isn't built. Conversations are saved in `data/acp-bridge-vscode/`, apart from the other IDEs'.

**Images and files**: the agent advertises image input (`supports_image`), so images a client attaches reach the model. ACP Client 0.2.0 sends text only (its file attachment isn't functional yet and it has no image paste), so in VS Code name the files you mean ("look at src/app.ts") and the agent reads them; for a screenshot, use Open WebUI.

**Checked headless (2026-10-23)**, driven over stdio the way the extension does it (`initialize` with its client capabilities, `session/new` with the project folder and no MCP servers, `session/prompt`): the agent advertised image input and read a screenshot sent as an ACP image block through the gateway's job API; on a small Cargo project, "add a function double(x: i32) -> i32 … and make main print double(21)" took 31 s (list, read, write, then `cargo check --offline` passed). **Not verified yet**: a session inside VS Code itself, and a connection audit of the extension.

**Autocomplete**: off. The gateway serves chat and embeddings only (see the end of this guide).

## Android Studio

Android Studio uses its own **model providers** setting to talk to the inference gateway. The Continue plugin is no longer an option. Checked 2026-10-15 on Android Studio Rabbit 1 | 2026.2.1 (build `AI-262.9437.185`).

**Why not Continue**: Continue's JetBrains plugin is tagged `deprecated` on the JetBrains Marketplace. The IDE-facing search and update endpoints return no Continue entry for any JetBrains build tried (Android Studio `AI-262` and `AI-251`, IntelliJ IDEA `IU-251` to `IU-262`), so it can't be found or installed from inside any JetBrains IDE. This is not a version lag: the last release (1.0.67, 2026-03-27) declares `since-build 241` with no upper bound. Continue's repository is read-only and 2.0.0 was its final release. Don't sideload the old zip, since it will get no fixes. VS Code moved to the ACP agent for the same reason (since 2026-10-23; see VS Code above). Other JetBrains IDEs (IntelliJ IDEA, PyCharm, …) currently have no supported path in this repo.

**Local mode** (start the stack first with `./scripts/stack.sh up`):
1. Settings → Tools → AI → **Model Providers** → **+** → **Local Provider**.
2. **Description**: `Gemma 4 12B (Local)`. **Port**: `8787` (or your `GATEWAY_PORT`). Android Studio then uses `http://localhost:<port>/v1` and detects the gateway as a generic OpenAI-compatible server through `/v1/models`.
3. Click **Refresh**. `coder-local:latest` only appears after that. Enable it, then click OK.
4. Open the **Agent** tab on the right sidebar (Rabbit 1 has no separate chat window) and pick `coder-local:latest` in its model picker.

**Server mode:**
1. Same dialog → **Third-Party Remote Provider**.
2. **Description**: `Llama 3.3 70B (Server)`. **URL**: `https://<SERVER_HOST from .env>/v1`. **URL Schema**: OpenAI. **API key**: your personal Open WebUI API key (`sk-...`).
3. **Refresh**, enable `coder-server:latest`, and pick it in the Agent tab's model picker.

`setup.sh --editors` prints these values for your current `MODE`. Nothing is written to Android Studio's settings.

**How it talks to the gateway**: Android Studio's OpenAI client tries the Responses API (`/v1/responses`) first. The gateway answers 404, and Android Studio switches that provider to `/v1/chat/completions`; its log shows `Falling back to Completion API. Error: 404`. Android Studio sends its instructions as `developer`-role messages, which `coder-local` follows like system messages. The gateway prepends `prompts/system.md` to every chat request, so Android Studio gets the same search rules as the other clients. Responses stream with no queue-position display (same as Open WebUI).

**Verified locally (2026-10-15, 16GB Mac, `coder-local`)**: a plain question and an Agent Mode request in the Agent tab were both answered by the local model through the gateway. Each agent turn sent 12.9K–14.8K prompt tokens (Android Studio's own agent prompt and tool definitions take about 12.5K), against the Modelfile's `num_ctx 16384` at the time. Turns took 17 s to 2.5 min.

**Context size (changed 2026-10-17)**: at 16K, longer agent sessions reached 16.1K prompt tokens, and Ollama cut replies off at the context limit (`truncated = 1` in `~/.ollama/logs/server.log`), usually in the middle of a file edit. Android Studio didn't compress its history in time because it didn't know the model's limit. For a model it doesn't recognise it assumes 16,384 and compresses only at 90% of that, by its own token estimate. `Modelfile.local` now sets `num_ctx 32768` (about 300 MiB more memory), and the gateway's `/v1/models` reports it as `context_length`. Android Studio reads that and, above 24,576, compresses at its default 50%, so about 16K stays free for the reply. Click **Refresh** in the model provider settings once so Android Studio reads the new limit.

**Timeouts (2026-10-18)**: Android Studio cancels any single request after 10 minutes. At about 10 tokens/s on a 16 GB M5, one 6,252-token reply ran past that. Its client then retried only `localhost`'s IPv6 address, `[::1]:8787`, and failed with "Connection refused" until restarted. The gateway now listens on `::1` as well, so the retry goes through. A reply longer than about 5,500 tokens still hits the 10-minute limit on that Mac. Asking for one change at a time and starting a new Agent chat per task keeps replies and prompts shorter. One request hit the gateway's `INFERENCE_TIMEOUT_SECONDS` (600 s) and Android Studio retried it on its own. For quick questions, Open WebUI or Xcode's plain chat is faster.

**Privacy** (see `docs/privacy.md`): Google says it does not see prompts or responses exchanged with a third-party or local provider. Android Studio still contacts Google on its own, whichever model you pick (server flags, experiments, an Android docs index download, lint jars from `maven.google.com`). While a Google account is signed in to Gemini, it also checks that account's Gemini quota when the Agent tab is used; this happened during the test above. Its agent has a built-in `web_search` tool (run through a Gemini model, not Brave). The gateway removes it from every request, so the model can't call it and answers from what it knows instead. For current information, use Open WebUI or an ACP agent (Xcode, Android Studio, VS Code), which search through Brave. Its Android-docs tools (`search_android_docs`, `fetch_android_docs`) pass through unchanged. **Not verified yet**: whether those docs tools reach Google while the local provider is selected, and whether the local provider works with the Google account signed out. Turn off usage statistics under Settings → Appearance & Behavior → System Settings → **Data Sharing**.

### Agent (ACP, via acp-bridge — preview, macOS)

The Agent tab with the local model above edits files, but nothing builds the result, so a 12B model's Kotlin often doesn't compile (wrong imports, Compose APIs that don't exist, dependencies that aren't declared). Android Studio 2026.2.2 (Rabbit 2) can instead run an external ACP agent. Registered there, the Xcode agent's `acp-bridge` brings its build-and-fix loop: after every turn that changed files it runs `./gradlew --offline compileDebugSources` in the project and sends the Kotlin errors (`e: …`) back to the model, up to 3 builds per turn. It never reports success for a failing build. Its no-progress guard, history trimming, notes and guarded Brave search work as described under Xcode below. It uses `editors/acp/config.android.toml`, which has Android rules in place of the Xcode ones.

Needs Android Studio Rabbit 2 | 2026.2.2 (build `AI-262.10968.63` checked, 2026-10-22). Google calls the feature "Bring Your Own Agent" and introduced it in Rabbit 2 Canary. Rabbit 1 | 2026.2.1 has the same code behind the flag `studiobot.acp.client.enabled` (off by default), but adding the agent there didn't work in practice. On Rabbit 2, adding the agent through the Agents page is verified: Android Studio wrote the pasted JSON to `acp.json` unchanged. A conversation run through it inside Android Studio is not verified yet. The headless test below drove acp-bridge the way Android Studio does.

**Setup** (after `./scripts/setup.sh --editors`, which prints the exact JSON for your `MODE`):
1. Settings → Tools → AI → **Agents** → **Add via JSON…** (or its **JSON Configuration** tab), and paste the `agent_servers` JSON setup printed. Android Studio saves it to `~/.android/studio/agent/acp.json`. The entry holds `command` (absolute path to `bin/acp-bridge`), `args` (absolute path to `editors/acp/config.android.toml`) and `env`: `LLM_BASE_URL`, `LLM_MODEL`, `LLM_MODEL_CONTEXT`, `LLM_QUEUE=1`, `LLM_TIMEOUT`, `JAVA_HOME`, and in server mode `LLM_API_KEY`. `JAVA_HOME` is required: an app started from the Dock passes no `JAVA_HOME`, and macOS's `/usr/bin/java` stub can't run Gradle. Setup points it at Android Studio's bundled JDK, which is also what Android Studio's own Gradle uses by default, so the agent's builds can reuse the running Gradle daemon instead of starting a second one.
2. Pick the agent in the agent window. Don't install anything from the registry list on that page (see `docs/privacy.md`).

**"Port for local model providers can not be empty"** when you click OK: Android Studio checks every AI settings page on OK, and this one comes from **Model Providers**. A **Local Provider** entry there has an empty Port, usually an extra row added by accident. Delete that row, or enter the gateway port (`8787`) if it's the one you use for the Agent tab. The agent JSON is saved as soon as you add it, so if you click Cancel instead, the agent still stays registered.

**How it differs from the Agent tab**:
- **Android Studio's prompt is still added**: Android Studio prepends its agent prompt to every message: a persona, rules for a "Python library" of tools that ask for parallel calls, its tool names, skills, and the project structure. That is about 2.6K tokens of fixed text before the project parts, in every message. The Android config tells the model to ignore it, and to make one tool call per reply. Two tool calls in one reply is what Ollama 0.35's gemma4 parser drops, and Android Studio's prompt asks for exactly that. Start a new conversation per task, since each follow-up carries another copy.
- **Android Studio's tools aren't used**: build diagnostics, Compose previews, emulator control and Android docs search come from an MCP server Android Studio offers the agent. acp-bridge ignores it (`client_servers = "off"`). The model works with acp-bridge's own file, search, `bash` and git tools, and Gradle for builds.
- **Separate history**: its conversations are saved in `data/acp-bridge-android/`, apart from the Xcode agent's `data/acp-bridge/`, so neither IDE lists the other's.
- **Edits go straight to disk**: Android Studio picks them up from the file system, so its accept/reject review of agent changes doesn't apply. Keep the project under git (or use Local History).
- **Images**: on, as for the Xcode agent (since 2026-10-23); not yet checked inside Android Studio.
- **Offline builds**: the build can only use libraries already in Gradle's cache, so the prompt tells the model not to add dependencies or plugins. After you add one yourself, sync once in Android Studio first.
- `bash` is unsandboxed, as in Xcode (see below and `docs/privacy.md`).

**Headless check (2026-10-21)**: `bin/acp-bridge` with this config, driven over ACP stdio like Android Studio's default dialect (its prompt sections prepended to the message, an HTTP MCP server offered in `session/new`), on a copy of a Compose project. The config loaded, the offered MCP server was ignored, Brave search connected, and with `JAVA_HOME` set to the bundled JDK the offline build ran in 4 s on a warm daemon. With `coder-local` on a 16 GB Mac:
- "Add a Reset button and an Even/Odd label, with the check in a new file" took 3 min 52 s: 5 tool calls, one at a time, then the automatic build (6 s), which passed on the first attempt.
- With a type error seeded in the screen file (`Text(text = count)`, an `Int`), "make the + button add 2" took 9 min 3 s. The model made the change, the first build failed on the seeded line, it fixed that (`count.toString()`), and the second build passed. A separate clean build of the result passed too.
- In that run acp-bridge forwarded only the `e: file:line:col message` line of each Kotlin error. Kotlin puts the detail on the following lines (here the candidate signatures after "None of the following candidates is applicable:", whose `text: String` is the fix), and working out the fix took about 4 minutes of the 9. `acp-bridge.patch` now keeps up to 4 of those lines per Kotlin error (200 characters each). With the same seeded error and request, the turn took 4 min 38 s: the failed build, then a fix 2 min 21 s later, then a passing build, with both changes made. That is one run each, and the model's output varies from run to run.

## Xcode

Xcode's Settings → Intelligence panel has three separate sections — don't confuse them:
- **Agents** — registers a full agentic coding tool (ACP or built-in) that Xcode launches and drives. This is where `acp-bridge` goes (below).
- **Models** — autocomplete-related model settings (not used here; autocomplete stays off per the allowlist policy, same as the other editors).
- **Chat** — a plain chat backend (`ChatGPT in Xcode`, `Claude Sonnet & Opus`, and an **"Add a Chat Provider..."** button). This is what the earlier revision of this doc described, and what's already confirmed working.

Verified on Xcode 27 (2026-10-06); check this against your installed version since Apple has reorganized these settings before and official docs here are thin (Apple shows the Agents dialog only as a screenshot, with no field-by-field documentation).

### Chat provider (plain chat, no tools — confirmed working)

**Local mode:**
1. Xcode → Settings → Intelligence → **Chat** section → **Add a Chat Provider...**
2. Select **Locally Hosted**, enter gateway port `8787` (or `GATEWAY_PORT`) → Add.
3. Star icon (top left) → dropdown → My Account → pick `coder-local`.

No API key, no outbound traffic — this talks to the local inference gateway. No tool access of any kind (no file edits, no search) — it's chat only.

**Server mode:**
1. Same dialog → **Internet Hosted**.
2. URL: `https://<SERVER_HOST from .env>` (the private TLS proxy — see `docs/server.md`).
3. API Key: your per-user Open WebUI API key (`sk-...`, from Open WebUI → Settings → Account → API Keys).
4. Add, then pick `coder-server` the same way as above.

The proxy sends `/v1/*` to the inference gateway, which answers `/v1/models` and `/v1/chat/completions` and checks the personal key; nothing is rewritten to Open WebUI's own `/api/chat/completions` any more. If a future Xcode version calls a different path, route that path to the gateway in the proxy config.

### Agent (ACP, via acp-bridge — tools, Xcode's own tools, guarded web search)

Xcode 27 supports the Agent Client Protocol (ACP) — a JSON-RPC-over-stdio standard (originally from Zed) for registering a full agentic coding tool, not just a chat backend. We use **[acp-bridge](https://github.com/BlakeHung/acp-bridge)**, a small Rust adapter purpose-built for local models: it implements the agentic loop itself (file read/write, `edit`, `list_dir`, `search_code`, `bash`, `git_status`/`diff`/`log`/`commit`) on top of any OpenAI-compatible endpoint. `setup.sh --editors` builds it from source: upstream tag `v$ACP_BRIDGE_VERSION` (0.9.2), checked against the pinned commit `ACP_BRIDGE_COMMIT` (both in `scripts/runtime.sh`), plus our patches `editors/acp/acp-bridge.patch` and `editors/acp/queue.patch`, which add everything in "What the agent does" below.

**Why this instead of a bigger agent CLI (e.g. OpenCode)**: evaluated and rejected — confirmed live (not just from docs) that it makes ~26 outbound connections to its own cloud and npm's registry on every single launch, even with every documented privacy flag set. That's incompatible with this stack's no-telemetry rule. Upstream `acp-bridge` 0.9.2 was verified the same way: launched it, watched its connections, and confirmed the *only* connection it ever opened was to the configured model endpoint (loopback to Ollama in local mode). The patch adds only loopback connections (Xcode's tool bridge, the local Brave server) — see `docs/privacy.md`. Other ways to run local models in the IDEs are compared in [comparison.md](comparison.md).

**What the agent does** (patched build; details in the patched crate's README, `build/acp-bridge/src/README.md` after a build):
- **Build-and-fix loop**: when a turn changed files, acp-bridge builds the project before ending the turn — with Xcode's own `BuildProject` when Xcode's tools are connected, else an offline `xcodebuild` (`-disableAutomaticPackageResolution`, `CODE_SIGNING_ALLOWED=NO`, DerivedData in `~/Library/Caches/acp-bridge/DerivedData/<project>-<hash>` — outside the repo and the project, never cleaned up automatically; delete it to reclaim space) — and hands the compiler errors back to the model, up to 3 builds per turn. It never reports success for a failing build.
- **Real Stop**: Xcode's Stop cancels the turn — the model request is aborted, a running `bash` command or build is killed (whole process group), and a running Xcode tool call is cancelled.
- **History trimming + notes**: every request is fitted into the model's context (`LLM_MODEL_CONTEXT`): first older copies of a file the model read again, then old reasoning and the file contents in old `write_file`/`edit` arguments; old tool results are cut and the oldest rounds dropped, never the system prompt or your message. The latest read of each file is kept whole until nothing else is left to cut, because that is what `edit` copies `old_text` from. A read that a later successful edit or write of the same file made out of date is replaced in every request by a note to use that change's result or read the file again (a pre-edit copy made the model retry edits against text that no longer existed). Dropped rounds are summarized into working notes at the end of each request, and the model has a `notes` tool for its own goal/findings.
- **No-progress guard**: duplicate reads are answered from a cache; after 6 read-only calls without a change the model is told to act, and from 14 read-only calls are refused. An edit only invalidates cached reads of the file it changed (searches and listings are refreshed after any change), so re-reading unchanged files after an edit still counts as repeating. If compaction removed the earlier result, the repeat gets it again in full and counts as an ordinary read. A reply whose reasoning loops (or hits `max_tokens`) is discarded and retried once with thinking off.
- **Docs search**: Xcode's on-device `DocumentationSearch` is offered as `docs_search` (top 3 results, at most 4 searches per turn).
- **Xcode diagnostics / BuildProject**: after each Swift edit, acp-bridge asks Xcode for that file's errors (`XcodeRefreshCodeIssuesInFile`) and appends them to the edit's result, so a wrong fix shows up in the same round; builds run in Xcode (shown there, Xcode's DerivedData, no competing `xcodebuild`).
- **Brave web search with a guard**: a slim `web_search` tool, through the Brave server `./scripts/stack.sh up` starts (only while it answers; the key stays with that server, acp-bridge needs none). A privacy guard in code refuses queries containing code, paths, file names, URLs, key-like strings, or names declared in your project; 3 searches per turn, 20 per conversation.
- **Saved, resumable conversations**: stored in the repo's gitignored `data/acp-bridge/` (dirs `0700`, files `0600`, keys/tokens redacted), deleted 30 days after last use, so Xcode can reopen a conversation after a restart. They contain prompts and source excerpts the model saw; `LLM_PERSIST=0` in the agent's env turns this off.
- **Images** (since 2026-10-23): the agent advertises image input (`supports_image = true`), so an image Xcode attaches to a message goes to the model inline, and saved conversations keep it. Not yet checked inside Xcode.

Tool access stays narrow: of the MCP servers Xcode passes, only its own `mcpbridge` at `/Applications/Xcode.app` or `/Applications/Xcode-beta.app` is started (a differently named install, e.g. `/Applications/Xcode-27.0.app`, is refused and the agent runs without Xcode's tools — add its `.../Contents/Developer/usr/bin/mcpbridge` path to `[mcp] allowed_commands` in `editors/acp/config.toml`); acp-bridge may call `DocumentationSearch`, `XcodeRefreshCodeIssuesInFile`, `BuildProject` and `XcodeGlob`, and the model sees only `docs_search`. Xcode's crash and field-performance tools (they fetch data from App Store Connect) are refused in code whatever the config says. All of this is set in `editors/acp/config.toml`.

**What isn't narrow: `bash`.** As in upstream acp-bridge, the model's `bash` tool runs any shell command in the project folder — no sandbox, no confirmation; Xcode shows each command as it runs, and Stop kills it. The agent's prompt forbids network commands there (`curl`, `wget`, `git clone`/`fetch`/`pull`/`push`, package installs), but that is an instruction to the model, not enforcement: such a command would bypass the `web_search` privacy guard. Watch what it runs (see `docs/privacy.md`).

**Setup:**
1. Install Rust once (prerequisite for the build; `setup.sh` won't install it): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`, then open a new terminal. It needs Rust 1.86 or newer (the locked dependencies require it) — if Rust is already installed, `rustup update`. Without cargo, `setup.sh --editors` stops before pulling any model.
2. Run `./scripts/setup.sh --editors` — clones acp-bridge at the pinned tag into `build/acp-bridge/` (gitignored), refuses to build unless the tag is the pinned commit, applies both patches, runs `cargo build --release --locked`, installs `bin/acp-bridge` plus `bin/acp-bridge.stamp` (version, commit, patch hash, and the installed binary's hash), and prints the exact registration values for your current `MODE`. Re-runs skip the build while the stamp matches. Cargo's downloaded crates are cached in `~/.cargo/registry` (shared with other Rust builds).
3. Xcode → Settings → Intelligence → **Agents** → **Add an Agent...**
4. Fill in exactly what the script printed:
   - **Name**: `Gemma 4 12B (Local)` or `Llama 3.3 70B (Server)`, as printed by setup
   - **Executable**: absolute path to `bin/acp-bridge`
   - **Interpreter**: leave empty
   - **Arguments**: one argument, the absolute path to `editors/acp/config.toml`, pasted as is (no quotes, even if the path contains spaces)
   - **Environment Variables**: `LLM_BASE_URL`, `LLM_MODEL`, `LLM_QUEUE=1`, `LLM_TIMEOUT` as printed by setup, `LLM_MODEL_CONTEXT` (the `num_ctx` of `Modelfile.$MODE`: 32768 local, 16384 server; acp-bridge otherwise assumes 32768), and (server mode only) `LLM_API_KEY` — exact values printed by the script
5. Leave the lifecycle trigger at its default (**While Xcode is Open**).
6. On the first prompt Xcode asks **"Allow acp-bridge to access Xcode?"** — once per Xcode launch, and again after every rebuild of `bin/acp-bridge`. Allow it; until it's answered (the first turn waits up to 30 s) the agent works without Xcode's tools. If it never asks, or the agent's thoughts say Xcode MCP access is disabled, turn on Xcode → Settings → Intelligence → **Model Context Protocol**. If the repo is in a privacy-protected folder (`~/Downloads`, `~/Desktop`, `~/Documents`), macOS may also ask whether **acp-bridge** may access that folder; allow it, or the agent can't read the repo.
7. For web search, set `BRAVE_API_KEY` in `.env` and run `./scripts/stack.sh up`. Without the Brave server running on this Mac the agent simply has no `web_search`.

Re-running `./scripts/setup.sh --editors` after a pin or patch change rebuilds to the same path — no need to re-register the agent, but Xcode asks to allow it again (and macOS may ask again about a protected folder). If you move the repo, update the Executable and Argument paths in Xcode.

**Why the binary and not a wrapper script** (verified with Xcode 27 beta, 2026-10-14): Xcode runs an agent registered with an Interpreter inside `/usr/bin/sandbox-exec`, so macOS checks folder access for that sandbox, not for Xcode. A sandboxed background process can't show the permission prompt, so a script in `~/Downloads` (and likewise Desktop/Documents) is refused before its first line runs. The new conversation then fails with "JSON-RPC request with ID … failed to produce a response". Registered as the binary itself, `acp-bridge` gets its own one-time folder permission and works. Xcode keeps the agent's stderr and doesn't display it; see **Debugging** below.

**Why the config file**: without it, acp-bridge sends a one-line generic system prompt, and small models write their tool calls as plain text (an early `llama3.1:8b` test went from 7/18 to 15/18 usable files with our prompt and a low temperature). `editors/acp/config.toml` sets the agent's system prompt (act through tool calls, Xcode's path rules, one tool call per reply, when to use `docs_search`/`web_search`), the reply cap (`max_tokens = 4096`, `timeout_secs = 600`), the context reserve, the guards, notes, the MCP policy, the Brave server URL (127.0.0.1 and `BRAVE_MCP_PORT` from `.env`; `doctor.sh` checks) and persistence. It sets **no temperature** on purpose: `gemma4:12b`'s own defaults (temperature 1, top_k 64, top_p 0.95) apply — the old `0.2`, tuned for llama, made gemma4's thinking loop for 8 minutes. Don't add JSON-escaping hints to the prompt — the model double-escapes and writes literal `\n` into files. The tool budget is `LLM_MAX_TOOL_ROUNDS` (default 30). If the model reaches it after changing files, the harness runs verification. A failed build can start a repair cycle, bounded by the configured build-attempt limit. If the model still has no final answer, the turn ends explicitly as incomplete, even if the build passes. Env vars override the file (per acp-bridge's `config.toml.example`), so it carries no endpoint, model, or key and is identical in both modes.

**Xcode-specific gotchas (captured from real Xcode 27 sessions, 2026-10-07 .. 14):**


The bridge rejects edits with identical old and new text and writes whose content already matches the file. It ends the turn after three identical unsuccessful file calls or six unsuccessful file calls since the last successful file change, even if searches occur between them. The final error includes the last failure and states that earlier changes remain incomplete and have not passed a final build. This protection applies to all supported models and does not depend on the read-only investigation limit. A stopped turn does not undo earlier edits.

After a failed edit, the bridge rereads the target through its sandboxed file reader and provides bounded current content and matching locations. It also says when `old_text` failed because of a placeholder line such as `// ...` or a difference only in spacing, the two slips recorded in Xcode sessions. A `write_file` or `edit` whose new text contains one of the bridge's own placeholders (such as "[contents of … elided - call read_file for the current version]") is refused without touching the file and counts as a failed file call; in one Xcode session the model had replaced a whole file with such a placeholder. When available, Xcode supplies fresh Swift diagnostics. The next inference request omits older failed edit exchanges and replaces the latest invalid call with its recovery evidence; the stored conversation is unchanged. This prevents repeated invalid arguments from serving as examples to copy. The model must still choose a correct repair; recovery does not automatically rewrite files or guarantee a successful build.

Follow up in the same conversation to continue a stopped turn. Each follow-up receives fresh failure counters and the previous failure in its history. The agent instructions require rereading the affected file and correcting the failed arguments. Before inference, the bridge reserves room for the configured output limit and compacts older context as needed, keeping tool calls together with their results. History trimming saves summaries of discarded requests and activity. Ordinary original requests are protected during compaction; an oversized old request can be summarized so it does not block a shorter follow-up. Compaction is announced once per turn as bridge status (see "Status messages" below), not every round. If the current request still exceeds the estimated budget, the bridge asks for a shorter request instead of submitting it. Summaries are bounded and lossy; the agent may need to reread files. A separate compact file-state record retains the latest mutation result for up to eight files, including available Xcode diagnostics, across request compaction. It is reconstructed from stored tool results and does not depend on the model writing notes. The 4K reply allowance leaves roughly 11K tokens for input before tool schemas and prompt overhead; large whole-file writes may need smaller focused changes. Empty replies are retried twice and then reported as incomplete, never as successful empty answers.

- Xcode prepends a hidden block to every prompt telling the model to use its `xcode-tools` MCP server (`DocumentationSearch`, `XcodeWrite`, ...). acp-bridge now connects to that server itself, but the model only sees `docs_search`; Xcode tool names it still calls (`XcodeRead`, `XcodeUpdate`, `BuildProject`, ...) are mapped onto acp-bridge's own tools, and the prompt says only listed tools exist.
- A new conversation that fails immediately with "JSON-RPC request with ID … failed to produce a response" means the agent process died at launch. The cause seen on 2026-10-14 was a script registration (Interpreter set) blocked from `~/Downloads`; register `bin/acp-bridge` directly as in Setup.
- Xcode lists files as `<Project>/MyApp/X.swift` but launches the agent with the project folder as cwd, so without the path rule writes land in a stray `<Project>/<Project>/MyApp/` folder that Xcode never shows. Check for that folder if files seem to "disappear".
- If the agent ignores the config entirely (generic replies, no `docs_search`/`web_search`, nothing saved under `data/acp-bridge/`), check that the agent's Arguments hold the absolute path to `editors/acp/config.toml`.
- It's still a 12B model on a 32K context: keep the project under git (or Xcode's Local History) so a bad rewrite is one revert away, ask for one piece at a time on large features, and prefer the Chat provider above for quick questions.

**Debugging**: Xcode keeps acp-bridge's stderr, so its own log isn't visible there. What is:
- Xcode's agent log shows each launch (binary, pid), tool calls, disconnects and failures: `/usr/bin/log stream --style compact --predicate 'subsystem == "com.apple.IDEIntelligenceChat" AND (category == "Agent Activity" OR category == "AssistantSubmissionCoordinator")'`. Use `/usr/bin/log`, because plain `log` is a zsh builtin. If a conversation fails at once, add `OR (process == "sandboxd" AND eventMessage CONTAINS "would require prompt")` to see a folder-permission refusal.
- Each conversation's full history (prompt, tool calls, results) is in `data/acp-bridge/sessions/<id>/history.jsonl`.
- To see the bridge's own log (requests, retries, history trimming, MCP status, every `web_search query=...` and every refused one with its rule), run it in a terminal with `RUST_LOG=acp_bridge=debug` plus the same `LLM_*` variables and the config path. That starts a separate agent, not Xcode's.

If replies come back empty or a turn stops mid-task, check `~/.ollama/logs/server.log` for `gemma4 tool call parsing failed`: every case captured so far was two tool calls in one reply with the first left unterminated, which Ollama 0.35's gemma4 parser drops whole — the "ONE tool call per reply" prompt line is there for that.

## Queue-aware Xcode transport (2026-10-11)

`setup.sh --editors` applies `queue.patch` after `acp-bridge.patch` and includes
both hashes in the build stamp. Register `LLM_QUEUE=1` and the `LLM_TIMEOUT`
printed by setup. Endpoints are `http://127.0.0.1:8787/v1` locally or
`https://<SERVER_HOST>/v1` on a server. Keep the server API key in `.env` and
supply it through your existing editor environment mechanism; never put it in
committed config. The internal gateway service key is not an editor credential.

**Server certificates** (2026-10-26). The agent checks the server's certificate
against Mozilla's public roots and the certificates the Mac's keychains trust
(login, System, and any your organization installs by MDM). When `SSL_CERT_FILE`
is set in the agent's environment, it uses that file (PEM) instead of the
keychains, still alongside Mozilla's roots. So a server whose certificate comes
from a team's private certificate authority works once that authority is trusted
on the Mac, or with `SSL_CERT_FILE` set to its certificate. The check runs on the
Mac and makes no revocation lookups (OCSP, CRL), which the system's own verifier
would: `acp-bridge.patch` adds reqwest's `rustls-tls-native-roots`
(`rustls-native-certs`), not `rustls-platform-verifier`. An untrusted certificate
ends the request at once with `invalid peer certificate: UnknownIssuer` and how to
fix it, and a server that can't be reached reports why (for example
`Connection refused`) instead of "Queue connection lost". Android Studio's model
providers and Xcode's plain chat use their own trust settings and were not tried
with a private certificate authority.

The bridge submits a job with a stable idempotency key and polls its status. It
reports only real waits: a job still queued when polled (with its position), and
its start after such a wait. A job that starts at once, the usual case locally, is
not reported. These reports stay out of the model response and tool-call history. Transient transport/server errors retry the
same submission/job, never create a second inference request. Cancellation sends
DELETE; loss of that connection may leave work running until its server deadline.
Results survive temporary disconnects within the gateway's retention window,
not gateway restarts. The Xcode agent already used nonstreaming completions for
its tool loop; this change preserves that behavior.

The Android Studio and VS Code agents are the same acp-bridge and use the same
transport (`LLM_QUEUE=1`). Open WebUI, Android Studio's model providers and
Xcode's plain chat use the gateway's standard streaming endpoint. Keepalive
comments prevent idle silence but **do not display queue position**, and those
clients do not have job-reconnect integration. Adding their visible queue UI
requires client-specific work. No queue text is injected into assistant answers or code.
Checked in Xcode 27 beta on 2026-10-14: bridge status lines (for example the
compaction notice) appear in the agent's thinking as separate `[acp-bridge]`
paragraphs; see "Status messages" below.

**Status messages** (2026-10-14): queue waits, the once-per-turn compaction notice,
"Edit rejected…", and Xcode-tools availability are the bridge's own status, not
model reasoning. Xcode merges back-to-back thought chunks into one "thinking"
block, so the old per-round queue/compaction lines appeared at the start of almost
every reasoning block (33 of 34 in one recorded session). A client that advertises
`clientCapabilities.session.notices` (ACP v1 schema 1.25, stable since
2026-10-09) gets them as `notice` updates. Other clients get them as a thought
paragraph starting with `[acp-bridge]`. Xcode 27 beta does not advertise notices
(checked 2026-10-14): in two real sessions every status line arrived as an
`[acp-bridge]` paragraph, and no thinking block started with status text (33 of
34 did before). If a later Xcode advertises notices, those paragraphs move out of
the thinking stream.

Autocomplete remains disabled and is not routed by the gateway.
