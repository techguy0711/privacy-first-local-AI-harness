# Test server for MODE=server on a Mac (docs/server.md, "Test server mode on a
# Mac"): a Debian box with what an administrator installs before
# ./scripts/setup.sh, plus Caddy as the TLS proxy. Ollama stays on the Mac
# (Metal GPU); boot.sh forwards this box's 127.0.0.1:11434 to it. Built by
# server-test/compose.yaml from the repo root.

# Only the ollama binary, for the CLI that setup.sh and doctor.sh run (the
# server is the Mac's); the tarball's GPU libraries are left out. Same version
# as the Mac's Ollama, so the CLI doesn't warn about a mismatch.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS ollama-cli
ARG OLLAMA_VERSION=0.35.0
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl zstd; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) sha=cb627d332b1fe5055bd5485ca10d595da8429e447648209e375390ec3bd09374 ;; \
      amd64) sha=1c114a6b220c5efca2ef2b1e5f01d1e535e26f6cd6d1678c8489325d2835e525 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' -o /tmp/ollama.tar.zst \
      "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-linux-$arch.tar.zst"; \
    echo "$sha  /tmp/ollama.tar.zst" | sha256sum -c -; \
    mkdir /out; \
    tar --zstd -xf /tmp/ollama.tar.zst -C /out --wildcards '*bin/ollama'; \
    rm /tmp/ollama.tar.zst

FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
# What setup.sh, stack.sh and doctor.sh use on a Linux server: python3 for
# services/config.py, Node.js 20+ for the Brave MCP server, perl for shasum,
# openssl for the generated keys, iproute2 (ss) and procps (ps) for doctor.sh.
# socat forwards Ollama, rsync updates the checkout, nano edits .env.
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 nano nodejs npm openssl perl procps python3 rsync socat; \
    rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.12.23@sha256:61d393e44e249f2e4b526b6c7ddcecce245946826e608e11c93ad4f5bba55b21 /uv /usr/local/bin/uv
COPY --from=caddy:2.11.7@sha256:504a44d7d74bd2bc28a66afc4774912fc21223ca8a67734af1c54ab2f999b489 /usr/bin/caddy /usr/local/bin/caddy
COPY --from=ollama-cli /out/bin/ollama /usr/local/bin/ollama

# An unprivileged account runs everything, as on a real server. Its home is
# a volume (compose.yaml): the checkout (~/stack), uv's Python and cache, and
# Caddy's CA. One volume, so uv can hardlink the venv from its cache.
RUN useradd --create-home --shell /bin/bash harness \
 && install -d -o harness -g harness /home/harness/stack

# The repo as a fresh clone has it: .dockerignore leaves out .env, data/ and
# the rest of the Mac's own install, and the build stops if they got in
# anyway. boot.sh copies it into the checkout at each start, with the test
# model in place of Llama 3.3 70B.
COPY . /opt/harness
RUN for p in .env data .venv logs; do \
      if [ -e "/opt/harness/$p" ]; then echo "ERROR: $p is in the build context; check .dockerignore" >&2; exit 1; fi; \
    done
COPY server-test/Modelfile.server /opt/harness/Modelfile.server

USER harness
WORKDIR /home/harness/stack
ENTRYPOINT ["/opt/harness/server-test/boot.sh"]
