# Server deployment

Deploy a shared coding assistant using Ollama and the inference gateway. Team members connect through a private HTTPS endpoint using individual Open WebUI API keys.

## Prerequisites

Install Ollama and the prerequisites in the [local setup guide](../README.md). Use hardware with enough memory for Llama 3.3 70B and the expected concurrent workload. Team access requires private DNS, TLS, and a reverse proxy. All internal services remain bound to loopback.

## 1. Configure and install

For a new installation, copy `.env.example` to `.env`. Preserve the existing file when upgrading. Set:

```dotenv
MODE=server
SERVER_HOST=ai.internal.example
QUEUE_ACTIVE=1
```

Then run:

```bash
./scripts/setup.sh --editors
```

Setup prepares the approved Ollama chat model, Nomic embeddings, the gateway, and editor configuration. Increase concurrency only after measuring the workload on the intended hardware.

## 2. Start and verify

```bash
./scripts/stack.sh up
./scripts/doctor.sh
```

Ollama runs separately through its app or service. The stack script manages the gateway, Open WebUI, and optional Brave MCP server. Their logs are under `logs/`.

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

1. Open the private HTTPS endpoint and create the administrator account.
2. Create or approve an Open WebUI account for each team member.
3. Have each member generate a personal API key in **Settings → Account → API Keys**.
4. Configure the editor with API base `https://ai.internal.example/v1` and model `coder-server:latest`.
5. Complete the client-specific steps in the [editor guide](editors.md).

The gateway validates personal keys through Open WebUI's `/api/v1/auths/` endpoint. Include that route if API-key endpoint restrictions are enabled. Pending accounts cannot submit requests.

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

## Operations

### Stop or restart

```bash
./scripts/stack.sh down
./scripts/stack.sh up
```

Restart after changing `.env`. The launcher rejects configuration changes while the existing gateway is running. A restart discards queued jobs and retained results.

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

Edit settings in `.env`; [.env.example](../.env.example) contains the complete list.

| Setting | Default | Purpose |
|---|---|---|
| `QUEUE_ACTIVE` | `1` | Maximum concurrent chat and embedding requests |
| `QUEUE_WAITING` | `32` | Maximum waiting requests |
| `QUEUE_PER_USER` | `2` | Maximum active and waiting requests per account |
| `QUEUE_WAIT_SECONDS` | `300` | Maximum time waiting for capacity |
| `INFERENCE_TIMEOUT_SECONDS` | `600` | Maximum inference duration |
| `QUEUE_RETENTION_SECONDS` | `300` | Retention after a job finishes |
| `QUEUE_MAX_JOBS` | `128` | Maximum jobs, including retained results |
| `QUEUE_MAX_BODY_BYTES` | `1048576` | Maximum request size |
| `QUEUE_MAX_RESULT_BYTES` | `4194304` | Maximum result size |

Scheduling rotates between accounts and preserves arrival order within each account. Running requests are not preempted. Queue positions may change as other accounts submit work. Capacity limits return HTTP 429 with `Retry-After`.

Open WebUI uses the gateway for chat and embeddings. Persistent WebUI configuration overrides are disabled; environment-controlled settings are reapplied on restart. WebUI requests without forwarded user identity share the internal service quota.

## Client and API behavior

| Client | Queue behavior |
|---|---|
| Xcode ACP with `LLM_QUEUE=1` | Separate activity notifications, job polling, reconnects, and cancellation |
| Continue | Standard streaming with keepalives; no queue-position display |
| Xcode plain chat | Standard completion API; no job-reconnect integration |

Standard clients use `/v1/chat/completions` and `/v1/embeddings`. Streaming keepalives are SSE comments and do not become assistant text. Disconnecting a standard request cancels it. Failures after streaming begins are reported in the stream because the HTTP response has already started.

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

- [Editor configuration](editors.md)
- [Privacy and outbound traffic](privacy.md)
