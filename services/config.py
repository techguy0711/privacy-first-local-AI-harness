"""One configuration boundary for the scripts and inference gateway."""
import json
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def loopback_url(value):
    url = urlparse(value)
    if url.scheme != 'http' or url.hostname != '127.0.0.1' or url.username or url.password or url.query or url.fragment:
        raise ValueError('Internal service URLs must use http://127.0.0.1 (TLS belongs at the private reverse proxy)')
    return value.rstrip('/')


def model_context(mode):
    """num_ctx from Modelfile.<mode>: the one place the context size is set."""
    for line in (ROOT / f'Modelfile.{mode}').read_text().splitlines():
        parts = line.split()
        if parts[:2] == ['PARAMETER', 'num_ctx'] and len(parts) == 3:
            return int(parts[2])
    raise ValueError(f'Modelfile.{mode} must set PARAMETER num_ctx')


def optional_int(env, name, default, minimum):
    """An integer setting where '' means "leave the tool's own default"."""
    value = env.get(name, default)
    if value == '':
        return ''
    if not value.lstrip('-').isdigit() or int(value) < minimum:
        raise ValueError(f'{name} must be an integer >= {minimum}, or empty')
    return str(int(value))


def kv_cache_type(env):
    """OLLAMA_KV_CACHE_TYPE; '' means Ollama's own default (f16)."""
    value = env.get('OLLAMA_KV_CACHE_TYPE', 'q8_0')
    if value not in ('', 'f16', 'q8_0', 'q4_0'):
        raise ValueError('OLLAMA_KV_CACHE_TYPE must be f16, q8_0, q4_0 or empty')
    return value


def positive(env, name, default):
    value = int(env.get(name, default))
    if value < 1:
        raise ValueError(f'{name} must be positive')
    return value


def non_negative(env, name, default):
    value = int(env.get(name, default))
    if value < 0:
        raise ValueError(f'{name} must be 0 or more')
    return value


@dataclass
class Settings:
    mode: str
    backend: str
    model: str
    upstream: str
    ollama: str
    webui: str
    gateway: str
    service_key: str
    active: int
    waiting: int
    per_user: int
    wait_seconds: int
    run_seconds: int
    retention: int
    max_jobs: int
    max_body: int
    max_result: int
    max_image: int
    context: int
    ctx_checkpoints: str
    cache_ram: str
    kv_cache_type: str
    num_parallel: str

    @classmethod
    def read(cls, env=None):
        e = os.environ if env is None else env
        mode = e.get('MODE', 'local')
        if mode not in ('local', 'server'):
            raise ValueError('MODE must be local or server')
        backend = 'ollama'
        if e.get('INFERENCE_BACKEND', 'ollama') not in ('', 'ollama'):
            raise ValueError('Only Ollama is supported')
        ollama = loopback_url(e.get('OLLAMA_BASE_URL', 'http://127.0.0.1:11434'))
        upstream = ollama + '/v1'
        if urlparse(upstream).path != '/v1':
            raise ValueError('Inference URL must end with /v1')
        if e.get('EMBED_MODEL', 'nomic-embed-text') != 'nomic-embed-text':
            raise ValueError('Only nomic-embed-text is supported for embeddings')
        for name in ('WEBUI_HOST', 'BRAVE_MCP_HOST'):
            if e.get(name, '127.0.0.1') != '127.0.0.1':
                raise ValueError(f'{name} must remain 127.0.0.1; use the private TLS proxy')
        return cls(mode, backend, f'coder-{mode}:latest', upstream, ollama,
                   f"http://127.0.0.1:{positive(e, 'WEBUI_PORT', 3000)}",
                   f"http://127.0.0.1:{positive(e, 'GATEWAY_PORT', 8787)}",
                   e.get('GATEWAY_SERVICE_KEY', ''),
                   positive(e, 'QUEUE_ACTIVE', 1), positive(e, 'QUEUE_WAITING', 32),
                   positive(e, 'QUEUE_PER_USER', 2), positive(e, 'QUEUE_WAIT_SECONDS', 300),
                   positive(e, 'INFERENCE_TIMEOUT_SECONDS', 600), positive(e, 'QUEUE_RETENTION_SECONDS', 300),
                   positive(e, 'QUEUE_MAX_JOBS', 128), positive(e, 'QUEUE_MAX_BODY_BYTES', 1048576),
                   positive(e, 'QUEUE_MAX_RESULT_BYTES', 4194304),
                   # Decoded inline-image bytes per chat request; 0 refuses images.
                   non_negative(e, 'QUEUE_MAX_IMAGE_BYTES', 16777216), model_context(mode),
                   # llama-server's prompt-cache RAM, Ollama's KV cache type and
                   # its slots per model, applied to Ollama by setup.sh.
                   optional_int(e, 'LLAMA_ARG_CTX_CHECKPOINTS', '4', 0),
                   optional_int(e, 'LLAMA_ARG_CACHE_RAM', '512', -1), kv_cache_type(e),
                   optional_int(e, 'OLLAMA_NUM_PARALLEL', '2', 1))

    def shell(self):
        import shlex
        values = dict(INFERENCE_BACKEND=self.backend, CHAT_MODEL=self.model,
                      INFERENCE_BASE_URL=self.upstream, GATEWAY_BASE_URL=self.gateway,
                      OLLAMA_BASE_URL=self.ollama, MODEL_CONTEXT=self.context,
                      LLAMA_ARG_CTX_CHECKPOINTS=self.ctx_checkpoints, LLAMA_ARG_CACHE_RAM=self.cache_ram,
                      OLLAMA_KV_CACHE_TYPE=self.kv_cache_type, OLLAMA_NUM_PARALLEL=self.num_parallel,
                      EDITOR_TIMEOUT_MS=(self.wait_seconds + self.run_seconds + 60) * 1000)
        return '\n'.join(f'export {k}={shlex.quote(str(v))}' for k, v in values.items())


if __name__ == '__main__':
    print(Settings.read().shell())
