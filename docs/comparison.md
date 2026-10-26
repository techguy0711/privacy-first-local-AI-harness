# How this compares to similar projects

A snapshot of open-source and commercial projects that overlap with this stack, checked on the web on 2026-10-25. These projects change fast: re-check a row before relying on it. Star counts are left out because the aggregator sites disagree.

## In short

Many projects cover one piece of this stack: a bundled local AI stack, a self-hosted coding server, a local coding agent, or local models in Xcode. None found combines what this stack is built around:

- a **model allowlist** that excludes models of Chinese origin and anything derived from them ([hard rule 1](../AGENTS.md#hard-rules));
- **no outbound traffic except Brave Search**, checked with live connection audits rather than assumed ([privacy.md](privacy.md));
- **source code kept out of search queries in code**, not only by prompt;
- **one inference gateway** behind Open WebUI and the agents in Xcode, Android Studio and VS Code, on one Mac or a shared server (`MODE` in `.env`).

## Similar projects

| Project | What overlaps | How it differs |
|---|---|---|
| **Bundled local stacks** | | |
| [Harbor](https://github.com/av/harbor) (Apache-2.0) | A CLI that starts Open WebUI with a local backend (llama.cpp by default; Ollama, vLLM and others), with SearXNG web search and Speaches voice as add-ons. `harbor launch` connects coding agents (Claude Code, Codex, OpenCode, VS Code and others) to the local model. | A general-purpose catalogue of backends and frontends. No model policy, no egress lockdown, no Xcode or Android Studio agent. |
| [local-ai-packaged](https://github.com/coleam00/local-ai-packaged) | A Docker Compose bundle: Ollama, Open WebUI, SearXNG, n8n, Supabase, Flowise, Langfuse, Caddy. | Built for workflow automation, not coding. No IDE integration. |
| **Self-hosted coding assistants** | | |
| [Tabby](https://github.com/TabbyML/tabby) | A self-hosted completion and chat server for teams, with IDE extensions. | Its own server and extensions, no Xcode. Its [model registry](https://tabby.tabbyml.com/docs/models/) includes DeepSeek-Coder, Qwen2.5-Coder, Qwen3 and Yi-Coder alongside StarCoder and CodeGemma. |
| Tabnine Enterprise | On-prem and air-gapped deployment, sold to regulated companies. | Commercial and closed source. The closest match for a regulated team that buys rather than builds. |
| **Local coding agents** | | |
| [`ollama launch`](https://ollama.com/blog/launch) (Ollama, 2026-01-23) | One command runs Claude Code, OpenCode, Codex or Droid on a local model. | Two of its three recommended local models are Chinese-origin (`glm-4.7-flash`, `qwen3-coder`). Terminal agents only: no gateway, prompt or search guard. |
| Goose, OpenCode | Open-source agents that run on Ollama. Goose also serves ACP to editors. | The agent only: models, policy and hardening are up to you. OpenCode was rejected here after it opened ~26 outbound connections on every launch ([privacy.md](privacy.md#xcode-acp-agent-opencode-rejected-acp-bridge-chosen-verified-live-2026-10-06)). |
| **Local models in Xcode** | | |
| [ProxyPilot](https://github.com/masterofthechaos/ProxyPilot-public) (AGPL-3.0) | A macOS proxy that lets Xcode's agent mode use Ollama, LM Studio or cloud providers. | Xcode only. Its build docs mention an optional PostHog analytics integration and Sparkle auto-updates. |
| [pi-xcode](https://cdn.jsdelivr.net/gh/ttiimmaahh/pi-xcode@main/README.md) | An ACP adapter that runs the Pi agent in Xcode 27. | Uses whatever provider Pi is configured for (its examples are cloud providers). Xcode only. |
| [Local-iOS-Agent](https://github.com/Lazizbek6766/Local-iOS-Agent) | A macOS app that runs OpenCode on a local Ollama model with XcodeBuildMCP. | Early (4 commits on 2026-10-25), defaults to a Qwen-based model, and is built on OpenCode. |
| **The IDEs themselves** | | |
| Xcode 27, Android Studio | Both connect to a locally hosted model natively; this stack's plain-chat setups use exactly that ([editors.md](editors.md)). | A direct connection skips the gateway: nothing adds [prompts/system.md](../prompts/system.md), removes Android Studio's Gemini-backed web search tool, or queues requests per user. |

The IDE agent here is built on [acp-bridge](https://github.com/BlakeHung/acp-bridge), which already describes itself as an air-gapped ACP adapter for local models. This repo pins it, audits it, and patches it (`editors/acp/acp-bridge.patch`, `queue.patch`) with the guarded Brave search, Xcode's tools, the build-and-fix loop and the gateway's job queue ([editors.md](editors.md#agent-acp-via-acp-bridge--tools-xcodes-own-tools-guarded-web-search)).

## What's specific to this stack

- **Model provenance is a rule, not a default.** Several tools above recommend or default to Qwen, DeepSeek or GLM models (Tabby's registry, `ollama launch`, Local-iOS-Agent), as did the setup guides found. Policy templates for banning them exist; no tool found enforces it.
- **Egress is checked.** Components were dropped when they were caught reaching out (OpenCode in a live connection audit, the ACP Patchbay extension from its source), and each IDE path documents what it can still send ([privacy.md](privacy.md)).
- **Search queries are filtered in code.** acp-bridge's `web_search` refuses queries holding code, paths, file names, URLs, key-like strings or names declared in the project, and caps searches per turn and per conversation.
- **One gateway for every client.** Open WebUI and the three IDEs share the same system prompt, the same removal of non-Brave web search tools, and in server mode the same per-user queues ([server.md](server.md)).
- **Xcode, Android Studio and VS Code from one agent binary**, each with a build-and-fix loop and its registration printed by `setup.sh --editors`.
- **Local or shared server with one setting**, and `doctor.sh` to check the result.
- **Evidence for a security review**: pinned and hash-checked components, a CycloneDX SBOM, metadata audit logs in server mode, and a mapping to federal requirements and NIST controls ([compliance.md](compliance.md)).

## Trade-offs

- **Model quality.** The allowlist rules out several of the strongest open-weight coding models (Qwen3-Coder, GLM, DeepSeek, Kimi), so side-by-side tests will favor stacks that use them.
- **macOS for the IDE agents.** `setup.sh --editors` builds acp-bridge on macOS only; server mode also runs on Linux.
- **The wiring matters less every release.** Ollama, Xcode and Android Studio keep making local models easier to connect. The reason to use this stack is its policy and audits, not convenience.
