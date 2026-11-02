# Self-hosted AI coding stack

[![Tests](https://github.com/techguy0711/privacy-first-local-AI-harness/actions/workflows/test.yml/badge.svg)](https://github.com/techguy0711/privacy-first-local-AI-harness/actions/workflows/test.yml)

A coding assistant that runs open-weight models on your own hardware: one Mac (`MODE=local`) or a shared server for a team (`MODE=server`). Developers use it in the browser through Open WebUI, and in Xcode, Android Studio and VS Code through an agent that edits, builds and fixes code.

- **What it is**: setup scripts and configuration around Ollama (Gemma 4 12B on a Mac, Llama 3.3 70B on a server), an inference gateway with bounded per-user queues, Open WebUI, optional Brave Search (MCP), and an ACP agent (`acp-bridge`) for the IDEs. Only [allowlisted models](AGENTS.md#hard-rules) run; models of Chinese origin and anything derived from them are excluded.
- **What leaves the machine**: at runtime, only Brave Search API calls, and only with a Brave key set. Setup downloads the models and software once. The IDEs and the browser still contact their own vendors. Details and evidence: [docs/privacy.md](docs/privacy.md).
- **What it isn't**: a product, a hosted service or an authorized system. Local models make mistakes, so review generated code as you would any contribution. The IDE agents run the shell commands the model writes without a sandbox, once you allow each one in the IDE ([approving commands](docs/editors.md#approving-commands)), so read what you approve.
- **What the deploying organization owns**: the authorization (an ATO or a CMMC assessment), sign-in with MFA, TLS and network egress rules, log retention, and the policy decisions: whether to allow Brave Search, which code the agents may work on, and how OMB M-26-04 applies to each model. [docs/compliance.md](docs/compliance.md) maps the stack to U.S. federal requirements and lists the rest.

See [server setup and Mac testing](docs/server.md) for Ollama deployment and queue limitations, and [how this compares](docs/comparison.md) for similar projects and what this stack does differently.

## Before you start

**What you need (local mode):** a Mac with at least 16 GB of memory (tested on an Apple Silicon Mac with 16 GB) and about 15.5 GB of free disk: 8 GB for the model, 2 GB for Open WebUI, 0.5 GB for the voice-input model, and 2.5 GB to build the IDE agent. The Xcode agent needs Xcode 27 (tested with 27.0 and the 27 beta).

**Where to put the project:** clone it into a normal folder such as `~/Developer`, **not** `~/Downloads`, `~/Desktop` or `~/Documents`. macOS privacy protection covers those three, so it asks extra permission prompts and can block agents that Xcode starts:

```bash
git clone https://github.com/techguy0711/privacy-first-local-AI-harness.git ~/Developer/privacy-first-local-AI-harness
cd ~/Developer/privacy-first-local-AI-harness
```

**Local or shared server:** the steps below run everything on your own Mac (`MODE=local`). `MODE=server` is for setting up the shared server machine itself. It downloads Llama 3.3 70B (over 40 GB), so don't use it on your laptop to connect to a team server. To join a team server, ask its administrator.

## Start here: local Mac setup

Run these commands from this project folder. Complete the [one-time prerequisites](#one-time-prerequisites) below first, and make sure Ollama is running (open the Ollama app, or run `ollama serve` in a separate terminal).

### 1. Configure local mode

For a new setup, copy the example configuration, readable only by you since it will hold your keys:

```bash
cp .env.example .env && chmod 600 .env
```

If you already have a `.env`, keep it. Open `.env` and confirm `MODE=local`. Set `BRAVE_API_KEY` to enable web search, or leave it empty to skip search.

### 2. Install the stack and IDE support

**Use `--editors` if you want VS Code, Android Studio, or Xcode support:**

```bash
./scripts/setup.sh --editors
```

This sets up the local models (Gemma 4 12B as `coder-local`, plus `nomic-embed-text`), Open WebUI, and the Whisper small model for Open WebUI's voice input (downloaded once to `data/whisper/` and checked against pinned hashes). On macOS it also builds the IDE agent (`acp-bridge`, which Xcode, Android Studio and VS Code run) from source, which needs Rust — see the [prerequisites](#one-time-prerequisites). Nothing is written to your editors' settings; setup prints what to enter. Each run also writes a software bill of materials of everything it installed to `build/sbom.cdx.json` (CycloneDX).

Setup also tunes Ollama's memory use for a 16 GB Mac: a smaller prompt cache, an 8-bit context cache and two conversation slots, none of which shortens the model's context ([details](docs/server.md#configuration-reference); override them in `.env`). A login item keeps them after a restart. When setup says so, quit and reopen the Ollama app once.

**Read the terminal output before closing it:** the script prints the exact values to enter in Android Studio's model provider settings, the JSON for the optional Android Studio agent, the paths and environment values for registering the Xcode agent, and the settings for the VS Code agent. Finish the IDE steps below after setup.

For Web UI only, run `./scripts/setup.sh` instead.

### 3. Start the Web UI server

```bash
./scripts/stack.sh up
```

Open the `Web UI:` address it prints at the end, **[http://127.0.0.1:3000/](http://127.0.0.1:3000/)** by default. Create your first account, which becomes admin, and select `coder-local` (Gemma 4 12B).

The command starts the inference gateway, Open WebUI and, when a Brave key is set, the Brave MCP server. Ollama must already be running.

### 4. Use the Web UI

There is nothing more to configure:

- **Images and files**: attach them in the message box. The model reads screenshots and other images (PNG, JPEG or WebP, not GIF); Open WebUI reads documents (PDF, text, code) on this machine and passes them on as text.
- **Voice**: the microphone button dictates and the call button starts voice mode. Your speech becomes text on this machine, each recording is deleted once transcribed, and your browser's built-in voices read the replies aloud. In **Settings → Audio**, keep both engines on **Default** and leave **Allow non-local voices** off: the other choices send your audio or the replies to Google, Apple or Hugging Face ([details](docs/privacy.md#voice-input-and-spoken-replies)).
- **Web search** (with `BRAVE_API_KEY` set): **Brave Search** is on in new chats, and the model decides when to search, for example for the latest version of a tool, so each message takes a little longer. To turn it off for one chat, click the wrench icon in the message box. The key stays with the local Brave server, never in Open WebUI.

`stack.sh up` sets the rest at each start, so changes made in **Admin Settings** to these don't last: the gateway adds [prompts/system.md](prompts/system.md) and today's date to every chat; Brave Search, when set up, is the default tool and Open WebUI's 23 built-in tools (notes, calendar, memory and more) are off, since they slowed every message (attached files and Knowledge are still read); suggested prompts and follow-ups are off; and chat titles and tags are made without the model's thinking, in their own conversation slot, so they don't slow your next reply ([details](docs/server.md#configuration-reference)). Don't add tool connections in Admin Settings either: Open WebUI forgets them at restart.

### 5. Connect your IDE

The agent names identify the model and where it runs: **Gemma 4 12B (Local)** or **Llama 3.3 70B (Server)**. `coder-local` and `coder-server` are stable API names independent of the selected inference engine.

After running `./scripts/setup.sh --editors`:

| IDE | Remaining steps |
|---|---|
| **VS Code** (macOS) | Install the **ACP Client** extension by Jun Han (ID `formulahendry.acp-client`) and add the settings printed by setup to your user `settings.json` (Command Palette → **Preferences: Open User Settings (JSON)**; the extension has no settings page of its own): the agent, `null` for each of the extension's built-in cloud agents so they can't start, `"acp.logTraffic": false` and `"telemetry.telemetryLevel": "off"`. This replaces Continue, which is no longer maintained; uninstall it. |
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

Check whether the inference gateway, Web UI and Brave MCP server are running:

```bash
./scripts/stack.sh status
```

Stop the inference gateway, Web UI and Brave MCP server:

```bash
./scripts/stack.sh down
```

These commands do not start or stop Ollama. If startup fails, check `logs/gateway.log`, `logs/openwebui.log` or `logs/brave-mcp.log`.

## One-time prerequisites

`setup.sh` checks for each of these and prints install instructions rather than installing them itself — install them first:

- **Ollama**: https://ollama.com/download, or `brew install ollama`.
- **Homebrew** (if not already present — check with `command -v brew`): the official installer needs `sudo` interactively (it creates `/opt/homebrew`), so it can't be scripted by an agent/CI; run it yourself in a real terminal:
  ```bash
  zsh ./scripts/install-homebrew.sh
  ```
  (a local copy of the official `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` installer — equivalent to piping that URL straight into bash, kept here so onboarding doesn't depend on fetching it fresh each time). Then add it to your shell (the installer prints the exact line; on Apple Silicon it's `eval "$(/opt/homebrew/bin/brew shellenv)"`, which needs to go in `~/.zprofile` to persist across terminal sessions).
- **`uv` and Node.js** (Node runs the Brave MCP server, which setup installs with npm from a pinned lockfile; only needed with a `BRAVE_API_KEY`): `brew install uv node`.
- **Rust 1.86 or newer** (only for `--editors` on macOS, to build the IDE agent for Xcode, Android Studio and VS Code): install it with rustup (https://rustup.rs) — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` — then open a new terminal. If Rust is already installed, run `rustup update`.


## Re-running setup or refreshing IDE support

Run `./scripts/setup.sh` to apply setup again. To refresh IDE configuration, run:

```bash
./scripts/setup.sh --editors
```

The editor option rebuilds the IDE agent (`acp-bridge`) only when its pinned version, commit, or patch changed, or `bin/acp-bridge` was replaced (Xcode then asks to allow it again). Setup pulls a model only when it isn't installed and never re-checks Ollama's registry, so models change only when you pull one yourself; after `ollama pull gemma4:12b`, rebuild `coder-local` on it with `ollama create coder-local -f Modelfile.local`. Version pins (Open WebUI, acp-bridge, Whisper) are in `scripts/runtime.sh`, not `.env`, so a `git pull` brings new ones. When `OPEN_WEBUI_VERSION` changes, setup rebuilds Open WebUI's venv and keeps `data/`, and the next start migrates its database; back up `data/openwebui` first, as in [upgrading Open WebUI](docs/server.md#upgrade-open-webui). Review the terminal output for any remaining manual steps, especially Xcode registration. If you move this project folder, update the agent paths in Xcode, Android Studio and VS Code.

## Uninstall

The stack keeps everything in this folder except what these steps remove:

1. Stop it: `./scripts/stack.sh down`.
2. Remove the IDE entries you added: the agent in Xcode (**Settings → Intelligence → Agents**); in Android Studio, the agent (**Settings → Tools → AI → Agents**, saved in `~/.android/studio/agent/acp.json`) and the provider under **Model Providers**; in VS Code, our agent under `acp.agents` in your user `settings.json`, or the ACP Client extension itself (while it's installed, keep the `null` entries: they stop its built-in cloud agents).
3. Remove Ollama's memory settings, the login item and the four values it sets, then quit and reopen the Ollama app:
   ```bash
   rm ~/Library/LaunchAgents/local-ai-harness.ollama-env.plist
   ```
   ```bash
   for v in OLLAMA_KV_CACHE_TYPE OLLAMA_NUM_PARALLEL LLAMA_ARG_CTX_CHECKPOINTS LLAMA_ARG_CACHE_RAM; do launchctl unsetenv "$v"; done
   ```
4. Remove the models, unless something else uses them (on a server: `coder-server llama3.3:70b nomic-embed-text`):
   ```bash
   ollama rm coder-local gemma4:12b nomic-embed-text
   ```
5. Delete this folder. That deletes the Open WebUI accounts, chats and uploads (`data/openwebui/`), the agents' saved conversations, the logs, the keys in `.env`, Open WebUI's venv and the built agent.

Left in place: `"disable_ollama_cloud": true` in `~/.ollama/server.json`, which keeps Ollama Cloud off (delete that line to undo it; setup saved any earlier version beside it as `server.json.<time>.bak`); the prerequisites you installed; the Python 3.11 that uv downloaded if your Mac had none (`uv python uninstall 3.11`); and the download caches of uv, npm and Cargo (`uv cache clean`, `npm cache clean --force`, `~/.cargo/registry`). On a Linux server, also remove the memory settings you added with `sudo systemctl edit ollama.service` (keep `OLLAMA_NO_CLOUD=1` to leave Ollama Cloud off).

## Shared server setup

For the shared `coder-server` deployment, see [docs/server.md](docs/server.md). That guide covers `MODE=server`, provisioning, TLS, and per-user API keys. Local setup above uses `MODE=local`. To try server mode on your Mac first, in a Linux container behind a TLS proxy, see [Test server mode on a Mac](docs/server.md#test-server-mode-on-a-mac).

## Project rules and privacy

See [AGENTS.md](AGENTS.md) for the project rules, [docs/architecture.md](docs/architecture.md) for how the components and scripts connect, [docs/privacy.md](docs/privacy.md) for what leaves the machine and the evidence for it, [docs/editors.md](docs/editors.md) for detailed IDE setup, [docs/compliance.md](docs/compliance.md) for regulated environments (federal requirements, NIST control mapping, audit logs, sign-in), and [docs/comparison.md](docs/comparison.md) for how this stack compares to similar projects. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Running the tests (no GPU needed)

After `./scripts/setup.sh` has created `.venv/openwebui`:

```bash
.venv/openwebui/bin/python -m unittest discover -s tests -v
```

They simulate inference, so they need no models, downloads or network. GitHub runs them on every push and pull request, with syntax checks of the scripts ([.github/workflows/test.yml](.github/workflows/test.yml)).

## License

Apache License 2.0 (see [LICENSE](LICENSE)). [NOTICE](NOTICE) lists the third-party material in this repository; the components setup installs keep their own licenses, listed in `build/sbom.cdx.json` and summarized in [docs/compliance.md](docs/compliance.md#software-components). Two of them aren't OSI-approved open source: Open WebUI's license forbids changing its branding in a deployment of more than 50 users without Open WebUI Inc.'s permission, and the Llama models used in server mode come under Meta's community license.
