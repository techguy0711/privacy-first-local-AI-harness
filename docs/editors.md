# Editors

Covers Continue (VS Code and Android Studio/JetBrains), and Xcode's built-in chat provider support plus its ACP agent support (via `acp-bridge`). All of them point at the same two things: local Ollama in local mode, Open WebUI's authenticated API in server mode.

## Continue (VS Code)

1. Install the Continue extension from the VS Code marketplace.
2. Install the repo's config for your current `MODE`:
   ```
   ./scripts/setup.sh --editors
   ```
   This backs up any existing `~/.continue/config.yaml` with a timestamp, then writes `editors/continue/config.${MODE}.yaml` into place (with `__SYSTEM_PROMPT_PATH__` and, in server mode, `__SERVER_HOST__` substituted for real values). It also writes a gitignored `.continue/.env` inside this repo containing `BRAVE_API_KEY`, synced from the repo's root `.env` — Continue's secrets resolver reads that file, not the root `.env` directly.
3. Nothing else is required for chat, embeddings, or the Brave MCP tool — they're all in the generated `config.yaml`.

**Telemetry**: Continue's "Allow Anonymous Telemetry" setting is an IDE toggle, not a `config.yaml` key — current docs confirm there's no way to script this into the committed config. Turn it off once per machine:
- Continue's own settings page (gear icon in the Continue panel) → toggle "Allow Anonymous Telemetry" off.
- VS Code additionally has its own override: Settings → search "Continue: Telemetry Enabled" → uncheck. (This VS Code setting overrides the Continue settings-page toggle if they disagree.)

**Autocomplete**: off by default (commented out in both `config.local.yaml` and `config.server.yaml`) to save memory on the 16GB Mac. If you enable it, uncomment the `starcoder2:3b` block only — do **not** use Continue's own documented recommendation (`qwen2.5-coder`), which is not on the model allowlist.

## Continue (Android Studio / JetBrains)

Same mechanism: install the "Continue" plugin from the JetBrains Marketplace, then run `./scripts/setup.sh --editors` (it writes the same `~/.continue/config.yaml` and `.continue/.env` the JetBrains plugin reads). The telemetry toggle lives in the same Continue settings page inside the JetBrains IDE; there's no separate IDE-level override there the way there is in VS Code.

**Caveat (confirmed against the plugin's current marketplace listing, 2026-10-06):** Continue's JetBrains plugin is now described by the Continue team as **"community-maintained"** — they explicitly recommend their terminal CLI (`cn`) instead for non-VS-Code use, saying it's where active development is happening. The plugin is still functional and this plan still uses it (it's the only in-IDE option for Android Studio), but don't expect it to get the same attention as the VS Code extension. If it becomes unreliable, the documented alternative is running Continue's CLI from a terminal alongside Android Studio rather than as an in-IDE panel.

Also note: unlike VS Code, JetBrains has no built-in local embedder, so the `embed`-role model block in `config.yaml` is required there (it's already present in both committed configs).

**Android Studio native alternative**: as of this writing, Android Studio has no first-party local/OpenAI-compatible model provider setting of its own (unlike Xcode) — the Continue plugin is the only documented path. If a native provider setting ships in a future Android Studio release, it would be configured the same way as Xcode's "Locally Hosted"/"Internet Hosted" flow described below.

## Xcode

Xcode's Settings → Intelligence panel has three separate sections — don't confuse them:
- **Agents** — registers a full agentic coding tool (ACP or built-in) that Xcode launches and drives. This is where `acp-bridge` goes (below).
- **Models** — autocomplete-related model settings (not used here; autocomplete stays off per the allowlist policy, same as the other editors).
- **Chat** — a plain chat backend (`ChatGPT in Xcode`, `Claude Sonnet & Opus`, and an **"Add a Chat Provider..."** button). This is what the earlier revision of this doc described, and what's already confirmed working.

Verified on Xcode 27 (2026-10-06); check this against your installed version since Apple has reorganized these settings before and official docs here are thin (Apple shows the Agents dialog only as a screenshot, with no field-by-field documentation).

### Chat provider (plain chat, no tools — confirmed working)

**Local mode:**
1. Xcode → Settings → Intelligence → **Chat** section → **Add a Chat Provider...**
2. Select **Locally Hosted**, enter port `11434` → Add.
3. Star icon (top left) → dropdown → My Account → pick `coder-local`.

No API key, no outbound traffic — this talks straight to local Ollama. No tool access of any kind (no file edits, no search) — it's chat only.

**Server mode:**
1. Same dialog → **Internet Hosted**.
2. URL: `https://<SERVER_HOST from .env>` (the reverse-proxied Open WebUI TLS endpoint — see `docs/server.md`).
3. API Key: your per-user Open WebUI API key (`sk-...`, from Open WebUI → Settings → Account → API Keys).
4. Add, then pick `coder-server` the same way as above.

Open WebUI's own OpenAI-compatible endpoint lives at `/api/chat/completions`, not `/v1/chat/completions`. `docs/server.md`'s reverse-proxy config includes a rewrite from `/v1/chat/completions` to `/api/chat/completions` specifically so this flow works unmodified — if a future Xcode version expects a different path, add the matching rewrite there rather than changing Open WebUI.

### Agent (ACP, via acp-bridge — real tool use, no Brave search)

Xcode 27 supports the Agent Client Protocol (ACP) — a JSON-RPC-over-stdio standard (originally from Zed) for registering a full agentic coding tool, not just a chat backend. We use **[acp-bridge](https://github.com/BlakeHung/acp-bridge)**, a small Rust adapter purpose-built for local models: it implements the agentic loop itself (file read/write, `edit`, `list_dir`, `search_code`, `bash`, `git_status`/`diff`/`log`/`commit`) on top of any OpenAI-compatible endpoint.

**Why this instead of a bigger agent CLI (e.g. OpenCode)**: evaluated and rejected — confirmed live (not just from docs) that it makes ~26 outbound connections to its own cloud and npm's registry on every single launch, even with every documented privacy flag set. That's incompatible with this stack's no-telemetry rule. `acp-bridge` was verified the same way: launched it, watched its connections, and confirmed the *only* connection it ever opens is to the configured model endpoint (loopback to Ollama in local mode) — zero other traffic. Full writeup in `docs/privacy.md`.

**Real limitation to know going in**: `acp-bridge` does **not** relay Xcode's own tools (build/test/project navigation — those are only exposed to *external* CLI agents like Claude Code via `xcrun mcpbridge`) and has **no MCP support at all** — so the Brave Search tool is not available here, by design (a closed, fixed tool set is what makes its zero-outbound-calls guarantee possible). You get real file-edit/bash/git tool use, not Xcode-specific tooling or web search. Brave search stays available in VS Code and Android Studio via Continue regardless of this choice.

**Setup:**
1. Run `./scripts/setup.sh --editors` — downloads the pinned `acp-bridge` binary (platform-detected) to `bin/acp-bridge` and prints the exact registration values for your current `MODE`.
2. Xcode → Settings → Intelligence → **Agents** → **Add an Agent...**
3. Fill in exactly what the script printed:
   - **Name**: whatever you like (e.g. `Coder (local)`)
   - **Executable**: absolute path to `bin/acp-bridge` (printed by the script)
   - **Interpreter**: leave empty (it's a native binary, not a script)
   - **Arguments**: absolute path to `editors/acp/config.toml` (printed by the script) — see "Why the config file" below
   - **Environment Variables**: `LLM_BASE_URL`, `LLM_MODEL`, `LLM_MODEL_CONTEXT=16384` (matches `num_ctx` in both Modelfiles; acp-bridge otherwise assumes 32768), and (server mode only) `LLM_API_KEY` — exact values printed by the script
4. Leave the lifecycle trigger at its default (**While Xcode is Open**).

Re-running `./scripts/setup.sh --editors` after a version bump re-downloads the binary to the same path — no need to re-register the agent in Xcode. If you move the repo, both the Executable and Arguments paths change — update them in Xcode.

**Why the config file**: without it, acp-bridge sends a one-line generic system prompt, and `llama3.1:8b` emits `write_file` calls as plain text (raw newlines inside the JSON arguments) about half the time. Ollama can't parse those as tool calls, so the agent "replies" with a JSON blob and builds nothing — while the same model does fine in Open WebUI, where it only has to write code into chat. `editors/acp/config.toml` sets an agent-specific system prompt plus `temperature = 0.2`; together they took usable files (a real tool call *and* real newlines in the content) from 7/18 to 15/18 in testing (2026-10-07, acp-bridge 0.9.2), and end-to-end ACP sessions then wrote proper multi-line files. Don't add JSON-escaping hints to the prompt — the model double-escapes and writes literal `\n` into files. acp-bridge also stops after 5 tool rounds (not configurable), which is why the prompt says to write each file once. It's still an 8B model: expect simple code and the occasional failed turn (just re-ask).

**Xcode-specific gotchas (captured from a real Xcode 27 session, 2026-10-07):**
- Xcode prepends a hidden block to every prompt telling the model to use its `xcode-tools` MCP server (`DocumentationSearch`, `BuildProject`, `XcodeWrite`, ...). acp-bridge ignores MCP, so without the config's "those tools DO NOT EXIST" line the model calls them, gets "Unknown tool", and falls back to pasting code in chat.
- Xcode lists files as `<Project>/MyApp/X.swift` but launches the agent with the project folder as cwd, so without the path rule writes land in a stray `<Project>/<Project>/MyApp/` folder that Xcode never shows. Check for that folder if files seem to "disappear".
- If the agent ignores the config entirely (generic replies, no temperature), Xcode isn't passing the Arguments field — reopen the agent in Settings and confirm it saved.
- Known ceiling: `llama3.1:8b` doesn't reliably read a file before rewriting it, so asking it to *change* an existing file can replace it with a fragment (no imports/struct). Use it for new files, keep the project under git (or Xcode's Local History) so a bad rewrite is one revert away, and prefer the Chat provider above for edits to existing code. Large multi-file requests hit the 5-round cap; ask for one piece at a time. Env vars override the file (per acp-bridge's `config.toml.example`), so it carries no endpoint, model, or key and is identical in both modes. To debug the agent, set `RUST_LOG=acp_bridge=debug` in Xcode's env vars — acp-bridge logs to stderr.
