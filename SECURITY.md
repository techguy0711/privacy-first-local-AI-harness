# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: on this repository's **Security** tab, choose **Report a vulnerability**. Please don't open a public issue for a security problem.

Include what you found, the steps to reproduce it, the affected file or setting, and the `MODE` (`local` or `server`) you tested. Reports are handled on a best-effort basis by the maintainers. You'll get an acknowledgement, and a fix or mitigation is published in the repository with credit to you unless you ask otherwise.

## Scope

In scope: this repository's own code and configuration: `scripts/`, `services/` (the inference gateway and Open WebUI function), `prompts/`, `editors/acp/` (the acp-bridge patches and configs), and the defaults they apply. Examples: a path by which data leaves the machine other than Brave Search, a service reachable from the network in local mode, a model outside the allowlist being installed or served, or the search guard letting source code into a query.

Out of scope here, report upstream instead: vulnerabilities in Ollama, Open WebUI, acp-bridge, the Brave Search MCP server, the IDEs, or the models themselves.

## Supported versions

Only the latest commit on `main` is supported. The pinned upstream versions are in `scripts/runtime.sh` (Open WebUI, acp-bridge, Whisper) and `services/brave-mcp/package-lock.json`, and `build/sbom.cdx.json` (written by `./scripts/setup.sh`) lists every installed component and its version.
