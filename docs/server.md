# Server deployment

Deploy a shared coding assistant using Ollama and the inference gateway. Team members connect through a private HTTPS endpoint using individual Open WebUI API keys.

## Prerequisites

Install Ollama and the prerequisites in the [local setup guide](../README.md). Use hardware with enough memory for Llama 3.3 70B and the expected concurrent workload. Team access requires private DNS, TLS, and a reverse proxy. All internal services remain bound to loopback.

## 1. Configure and install

For a new installation, copy `.env.example` to `.env`. Preserve the existing file when upgrading. Set:

```dotenv
MODE=server
SERVER_HOST=ai.internal.example
```

Then run:

```bash
./scripts/setup.sh --editors
```

Setup prepares the approved Ollama chat model, Nomic embeddings, the Whisper model for Open WebUI's voice input, the gateway, and editor configuration. Increase concurrency (`QUEUE_ACTIVE`, 1 by default) only after measuring the workload on the intended hardware.

## 2. Start and verify

```bash
./scripts/stack.sh up
./scripts/doctor.sh
```

Ollama runs separately through its app or service. The stack script manages the gateway, Open WebUI, and optional Brave MCP server. Their logs are under `logs/`.

On Linux, `setup.sh` prints the `systemctl edit ollama.service` lines that give the Ollama service its memory settings (`OLLAMA_KV_CACHE_TYPE`, `OLLAMA_NUM_PARALLEL`, `LLAMA_ARG_CTX_CHECKPOINTS`, `LLAMA_ARG_CACHE_RAM`; defaults in `services/config.py`, overridable in `.env`), and `doctor.sh` checks the service has them. On a server with spare RAM and several users, raise `LLAMA_ARG_CACHE_RAM` so more conversations stay cached between turns.

## 3. Configure private HTTPS access

Expose only the reverse proxy to the team network or VPN. On AWS, allow inbound TCP 443 from the team network and TCP 22 from administrator addresses. Do not expose the internal service ports directly.

Configure the proxy with these routes:

| Public route | Internal destination |
|---|---|
| `/v1/*` | Gateway at `127.0.0.1:8787` |
| All other paths | Open WebUI at `127.0.0.1:3000` |

Example Caddy configuration, using the default ports:

```caddy
ai.internal.example {
    handle /v1/* {
        reverse_proxy 127.0.0.1:8787 {
            flush_interval -1
        }
    }
    handle {
        reverse_proxy 127.0.0.1:3000
    }
}
```

Replace the hostname and configure certificate issuance through the team's certificate authority. Set proxy and client deadlines longer than the combined queue and inference limits—900 seconds with the default settings. Disable response buffering for streaming routes.

When upgrading from the direct Ollama proxy configuration, remove `/ollama-embed`. Embeddings now use the authenticated gateway.

## 4. Grant team access

1. Open the private HTTPS endpoint and create the administrator account. In server mode new passwords need at least 15 characters and logins last 12 hours; to sign people in through your identity provider (OIDC, with MFA) instead, see [Identity](compliance.md#identity-sign-in-and-sessions).
2. Create or approve an Open WebUI account for each team member.
3. Have each member generate a personal API key in **Settings → Account → API Keys**.
4. Configure the editor with API base `https://ai.internal.example/v1` and model `coder-server:latest`.
5. Complete the client-specific steps in the [editor guide](editors.md).

In server mode `stack.sh` turns on API keys for every account (`ENABLE_API_KEYS`, `USER_PERMISSIONS_FEATURES_API_KEYS`; both off by default since Open WebUI 0.12, and an Admin-panel change would not survive a restart). The gateway validates personal keys through Open WebUI's `/api/v1/users/user/status` endpoint; include that route if API-key endpoint restrictions are enabled (`ENABLE_API_KEYS_ENDPOINT_RESTRICTIONS`, `API_KEYS_ALLOWED_ENDPOINTS`). Pending accounts cannot submit requests.

Open WebUI's own chat lists `coder-server` to administrators only until an administrator grants access to the model (Settings → Admin → Models, where it is marked Private): `stack.sh` creates its entry private, as Open WebUI does for models without one. IDE access through the gateway does not depend on this.

`GATEWAY_SERVICE_KEY` is an internal credential for Open WebUI. Do not distribute it to team members. Keep secrets in the gitignored `.env` files described in the editor guide.

## 5. Verify before rollout

On the target hardware, verify:

- Chat completions and tool calls work with the selected checkpoint.
- Requests from separate accounts are queued and processed fairly.
- Cancelling queued and running requests releases their capacity.
- An interrupted Xcode queue connection resumes the same job.
- Expected concurrent usage stays within acceptable latency and memory limits.

Increase `QUEUE_ACTIVE` only after measuring the server under representative coding workloads. Run one gateway worker; multiple workers do not share queue state.

For unattended operation, configure process supervision with launchd on macOS or systemd on Linux. Preserve the working directory and environment used by `stack.sh`. The scripts do not provide automatic restart supervision or high availability.

## Test server mode on a Mac

`server-test/` runs server mode on a 16 GB Mac, in a Linux container, the way an administrator sets up the real server: a Debian 13 box with the prerequisites installed, `.env` with `MODE=server`, then `./scripts/setup.sh --editors` and `./scripts/stack.sh up` as an unprivileged account, and Caddy as the TLS proxy with the routes above. Only the proxy is published, on the Mac's loopback: **https://localhost:8443/** (`SERVER_HOST=localhost:8443`). It is a test setup, not a way to deploy.

Two things differ from a real server:

- **Ollama runs on the Mac**, which has the GPU; the container forwards its `127.0.0.1:11434` to it. Docker on a Mac has no GPU, so Ollama inside the container would be slow.
- **`coder-server` is built on Llama 3.1 8B** (`server-test/Modelfile.server`, which replaces `Modelfile.server` in the container), because Llama 3.3 70B doesn't fit 16 GB. It uses the same chat template and tool-call format, and the same 16K context. `setup.sh` creates it in the Mac's Ollama; `ollama rm coder-server` removes it. It is much weaker with tools: given Brave Search (2026-10-26), it got a search through in 3 of 10 tries. The rest sent arguments of the wrong type, which the Brave server refuses, or wrote the call out as text. `coder-local` (Gemma 4 12B), through the same gateway, system prompt and Brave server, got 3 of 3. So expect search in the test server to fail often; that says nothing about the stack.

### Start it

You need Ollama running on the Mac with `llama3.1:8b` and `nomic-embed-text` pulled, and a container runtime. Tested with Colima 0.10.3 (open source, no telemetry): `brew install colima docker docker-compose`, then `colima start --cpu 4 --memory 4`. Homebrew's Compose works as `docker-compose`; for `docker compose`, add the `cliPluginsExtraDirs` line that `brew info docker-compose` shows to `~/.docker/config.json`. Docker Desktop and OrbStack work too.

From the repo root:

```bash
docker compose -f server-test/compose.yaml up -d --build
```

```bash
docker compose -f server-test/compose.yaml logs -f
```

Building the image takes about 6 minutes, mostly downloading Ollama's Linux release for its CLI. The first start takes another 10 to 15 minutes: it installs Open WebUI (6.6 GB on Linux, 4.2 GB of it PyTorch's CUDA libraries) and downloads the Whisper model. It is ready when the log shows `Test server: https://localhost:8443/`. Later starts take about 15 seconds. The container and its volume use about 9 GB inside Colima's VM. Before chatting, run `ollama stop coder-local` if it is loaded: on 16 GB the two models don't fit in memory together (`coder-server` takes 7.1 GB).

### Use it

The certificate comes from Caddy's own local CA, which only this container has. Copy its root out to use it with command-line tools:

```bash
docker compose -f server-test/compose.yaml cp server:/home/harness/.local/share/caddy/pki/authorities/local/root.crt server-test/test-ca.crt
```

A browser shows a certificate warning for https://localhost:8443/; accept it for this site, or add `server-test/test-ca.crt` to your login keychain as trusted (and remove it when you're done testing). Then follow [step 4](#4-grant-team-access): the first account becomes the administrator, passwords need 15 characters, and each account can create an API key. Add the other accounts in **Admin Panel → Users**: Open WebUI closes sign-ups once the administrator exists, though only until the next restart, after which anyone who reaches the page can sign up again as a pending account (it can create an API key, which the gateway refuses until an administrator approves the account). To try a key:

```bash
curl --cacert server-test/test-ca.crt -H "Authorization: Bearer sk-..." https://localhost:8443/v1/models
```

Run the checks inside the container, where they see what the server sees:

```bash
docker compose -f server-test/compose.yaml exec server ./scripts/doctor.sh
```

The Ollama checks there describe the container, not the Mac's Ollama (its Ollama Cloud and memory settings come from the Mac's own `setup.sh`).

### Change it

| To | Run |
|---|---|
| Edit the server's `.env` (for example `BRAVE_API_KEY` or `QUEUE_ACTIVE`), then apply it | `docker compose -f server-test/compose.yaml exec server nano .env`, then `docker compose -f server-test/compose.yaml restart server` |
| Test a change to the repo | `docker compose -f server-test/compose.yaml up -d --build`: the container copies the new files into its checkout and runs `setup.sh` again |
| Read a service's log | `docker compose -f server-test/compose.yaml exec server tail -f logs/gateway.log` (also `logs/openwebui.log`, `logs/gateway-audit.log`) |
| Stop it, keeping accounts and chats | `docker compose -f server-test/compose.yaml down` |
| Start over from an empty server | `docker compose -f server-test/compose.yaml down -v` (deletes the accounts, chats, keys, the test CA and the installed Open WebUI, so the next start is a first start again) |
| Free the VM's memory when you're done | `docker compose -f server-test/compose.yaml down`, then `colima stop` |

The server's `.env`, its data and its logs live in a Docker volume (the `harness` account's home, with the checkout in `~/stack`), never in this repo; the image is built from the files a fresh clone has (`.dockerignore`, and the build stops if `.env` or `data/` got in), so the Mac's `.env` and chats stay out of it.

**IDE agents.** Register the agent as `./scripts/setup.sh --editors` prints it on the Mac (local mode), with these environment values instead: `LLM_BASE_URL=https://localhost:8443/v1`, `LLM_MODEL=coder-server:latest`, `LLM_MODEL_CONTEXT=16384`, `LLM_API_KEY` set to your personal key from the test server, and `SSL_CERT_FILE` set to the full path of `server-test/test-ca.crt`; `LLM_QUEUE` and `LLM_TIMEOUT` stay as printed. Instead of `SSL_CERT_FILE` you can trust that certificate in your login keychain; with the repo under `~/Downloads`, macOS may first ask whether acp-bridge may read the file. Checked on 2026-10-26 by driving the VS Code agent's config over ACP: a turn completed through the queue, and without the certificate the agent stopped at once with `invalid peer certificate: UnknownIssuer` ([editor guide](editors.md#queue-aware-xcode-transport-2026-10-11), "Server certificates"). Not yet tried from Xcode, Android Studio or VS Code themselves.

## Operations

### Stop or restart

```bash
./scripts/stack.sh down
./scripts/stack.sh up
```

Restart after changing `.env`. The launcher rejects configuration changes while the existing gateway is running. A restart discards queued jobs and retained results.

### Upgrade Open WebUI

The pin is `OPEN_WEBUI_VERSION` in `scripts/runtime.sh`, so it arrives with a `git pull`, together with the changes verified against it. Before running setup after a pull that changes it: stop the stack and back up `data/openwebui` (its database migrations can't be undone). Then run `./scripts/setup.sh` (it rebuilds the venv; `data/` is kept), and start the stack, which migrates the database.

### Change deployment mode

`MODE=local` uses `coder-local:latest` based on Gemma 4 12B. `MODE=server` uses `coder-server:latest` based on Llama 3.3 70B. Both use Ollama. Server mode requires hardware sized for the 70B model; do not use it for a 16GB Mac test.

After changing `MODE`, rerun setup to prepare the selected model and regenerate editor configuration where needed.

### Test queues locally

Use an existing [local Ollama installation](../README.md#start-here-local-mac-setup) with `QUEUE_ACTIVE=1`. Configure the Xcode agent as described in the [editor guide](editors.md#queue-aware-xcode-transport-2026-10-11), then submit two requests and cancel one while it is waiting.

Local IDE requests share one user identity. For automated tests covering separate users, reconnects, overload, and cancellation:

```bash
.venv/openwebui/bin/python -m unittest discover -s tests -v
```

These tests use simulated inference responses and require no model downloads.

## Configuration reference

Edit settings in `.env`. [.env.example](../.env.example) lists every one; the tuning settings below are commented out at their defaults, so uncomment a line to override it. Version pins are not settings: they are in `scripts/runtime.sh` and `services/brave-mcp/package-lock.json`.

| Setting | Default | Purpose |
|---|---|---|
| `QUEUE_ACTIVE` | `1` | Maximum concurrent chat and embedding requests |
| `QUEUE_WAITING` | `32` | Maximum waiting requests |
| `QUEUE_PER_USER` | `2` | Maximum active and waiting requests per account |
| `QUEUE_WAIT_SECONDS` | `300` | Maximum time waiting for capacity |
| `INFERENCE_TIMEOUT_SECONDS` | `600` | Maximum inference duration |
| `QUEUE_RETENTION_SECONDS` | `300` | Retention after a job finishes |
| `QUEUE_MAX_JOBS` | `128` | Maximum jobs, including retained results |
| `QUEUE_MAX_BODY_BYTES` | `1048576` | Maximum request size, not counting inline images |
| `QUEUE_MAX_RESULT_BYTES` | `4194304` | Maximum result size |
| `QUEUE_MAX_IMAGE_BYTES` | `16777216` | Inline images per chat request (decoded); waiting requests hold theirs in RAM, so lower it on a busy server. `0` refuses images |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Ollama's KV cache (the model's context memory) in 8 bits; `f16` or empty keeps Ollama's default. Applied by `setup.sh` with the `LLAMA_ARG_*` cache limits; restart Ollama afterwards |
| `OLLAMA_NUM_PARALLEL` | `2` | Conversation slots per model, each with its own KV cache. Applied by `setup.sh` like the line above. On a shared server, raise it to keep more users' conversations cached, as memory allows. Requests beyond it wait inside Ollama, so a `QUEUE_ACTIVE` above it adds no concurrency |
| `LLAMA_ARG_CACHE_RAM` | `512` | MiB of RAM for saved prompt states (llama-server's prompt cache); with `LLAMA_ARG_CTX_CHECKPOINTS` (`4`) |
| `GATEWAY_AUDIT_LOG` | on in server mode | One JSON line per request and per finished job in `logs/gateway-audit.log` (time, account, endpoint, model, outcome; no content). `0` turns it off |
| `AUDIT_LOG_LEVEL` | `METADATA` in server mode | Open WebUI's audit log of sign-in attempts and changes, without bodies, in `data/openwebui/audit.log`. `NONE` turns it off |
| `JWT_EXPIRES_IN` | `12h` in server mode | Login lifetime (Open WebUI's own default is `4w`) |
| `ENABLE_PASSWORD_VALIDATION` | `true` in server mode | New passwords need 15+ characters (`PASSWORD_VALIDATION_REGEX_PATTERN='^.{15,}$'`) |
| `WEBUI_SESSION_COOKIE_SECURE` | `true` in server mode | Login cookies over HTTPS only |

The last five apply in server mode unless `.env` sets them; [compliance notes](compliance.md) explain each, and how to sign users in through your identity provider (OIDC) instead.

**KV cache in 8 bits (measured 2026-10-24, `coder-local` on a 16 GB Mac, Ollama 0.35).** Ollama passes `--cache-type-k q8_0 --cache-type-v q8_0` to llama-server, which needs flash attention (on automatically). The KV cache went from 1,092 to 580 MiB and each context checkpoint from 320 to 170 MiB (up to 4 are kept), so 0.5 to 1.1 GB less in all. Speed showed no consistent difference. Output is not identical: with fixed sampling (temperature 0, fixed seed), f16 repeated itself exactly on 4 prompts, and q8_0 matched it on a short prompt and a 6,400-token one but chose a different word early on 5,300- and 11,300-token prompts ("document" for "report") and continued from there. No loss of quality was visible; Ollama's FAQ calls it "a very small loss in precision" that "usually has no noticeable impact". `q4_0` (a quarter of the memory) has a larger loss and wasn't tested. The model's weights (7 GB) and context length are unchanged.

**Open WebUI's background calls (measured 2026-10-24, same Mac).** After each reply Open WebUI asks the model for suggested next messages, and for a title and tags early in a chat. gemma4 thinks by default, so each took 54 s to over 2 minutes, and with one slot it replaced the conversation in the model's cache: the next reply re-read the whole conversation, 8,500 to 12,700 tokens in 33 to 113 s, most of it Open WebUI's tool definitions (its 23 built-in tools, about 4,000 tokens, have been off since 2026-10-26; see [privacy notes](privacy.md)). `stack.sh` now sends these calls with `reasoning_effort: "none"` (`TASK_MODEL_PARAMS`, which reaches only Open WebUI's task calls: title, tags, suggestions, search and document-search keywords, plus image prompts and autocomplete, both unused here), and `OLLAMA_NUM_PARALLEL=2` gives them their own slot. Replayed on a temporary Ollama: the suggestions call took 11.7 s and returned 5 usable suggestions, and the next reply processed its 7,259-token prompt in 0.8 s instead of reading it again. Chat replies, including tool calls such as Brave Search, still think. The second slot adds 527 MiB of KV cache, offset by `LLAMA_ARG_CACHE_RAM` going from 1024 to 512 MiB. Since 2026-10-25 `stack.sh` turns the suggested next messages off altogether (`ENABLE_FOLLOW_UP_GENERATION=false`, along with the starter prompts on a new chat and autocomplete), so only the title and tags calls remain.

Scheduling rotates between accounts and preserves arrival order within each account. Running requests are not preempted. Queue positions may change as other accounts submit work. Capacity limits return HTTP 429 with `Retry-After`.

Open WebUI uses the gateway for chat and embeddings. Persistent WebUI configuration overrides are disabled; environment-controlled settings are reapplied on restart. WebUI requests without forwarded user identity share the internal service quota.

## Client and API behavior

| Client | Queue behavior |
|---|---|
| ACP agents (Xcode, Android Studio, VS Code) with `LLM_QUEUE=1` | Separate activity notifications, job polling, reconnects, and cancellation |
| Open WebUI, Android Studio model providers | Standard streaming with keepalives; no queue-position display |
| Xcode plain chat | Standard completion API; no job-reconnect integration |

Standard clients use `/v1/chat/completions` and `/v1/embeddings`. Chat requests may include inline PNG, JPEG or WebP images, budgeted separately by `QUEUE_MAX_IMAGE_BYTES`. Streaming keepalives are SSE comments and do not become assistant text. Disconnecting a standard request cancels it. Failures after streaming begins are reported in the stream because the HTTP response has already started.

Queue-aware clients use:

| Endpoint | Action |
|---|---|
| `POST /v1/jobs` | Submit a chat request with `stream=false` |
| `GET /v1/jobs/{id}` | Read status or the completed result |
| `DELETE /v1/jobs/{id}` | Cancel a queued or running request |

Supply a stable `Idempotency-Key` when submitting a job. Within its retention period, repeating the same request returns the same job; reusing the key with a different request returns HTTP 409. Only the job owner can read or cancel it.

### Limitations

- Jobs and results are stored in memory. Reconnects require the same gateway process and an unexpired job; server restarts lose them.
- A failed cancellation request can leave inference running until its deadline. Confirm GPU resource release on the selected backend.
- Multiple gateway replicas and durable job recovery are not supported.
- Automated tests do not establish server performance or IDE rendering compatibility. Complete the rollout checks on the target hardware and editor versions.

## Related documentation

- [Architecture: how the components and scripts connect](architecture.md)
- [Editor configuration](editors.md)
- [Privacy and outbound traffic](privacy.md)
- [Compliance notes for regulated environments](compliance.md)
- [Comparison with similar projects](comparison.md)
