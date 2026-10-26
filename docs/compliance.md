# Compliance notes for regulated environments

How this stack lines up with the U.S. federal requirements that come up when an agency, a contractor or another regulated organization evaluates a self-hosted AI coding assistant. Checked on 2026-10-25.

This is not legal advice, and no software is compliant on its own: an organization authorizes a system (an ATO, or a CMMC assessment) in its own environment, with its own controls around it. Use this page as input to that review. Each row says what the stack itself does and what stays with the organization that runs it.

## Federal requirements

| Requirement | What it asks | What this stack does | Left to the deploying organization |
|---|---|---|---|
| **AI from foreign adversaries.** FY2026 NDAA §1532 (DoD and its contractors); DHS FASCSA Exclusion and Removal Order 2026-01 (civilian agencies, published in the Federal Register 2026-10-20) | DoD and contractors performing DoD work may not use or acquire AI from DeepSeek, High Flyer or covered nations (China, Russia, Iran, North Korea). Civilian agencies must exclude and remove DeepSeek products and "third-party products and services developed using DeepSeek implementations"; contractors are reached through FAR 52.204-29/30. | The [model allowlist](../AGENTS.md#hard-rules) excludes every model of Chinese origin and anything derived from one, naming DeepSeek's distilled Llama models explicitly. The gateway serves only `coder-<mode>` and `nomic-embed-text` (enforced in `services/gateway.py`), and `doctor.sh` fails if Ollama holds any other model. Components that bundle models outside the allowlist are left out: `rapidocr` (Baidu's PaddleOCR models) is never installed, and faster-whisper's Silero voice-activity model is deleted. `build/sbom.cdx.json` lists every model with its SHA-256 digest. | Contractor representations under FAR 52.204-29/30. Other tools on the same machines: `doctor.sh` checks only this stack's Ollama. |
| **Domestic preference.** OMB M-25-21 and M-25-22 (April 2025) | Agencies should maximize their use of AI developed and produced in the United States. M-25-22 contracts must stop vendors from training on non-public government data. | Every model that runs by default comes from a U.S. developer (see [Models](#models)). No vendor receives prompts or code, so no vendor can train on them. | Its own sourcing determination and inventory entry (M-25-21 asks agencies to publish their AI use cases each year). |
| **Unbiased AI Principles.** EO 14319 and OMB M-26-04 (2025-12-11) | LLM procurements must include contract terms on truth-seeking and ideological neutrality, and agencies obtain documentation: acceptable use policy, model or system cards, evaluation information, and a way for end users to give feedback. Summaries of the memo say LLMs acquired under free, open-source licenses are excluded; check the memo text. | The stack is free and open source (Apache-2.0). The only text it adds to requests is [prompts/system.md](../prompts/system.md): public, short, and limited to sourcing, honesty about uncertainty and search hygiene. Model cards and licenses are linked under [Models](#models), and the derived `coder-*` models are defined in the public `Modelfile.local` and `Modelfile.server`. Open WebUI's thumbs-up/down rating on each reply is on, and ratings stay in the local database. | Whether the exclusion applies. If it treats `coder-*` as its own LLM, M-26-04 asks for similar documentation, and this page and the Modelfiles are the starting point. |
| **Secure software development.** EO 14028; OMB M-22-18 and M-23-16; NIST SP 800-218 (SSDF) | Software producers attest to secure development practices; agencies expect an SBOM and a vulnerability reporting channel. M-23-16 doesn't require an attestation for open-source software an agency obtains freely and directly. | Every upstream component is pinned: Open WebUI by version, the Brave server and its 96 dependencies by `services/brave-mcp/package-lock.json` (sha512 each), acp-bridge by commit (checked before building), Whisper by SHA-256 per file. `setup.sh` writes a CycloneDX 1.6 SBOM (`build/sbom.cdx.json`). [SECURITY.md](../SECURITY.md) gives a private reporting channel. Unit tests cover the gateway; `doctor.sh` checks the installed configuration. | Its own review of the SBOM with its scanning tools, and its patch cadence. |
| **Controlled Unclassified Information.** NIST SP 800-171; CMMC (DFARS 252.204-7012/7021, phased in from 2025-11-10) | Contractors protect CUI on their systems with the 800-171 controls; CMMC Level 2 assessments verify them. | Data never leaves the host: models run locally, local mode listens only on the loopback addresses, and data/logs are owner-only. In server mode, the audit logs and login settings below support the access control, audit and identification families. | The host system's 800-171 controls: FIPS-validated encryption in transit and at rest, MFA, configuration management and incident response. |
| **FedRAMP** | Authorization for cloud services agencies use. | Doesn't apply to the stack itself: it is software an organization runs on its own machines, not a cloud service. | If the server runs in a cloud, that cloud (IaaS) needs an authorization at the right impact level. |
| **Federal records.** Federal Records Act; NARA schedules | AI prompts and outputs can be federal records and must follow the agency's records schedule. | Open WebUI keeps chats until a user or admin deletes them. Agent conversations are deleted after `LLM_SESSION_RETENTION_DAYS` (default 30; 0 deletes on close). Voice recordings are deleted once transcribed, and the transcript stays in the chat. | Set retention to match the records schedule. Back up or export `data/` where records must be kept. |
| **Privacy.** Privacy Act; E-Government Act (PIAs) | Assess systems that handle personal information. | No telemetry, analytics, update checks or sharing in any component ([privacy.md](privacy.md)). Search queries carry no code or identifiers. The audit logs hold account IDs, and Open WebUI's also names, email addresses and source IPs; both are owner-only. | PIA, and a SORN where one applies. |
| **Accessibility.** Section 508 | ICT the agency uses must be accessible. | No conformance report (ACR/VPAT) exists for this project. The IDE agents run inside Xcode, Android Studio and VS Code, whose ACRs come from their vendors. | Its own 508 evaluation of Open WebUI. |
| **Cryptography.** FIPS 140-3 | Sensitive data in transit and at rest is protected with validated modules. | Local mode has no network traffic between components (loopback only). Server mode terminates TLS at the reverse proxy, and login cookies are sent over HTTPS only. Open WebUI hashes passwords with bcrypt, which isn't a FIPS-approved algorithm. | Run the proxy on an OS in FIPS mode. Sign users in through the organization's identity provider so no passwords are stored here (see [Identity](#identity-sign-in-and-sessions)). Use full-disk encryption. |
| **Web search.** Agency approval of external services | Data sent to an external service needs approval. | Brave Search (Brave Software, San Francisco) is the only outbound connection at runtime, and only when `BRAVE_API_KEY` is set. Every agent query passes a guard in code that refuses code, paths, file names, URLs, key-like strings and project names (at most 12 words, 3 per turn, 20 per conversation). Open WebUI's searches go through the same local server under the prompt's rule. | Approve Brave's API terms, or leave `BRAVE_API_KEY` empty. On a network with no outbound access, leave it empty and the stack makes no outbound connections at all. |

## Models

Every model that runs by default comes from a U.S. developer. Licenses as reported by each model's own metadata in Ollama and recorded in the SBOM.

| Model | Role | Developer | License | Runs by default |
|---|---|---|---|---|
| `gemma4:12b`, as `coder-local` | Chat and agents, local mode | Google DeepMind | Apache-2.0 ([terms](https://ai.google.dev/gemma/docs/gemma_4_license)) | Yes (local) |
| `llama3.3:70b`, as `coder-server` | Chat and agents, server mode | Meta | [Llama 3.3 Community License](https://www.llama.com/llama3_3/license/) | Yes (server) |
| `llama3.1:8b` | Optional chat model | Meta | [Llama 3.1 Community License](https://www.llama.com/llama3_1/license/) | No |
| `nomic-embed-text` | Embeddings for document search | Nomic AI | Apache-2.0 | Yes |
| `starcoder2:3b` | Allowlisted for autocomplete, which is off | BigCode (Hugging Face and ServiceNow) | BigCode OpenRAIL-M | No |
| Whisper small (`Systran/faster-whisper-small`) | Speech-to-text in Open WebUI | OpenAI; CTranslate2 conversion by SYSTRAN | MIT | Yes (voice input) |

Adding a model requires explicit approval ([hard rule 1](../AGENTS.md#hard-rules)). The derived `coder-*` models only set a context size on their base model (`PARAMETER num_ctx` in their Modelfiles); they aren't fine-tuned and their weights are the base model's.

## Identity, sign-in and sessions

In server mode, `stack.sh` starts Open WebUI with these defaults unless `.env` overrides them (`doctor.sh` warns about an override):

| Setting | Default | Effect |
|---|---|---|
| `JWT_EXPIRES_IN` | `12h` | A login lasts 12 hours (Open WebUI's own default is 4 weeks). |
| `ENABLE_PASSWORD_VALIDATION`, `PASSWORD_VALIDATION_REGEX_PATTERN` | `true`, `^.{15,}$` | New passwords need at least 15 characters and nothing else, following NIST SP 800-63B for passwords used as a single factor. Checked when a password is set; existing ones are unaffected. |
| `WEBUI_SESSION_COOKIE_SECURE` | `true` | The login cookie is sent only over HTTPS, which the TLS proxy provides. |
| `AUDIT_LOG_LEVEL` | `METADATA` | See [Audit logs](#audit-logs). |

New sign-ups wait for an administrator's approval (Open WebUI's `pending` role), and pending accounts can't use the gateway.

For MFA, PIV/CAC or Login.gov, connect Open WebUI to the organization's identity provider over OpenID Connect: set `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OPENID_PROVIDER_URL` and `ENABLE_OAUTH_SIGNUP=true` in `.env` (`stack.sh` passes `.env` through to Open WebUI), and `ENABLE_LOGIN_FORM=false` to turn local passwords off. The identity provider then also shows the system use notification (NIST AC-8). Open WebUI has no idle timeout of its own, so the identity provider's session policy covers inactivity.

## Audit logs

| Log | Holds | Never holds |
|---|---|---|
| `logs/gateway-audit.log` (on by default in server mode; `GATEWAY_AUDIT_LOG`) | One JSON line per request (time in UTC, account ID, method, endpoint, HTTP status, duration), including refused ones (401, 403, 429), and one per finished job (account, kind, model, final state, wait and run time). Covers every inference request from Open WebUI and the IDEs. | Prompts, code, replies, images. Tested in `tests/test_gateway.py`. |
| `data/openwebui/audit.log` (Open WebUI, `AUDIT_LOG_LEVEL=METADATA`) | Every sign-in and sign-up attempt, and every change (POST, PUT, PATCH, DELETE) by a signed-in user: time, account (ID, name, email, role), source IP, user agent, endpoint. In 0.12.3 it doesn't record whether a sign-in succeeded (checked 2026-10-25 on a test instance). | Request and response bodies, chats. |

The gateway's log rotates at midnight UTC and Open WebUI's at 10 MB; neither deletes old files. OMB M-21-31 asks agencies to keep logs for 12 months in active storage and 18 months in cold storage, so forward both files to the organization's log platform.

## NIST SP 800-53 Rev. 5

What the stack provides toward each control. The organization's own controls (policy, personnel, physical, the host OS) complete it.

| Control | Provided by the stack |
|---|---|
| AC-2 Account management | Personal Open WebUI accounts; sign-ups wait for admin approval; SSO through OIDC. |
| AC-3 Access enforcement | A user's jobs can be read or cancelled only by that user; personal API keys for the IDEs; tool connections are admin-managed and granted to signed-in users only. |
| AC-6 Least privilege | The Brave server runs with only its own key in its environment; data, logs and `.env` are owner-only; acp-bridge starts only Xcode's own tool bridge and calls four allowlisted Xcode tools, and Xcode's App Store Connect tools are refused in code. |
| AC-8 System use notification | Not in the stack: shown by the identity provider or the reverse proxy. |
| AC-12 Session termination | 12-hour logins in server mode. |
| AU-2, AU-3, AU-12 Event logging | The two audit logs above. |
| AU-9, AU-11 Audit protection and retention | Logs are owner-only and never deleted by the stack; retention is the organization's. |
| CM-2, CM-6 Baseline and settings | `.env` is authoritative (`ENABLE_PERSISTENT_CONFIG=false`), version pins are compared with `.env.example`, and `doctor.sh` checks the settings. |
| CM-7 Least functionality | Telemetry, update checks, community sharing, user webhooks, suggestions, autocomplete and Open WebUI's own web search are off. |
| CM-8 Component inventory | `build/sbom.cdx.json`. |
| CM-10, CM-11 Software usage | Model allowlist, enforced by the gateway and `doctor.sh`. |
| IA-2 Identification and authentication | Personal accounts and API keys; MFA through the organization's identity provider. |
| IA-5 Authenticator management | Passwords of 15+ characters; personal API keys checked against Open WebUI on each request. |
| SC-7 Boundary protection | Local mode: every service on loopback only (`doctor.sh` checks the listening addresses). Server mode: reachable only through the TLS proxy. |
| SC-8 Transmission confidentiality | TLS at the proxy; HTTPS-only cookies. |
| SC-28 Protection at rest | Owner-only files; full-disk encryption is the organization's. |
| SI-2 Flaw remediation | Pinned versions upgraded through `.env` and `setup.sh` (the venv is rebuilt on a version change); private vulnerability reporting ([SECURITY.md](../SECURITY.md)). |
| SI-4 System monitoring | The audit logs; `doctor.sh` exits non-zero on any failed check. |
| SI-7 Software and information integrity | SHA-256 pins for Whisper, sha512 for every npm package, a commit check before acp-bridge is built, a hash stamp for each Modelfile and patch, model digests in the SBOM. |
| SI-10 Input validation | The gateway accepts only known request fields, the configured model, text and inline PNG/JPEG/WebP images within size limits, and never fetches a URL. |
| SI-11 Error handling | Clients get generic errors ("Inference failed or response limit exceeded"); backend details stay out of responses. |
| SI-12 Information retention | Retention settings for agent conversations, voice recordings and jobs (`QUEUE_RETENTION_SECONDS`, in memory only). |
| SI-15 Output filtering | Search queries are filtered in code before they leave; web search tools that aren't Brave-backed (such as Android Studio's Gemini search) are removed from every request. |
| SR-3, SR-4, SR-11 Supply chain | Allowlist, pinned and hash-checked components, excluded bundled models, lockfile, SBOM with provenance (acp-bridge's patches are listed as such). |

## NIST AI Risk Management Framework

Against the [AI RMF](https://www.nist.gov/itl/ai-risk-management-framework) and its Generative AI Profile (NIST AI 600-1):

- **Govern**: the hard rules in [AGENTS.md](../AGENTS.md) (allowlist, no reporting out, no code in searches, loopback only) are written down and checked by `doctor.sh`.
- **Map**: the use is coding help for developers. The stack makes no decisions about people. Whether a use is "high-impact" under M-25-21 is the agency's determination.
- **Measure**: the project publishes no quality or bias evaluations of the models; the organization should test the models on its own code before relying on them.
- **Manage**: per-reply feedback, audit logs, search that can be turned off, and the agents' build-and-fix loop, which builds after each change and returns compiler errors instead of reporting success.

## Residual risks

- **Agent shell commands.** The IDE agents' `bash` tool runs the commands the model writes, in the project folder, without a sandbox or confirmation (the IDE shows each one). The prompt forbids network commands; code doesn't enforce that. Use the agents on code cleared for it and watch the commands they run ([privacy.md](privacy.md#xcode-agent-patched-acp-bridge-what-can-leave-the-mac)).
- **The IDEs' own traffic.** Xcode, Android Studio and VS Code contact their vendors for updates, feature flags and documentation indexes, separately from the model. [privacy.md](privacy.md) lists what was observed and which settings to turn off (Share Mac Analytics, Android Studio's Data Sharing, VS Code telemetry).
- **Model quality.** Local models make mistakes, and the allowlist rules out some stronger open-weight models. Review generated code as you would any contribution.
- **Not yet audited live.** Some paths are verified from source and tests only; [privacy.md](privacy.md) marks each one.

## Checklist for the deploying organization

1. Include the host and this stack in the system's authorization boundary.
2. Connect Open WebUI to the identity provider (OIDC) with MFA, turn the login form off, and show the system use notification there.
3. Run the TLS proxy on a FIPS-mode OS; turn on full-disk encryption.
4. Forward `logs/gateway-audit.log` and `data/openwebui/audit.log` to the log platform and keep them as required.
5. Set chat and agent retention to the records schedule.
6. Decide on Brave Search: approve it, or leave `BRAVE_API_KEY` empty.
7. Turn off OS and IDE analytics, and decide which repositories the agents may work in.
8. Complete the PIA, the 508 evaluation and the AI use-case inventory entry.
9. Contractors: make the FAR 52.204-29/30 representations; DoD contractors: confirm §1532 for every tool in use.
10. Run `./scripts/doctor.sh` after every change and keep `build/sbom.cdx.json` with the system's records.

## Sources

Summaries and primary documents read on 2026-10-25. Where only summaries were available, check the primary text before relying on a detail.

- OMB M-25-21 and M-25-22: [Wiley](https://www.wiley.law/alert-Trump-Administration-Revamps-Guidance-on-Federal-Use-and-Procurement-of-AI), [Sheppard Mullin](https://www.sheppard.com/insights/blogs/all-american-ai-new-omb-memos-set-priorities-for-federal-ai-use-and-acquisition)
- EO 14319: [text](https://www.presidency.ucsb.edu/documents/executive-order-14319-preventing-woke-ai-the-federal-government); OMB M-26-04: [FedScoop](https://fedscoop.com/omb-requirements-woke-ai-federal-agencies/), [Crowell](https://www.crowell.com/en/insights/client-alerts/in-bid-to-ban-woke-ai-white-house-imposes-transparency-requirements-on-contractors)
- FY2026 NDAA §1532: [CRS IF13197](https://www.congress.gov/crs-product/IF13197), [King & Spalding](https://www.kslaw.com/insights/articles/fy-2026-ndaa-domestic-sourcing-artificial-intelligence-cybersecurity-and-acquisition-reforms), [Crowell](https://www.crowell.com/en/insights/client-alerts/the-fy-2026-national-defense-authorization-act)
- DHS FASCSA Order 2026-01: [Federal Register document 2026-21447](https://public-inspection.federalregister.gov/2026-21447.pdf), [summary](https://safeguard.sh/resources/blog/dhs-fascsa-order-2026-01-deepseek-exclusion-removal-federal-suppliers)
- [NIST SP 800-53 Rev. 5](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final), [NIST SP 800-63B](https://pages.nist.gov/800-63-4/sp800-63b.html), [NIST SP 800-218](https://csrc.nist.gov/pubs/sp/800/218/final), [NIST AI 600-1](https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-generative-artificial-intelligence)
