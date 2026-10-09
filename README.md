# Self-hosted AI coding stack

Run a local coding assistant on your Mac with Ollama, Open WebUI, Brave Search (MCP), and IDE support through Continue or Xcode ACP.

## Start here: local Mac setup

Run these commands from this project folder. Complete the [one-time prerequisites](#one-time-prerequisites) below first, and make sure Ollama is running (open the Ollama app, or run `ollama serve` in a separate terminal).

### 1. Configure local mode

For a new setup, copy the example configuration:

```bash
cp .env.example .env
```

If you already have a `.env`, keep it. Open `.env` and confirm `MODE=local`. Set `BRAVE_API_KEY` to enable web search, or leave it empty to skip search.

### 2. Install the stack and IDE support

**Use `--editors` if you want VS Code, Android Studio / JetBrains, or Xcode support:**

```bash
./scripts/setup.sh --editors
```

This sets up the local models and Open WebUI, backs up and writes `~/.continue/config.yaml`, and copies the Brave key into this project's gitignored `.continue/.env`. On macOS it also downloads `acp-bridge` for Xcode.

**Read the terminal output before closing it:** the script prints the exact paths and environment values to enter when registering the Xcode agent. Finish the IDE steps below after setup.

For Web UI only, run `./scripts/setup.sh` instead.

### 3. Start the Web UI server

```bash
./scripts/stack.sh up
```

Open **[http://127.0.0.1:3000](http://127.0.0.1:3000)** in your browser (use your `WEBUI_PORT` if you changed it). Create your first account, which becomes admin, and select `coder-local`.

The command starts Open WebUI and, when a Brave key is set, the Brave MCP server. Ollama must already be running.

### 4. Finish the one-time Web UI settings

- In **Workspace → Models**, configure `coder-local` with the contents of [prompts/system.md](prompts/system.md), including the search privacy instructions.
- If you enabled Brave search, go to **Settings → Admin Settings → Integrations → Add Connection**, choose **MCP (Streamable HTTP)**, and enter `http://127.0.0.1:8765`.

### 5. Connect your IDE

After running `./scripts/setup.sh --editors`:

| IDE | Remaining steps |
|---|---|
| **VS Code** | Install the Continue extension. Turn off **Allow Anonymous Telemetry** in Continue and **Continue: Telemetry Enabled** in VS Code settings. |
| **Android Studio / JetBrains** | Install the Continue plugin. Turn off **Allow Anonymous Telemetry** in Continue settings. |
| **Xcode agent** | Open **Settings → Intelligence → Agents → Add an Agent**. Enter the executable, arguments, and environment values printed by setup. |

See [the IDE guide](docs/editors.md) for full instructions and Xcode's plain-chat option. The Xcode agent can edit files and run tools, but has no Brave search or Xcode-native build tools.

### 6. Check the stack

```bash
./scripts/doctor.sh
```

Review any `FAIL` results before relying on the stack. This checks basic health and configuration; it is not a complete security audit.

## Everyday use: start, check, stop

Make sure Ollama is running, then start the Web UI and open **[http://127.0.0.1:3000](http://127.0.0.1:3000)**:

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


## Re-running setup or refreshing IDE support

Run `./scripts/setup.sh` to apply setup again. To refresh IDE configuration, run:

```bash
./scripts/setup.sh --editors
```

The editor option backs up and rewrites the Continue configuration and secrets file. Review the terminal output for any remaining manual steps, especially Xcode registration. If you move this project folder, update Xcode's executable and arguments paths.

## Shared server setup

For the shared `coder-server` deployment, see [docs/server.md](docs/server.md). That guide covers `MODE=server`, provisioning, TLS, and per-user API keys. Local setup above uses `MODE=local`.

## Project rules and privacy

See [AGENTS.md](AGENTS.md) for the project rules, [docs/privacy.md](docs/privacy.md) for the existing privacy notes and earlier network observations, and [docs/editors.md](docs/editors.md) for detailed IDE setup.
# privacy-first-local-AI-harness
