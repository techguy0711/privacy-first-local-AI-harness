# Self-hosted AI coding stack

Run a local or shared coding assistant with Ollama. A common inference gateway supplies bounded per-user queues, while Open WebUI, Brave Search (MCP) and an ACP agent (`acp-bridge`) for Xcode, Android Studio and VS Code provide the user interfaces.

See [server setup and Mac testing](docs/server.md) for Ollama deployment and queue limitations.

## Before you start

**What you need (local mode):** a Mac with at least 16 GB of memory (tested on an Apple Silicon Mac with 16 GB) and about 15 GB of free disk: 8 GB for the model, 2 GB for Open WebUI, and 2.5 GB to build the IDE agent. The Xcode agent needs Xcode 27 (tested with 27.0 and the 27 beta).

**Where to put the project:** clone it into a normal folder such as `~/Developer`, **not** `~/Downloads`, `~/Desktop` or `~/Documents`. macOS privacy protection covers those three, so it asks extra permission prompts and can block agents that Xcode starts:

```bash
git clone https://github.com/techguy0711/privacy-first-local-AI-harness.git ~/Developer/privacy-first-local-AI-harness
cd ~/Developer/privacy-first-local-AI-harness
```

**Local or shared server:** the steps below run everything on your own Mac (`MODE=local`). `MODE=server` is for setting up the shared server machine itself. It downloads Llama 3.3 70B (over 40 GB), so don't use it on your laptop to connect to a team server. To join a team server, ask its administrator.

## Start here: local Mac setup

Run these commands from this project folder. Complete the [one-time prerequisites](#one-time-prerequisites) below first, and make sure Ollama is running (open the Ollama app, or run `ollama serve` in a separate terminal).

### 1. Configure local mode

For a new setup, copy the example configuration:

```bash
cp .env.example .env
```

If you already have a `.env`, keep it. Open `.env` and confirm `MODE=local`. Set `BRAVE_API_KEY` to enable web search, or leave it empty to skip search.

### 2. Install the stack and IDE support

**Use `--editors` if you want VS Code, Android Studio, or Xcode support:**

```bash
./scripts/setup.sh --editors
```

This sets up the local models (Gemma 4 12B as `coder-local`, plus `nomic-embed-text`) and Open WebUI. On macOS it also builds the IDE agent (`acp-bridge`, which Xcode, Android Studio and VS Code run) from source, which needs Rust — see the [prerequisites](#one-time-prerequisites). Nothing is written to your editors' settings; setup prints what to enter.

Every run of `setup.sh` also limits how much RAM Ollama spends caching prompts (`LLAMA_ARG_*` in `.env`; by default it could use about 8 GB, enough to push a 16 GB Mac into swap). This doesn't shorten the model's context. On macOS it adds a login item that keeps the limit after a restart. When setup says so, quit and reopen the Ollama app once.

**Read the terminal output before closing it:** the script prints the exact values to enter in Android Studio's model provider settings, the JSON for the optional Android Studio agent, the paths and environment values for registering the Xcode agent, and the settings for the VS Code agent. Finish the IDE steps below after setup.

For Web UI only, run `./scripts/setup.sh` instead.

### 3. Start the Web UI server

```bash
./scripts/stack.sh up
```

Open the `Web UI:` address it prints at the end, **[http://127.0.0.1:3000/](http://127.0.0.1:3000/)** by default. Create your first account, which becomes admin, and select `coder-local` (Gemma 4 12B).

The command starts the inference gateway, Open WebUI and, when a Brave key is set, the Brave MCP server. Ollama must already be running.

### 4. Finish the one-time Web UI settings

- The inference gateway adds [prompts/system.md](prompts/system.md) and today's date to chat requests automatically.
- **Images and files**: attach them in the message box. Screenshots and other images (PNG, JPEG or WebP, not GIF) go to the model, which reads them; documents (PDF, text, code) are read by Open WebUI on this machine and passed on as text. The gateway takes images only when they're sent inline and never fetches a link.
- With `BRAVE_API_KEY` set, `stack.sh up` adds **Brave Search** to Open WebUI and turns it on by default in new `coder-local` chats; there is nothing to configure. The model decides when to search, for example for current events or the latest version of a tool. Each message then takes longer, because the model first decides whether to search. To turn search off for one chat, click the wrench icon in the message box and switch off **Brave Search**. `stack.sh up` turns it back on as the default for new chats, even if you turned it off in **Admin Settings → Models**. Open WebUI connects to the local Brave MCP server, which holds the key, so the key never enters Open WebUI. Don't add tool connections in Admin Settings: Open WebUI forgets them at restart, because `stack.sh` makes `.env` authoritative.

### 5. Connect your IDE

The agent names identify the model and where it runs: **Gemma 4 12B (Local)** or **Llama 3.3 70B (Server)**. `coder-local` and `coder-server` are stable API names independent of the selected inference engine.

After running `./scripts/setup.sh --editors`:

| IDE | Remaining steps |
|---|---|
| **VS Code** (macOS) | Install the **ACP Client** extension (publisher formulahendry) and add the settings printed by setup to your user `settings.json`: the agent, `"acp.logTraffic": false` and `"telemetry.telemetryLevel": "off"`. This replaces Continue, which is no longer maintained; uninstall it. |
| **Android Studio** | Open **Settings → Tools → AI → Model Providers**, add the **Local Provider** (port `8787`) or, on a server, the **Third-Party Remote Provider** printed by setup, click **Refresh**, enable the model, and pick it in the **Agent** tab on the right sidebar. The gateway removes its built-in web search (Gemini), so use Open WebUI for current information (see the IDE guide). The Continue JetBrains plugin is deprecated and can no longer be installed. |
| **Android Studio agent** (preview, macOS, Android Studio 2026.2.2 Rabbit 2 or later) | Optional, in place of the Agent tab: it builds with Gradle after each change and fixes compile errors. Paste the JSON printed by setup under **Settings → Tools → AI → Agents → Add via JSON…**. |
| **Xcode agent** | Open **Settings → Intelligence → Agents → Add an Agent**. Enter the executable, arguments, and environment values printed by setup, and leave **Interpreter** empty. |

See [the IDE guide](docs/editors.md) for full instructions and Xcode's plain-chat option. The agents in VS Code and Android Studio are the same `acp-bridge` with their own settings: they edit files, build the project after each change (Cargo, Gradle, Go, Swift, TypeScript) and fix the errors. The Xcode agent edits files, builds through Xcode and fixes the errors, searches Apple's documentation on your Mac, and can use Brave search (guarded) while the stack is up. Xcode asks "Allow acp-bridge to access Xcode?" once per launch and after each rebuild — allow it.

### 6. Check the stack

```bash
./scripts/doctor.sh
```

Review any `FAIL` results before relying on the stack. This checks basic health and configuration; it is not a complete security audit. The gateway chat check can time out while an agent is generating, because the gateway runs one request at a time; re-run it when the agent is idle.

If a new Xcode agent conversation fails immediately with "JSON-RPC request … failed to produce a response", check the Xcode registration (Interpreter must be empty) and see the Xcode gotchas in [docs/editors.md](docs/editors.md).

## Everyday use: start, check, stop

Make sure Ollama is running, then start the Web UI and open the address it prints (**[http://127.0.0.1:3000/](http://127.0.0.1:3000/)** by default):

```bash
./scripts/stack.sh up
```

Check whether the Web UI and Brave MCP server are running:

```bash
./scripts/stack.sh status
```

Stop the Web UI and Brave MCP server:

```bash
./scripts/stack.sh down
```

These commands do not start or stop Ollama. If startup fails, check `logs/openwebui.log` or `logs/brave-mcp.log`.

## One-time prerequisites

`setup.sh` checks for each of these and prints install instructions rather than installing them itself — install them first:

- **Ollama**: https://ollama.com/download, or `brew install ollama`.
- **Homebrew** (if not already present — check with `command -v brew`): the official installer needs `sudo` interactively (it creates `/opt/homebrew`), so it can't be scripted by an agent/CI; run it yourself in a real terminal:
  ```bash
  zsh ./scripts/install-homebrew.sh
  ```
  (a local copy of the official `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` installer — equivalent to piping that URL straight into bash, kept here so onboarding doesn't depend on fetching it fresh each time). Then add it to your shell (the installer prints the exact line; on Apple Silicon it's `eval "$(/opt/homebrew/bin/brew shellenv)"`, which needs to go in `~/.zprofile` to persist across terminal sessions).
- **`uv` and Node.js** (Node provides `npx`, used to run the Brave MCP server): `brew install uv node`.
- **Rust 1.86 or newer** (only for `--editors` on macOS, to build the IDE agent for Xcode, Android Studio and VS Code): install it with rustup (https://rustup.rs) — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` — then open a new terminal. If Rust is already installed, run `rustup update`.


## Re-running setup or refreshing IDE support

Run `./scripts/setup.sh` to apply setup again. To refresh IDE configuration, run:

```bash
./scripts/setup.sh --editors
```

The editor option rebuilds the IDE agent (`acp-bridge`) only when its pinned version, commit, or patch changed, or `bin/acp-bridge` was replaced (Xcode then asks to allow it again). Setup pulls a model only when it isn't installed and never re-checks Ollama's registry, so models change only when you pull one yourself; after `ollama pull gemma4:12b`, rebuild `coder-local` on it with `ollama create coder-local -f Modelfile.local`. When `OPEN_WEBUI_VERSION` in `.env` changes, setup rebuilds Open WebUI's venv and keeps `data/`; see [upgrading Open WebUI](docs/server.md#upgrade-open-webui). Review the terminal output for any remaining manual steps, especially Xcode registration. If you move this project folder, update the agent paths in Xcode, Android Studio and VS Code.

## Shared server setup

For the shared `coder-server` deployment, see [docs/server.md](docs/server.md). That guide covers `MODE=server`, provisioning, TLS, and per-user API keys. Local setup above uses `MODE=local`.

## Project rules and privacy

See [AGENTS.md](AGENTS.md) for the project rules, [docs/privacy.md](docs/privacy.md) for the existing privacy notes and earlier network observations, and [docs/editors.md](docs/editors.md) for detailed IDE setup.

## Running the tests (no GPU needed)

After `./scripts/setup.sh` has created `.venv/openwebui`:

```bash
.venv/openwebui/bin/python -m unittest discover -s tests -v
```

These tests use in-process fake inference responses, with no downloads or network calls.
For live queue testing use the existing local Ollama model with `QUEUE_ACTIVE=1`.
The IDE agents use `LLM_QUEUE=1` to show waiting/running status and reconnect to
jobs. Open WebUI and the IDEs' plain-chat providers receive standard streaming
responses and keepalives; they don't display queue positions. See [editor limitations](docs/editors.md).
