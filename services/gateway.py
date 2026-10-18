"""Single-process, bounded fair queue. No prompt logs or on-disk job store."""
import asyncio
import hashlib
import hmac
import json
import socket
import time
import uuid
from collections import OrderedDict, deque
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import date
from urllib.parse import urlparse

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

from services.config import ROOT, Settings

TERMINAL = {'completed', 'failed', 'cancelled', 'expired'}


def foreign_web_search(tool):
    """A web search tool an IDE offers that is not Brave-backed, such as
    Android Studio's Gemini web_search. Brave tools name Brave in their name
    (brave_web_search) or description (the Xcode agent's web_search)."""
    fn = tool.get('function') if isinstance(tool, dict) else None
    if not isinstance(fn, dict):
        return False
    name, desc = str(fn.get('name', '')).lower(), str(fn.get('description', '')).lower()
    web = 'search' in name and any(w in name for w in ('web', 'internet', 'google', 'bing'))
    return web and 'brave' not in name and 'brave' not in desc


@dataclass
class Job:
    id: str
    user: str
    body: dict
    kind: str
    fingerprint: str
    key: str | None
    created: float = field(default_factory=time.monotonic)
    finished: float = 0
    state: str = 'queued'
    result: dict | None = None
    error: str | None = None
    chunks: list = field(default_factory=list)
    size: int = 0
    task: asyncio.Task | None = None
    code: int = 200


class Queue:
    def __init__(self, cfg, client):
        self.cfg, self.client = cfg, client
        self.jobs = {}
        self.keys = {}
        self.users = OrderedDict()
        self.running = set()
        self.wakeup = asyncio.Event()
        self.last_user = None
        self.prompt = (ROOT / 'prompts/system.md').read_text()

    def prune(self):
        now = time.monotonic()
        for jid, j in list(self.jobs.items()):
            if j.state in TERMINAL and now - j.finished > self.cfg.retention:
                self.jobs.pop(jid)
                if j.key:
                    self.keys.pop((j.user, j.key), None)

    def submit(self, user, body, kind, key=None):
        self.prune()
        fingerprint = hashlib.sha256(json.dumps([kind, body], sort_keys=True).encode()).hexdigest()
        if key:
            if len(key) > 128:
                raise HTTPException(400, 'Idempotency-Key is too long')
            old = self.keys.get((user, key))
            if old:
                j = self.jobs[old]
                if j.fingerprint != fingerprint:
                    raise HTTPException(409, 'Idempotency-Key already used with a different request')
                return j
        pending = [j for j in self.jobs.values() if j.state not in TERMINAL]
        if (sum(j.user == user for j in pending) >= self.cfg.per_user
                or sum(j.state == 'queued' for j in pending) >= self.cfg.waiting
                or len(self.jobs) >= self.cfg.max_jobs):
            raise HTTPException(429, 'Server busy: queue or per-user limit reached. Retry later.', headers={'Retry-After': '5'})
        j = Job(str(uuid.uuid4()), user, body, kind, fingerprint, key)
        self.jobs[j.id] = j
        if key:
            self.keys[user, key] = j.id
        self.users.setdefault(user, deque()).append(j.id)
        self.wakeup.set()
        return j

    def owned(self, jid, user):
        self.prune()
        j = self.jobs.get(jid)
        if j is None or j.user != user:
            raise HTTPException(404, 'Request not found or retention expired')
        return j

    def finish(self, j, state, error=None, code=200):
        j.state, j.error, j.code, j.finished = state, error, code, time.monotonic()
        j.body = {}  # release source code as soon as the request ends
        self.wakeup.set()

    def cancel(self, j):
        if j.state not in TERMINAL:
            if j.task:
                j.task.cancel()
            self.finish(j, 'cancelled', 'Request cancelled', 409)

    def order(self):
        queues = OrderedDict((u, deque(i for i in ids if i in self.jobs and self.jobs[i].state == 'queued'))
                             for u, ids in self.users.items())
        if self.last_user in queues:
            queues.move_to_end(self.last_user)
        ordered = []
        while queues:
            for u in list(queues):
                if queues[u]:
                    ordered.append(queues[u].popleft())
                if not queues[u]:
                    del queues[u]
        return ordered

    def status(self, j):
        order = self.order()
        return dict(id=j.id, state=j.state,
                    position=(order.index(j.id) + 1 if j.id in order else None),
                    elapsed_seconds=round(time.monotonic() - j.created),
                    error=j.error, result=j.result if j.state == 'completed' else None)

    async def scheduler(self):
        while True:
            self.wakeup.clear()
            now = time.monotonic()
            for j in list(self.jobs.values()):
                if j.state == 'queued' and now - j.created >= self.cfg.wait_seconds:
                    self.finish(j, 'expired', 'Queue wait limit reached; retry later', 504)
            # Remove terminal entries before prune removes their job objects.
            for u, ids in list(self.users.items()):
                remaining = deque(i for i in ids if i in self.jobs and self.jobs[i].state == 'queued')
                if remaining:
                    self.users[u] = remaining
                else:
                    del self.users[u]
            self.prune()
            while len(self.running) < self.cfg.active and self.users:
                if self.last_user in self.users:
                    self.users.move_to_end(self.last_user)
                user = next(iter(self.users))
                jid = self.users[user].popleft()
                if not self.users[user]:
                    del self.users[user]
                else:
                    self.users.move_to_end(user)
                self.last_user = user
                j = self.jobs[jid]
                j.state = 'running'
                self.running.add(jid)
                j.task = asyncio.create_task(self.run(j))
                j.task.add_done_callback(lambda task, jid=jid: self.release(jid))
            try:
                async with asyncio.timeout(0.25):
                    await self.wakeup.wait()
            except asyncio.TimeoutError:
                pass

    def release(self, jid):
        self.running.discard(jid)
        self.wakeup.set()

    async def run(self, j):
        try:
            body = dict(j.body)
            if j.kind == 'chat':
                body['model'] = self.cfg.model
                messages = list(body['messages'])
                # Per request, so a long-running gateway never serves a stale date.
                prompt = f"{self.prompt.rstrip()}\n\nToday's date is {date.today():%A %d %B %Y}."
                body['messages'] = [{'role': 'system', 'content': prompt}] + messages
                base, route = self.cfg.upstream, '/chat/completions'
            else:
                base, route = self.cfg.ollama + '/v1', '/embeddings'
            async with asyncio.timeout(self.cfg.run_seconds):
                async with self.client.stream('POST', base + route, json=body) as response:
                    if response.status_code >= 400:
                        self.finish(j, 'failed', f'Inference backend returned HTTP {response.status_code}', 502)
                        return
                    if body.get('stream'):
                        done = False
                        async for line in response.aiter_lines():
                            if not line.startswith('data:'):
                                continue
                            data = line[5:].strip()
                            if not data:
                                continue
                            if data == '[DONE]':
                                done = True
                            else:
                                chunk = json.loads(data)
                                if 'error' in chunk:
                                    raise ValueError('Backend stream failed')
                                if 'choices' not in chunk:
                                    raise ValueError('Invalid backend stream')
                                chunk['model'] = self.cfg.model
                                data = json.dumps(chunk)
                            j.size += len(data.encode())
                            if j.size > self.cfg.max_result:
                                raise ValueError('Result exceeds configured limit')
                            j.chunks.append(data)
                            if done:
                                break
                        if not done:
                            raise ValueError('Backend disconnected before completion')
                    else:
                        content = bytearray()
                        async for chunk in response.aiter_bytes():
                            content.extend(chunk)
                            if len(content) > self.cfg.max_result:
                                raise ValueError('Result exceeds configured limit')
                        j.result = json.loads(content)
                        expected = 'choices' if j.kind == 'chat' else 'data'
                        if not isinstance(j.result, dict) or expected not in j.result:
                            raise ValueError('Invalid backend result')
                        if j.kind == 'chat':
                            j.result['model'] = self.cfg.model
                self.finish(j, 'completed')
        except asyncio.CancelledError:
            self.finish(j, 'cancelled', 'Request cancelled', 409)
        except TimeoutError:
            self.finish(j, 'failed', 'Inference time limit reached', 504)
        except (httpx.HTTPError, ValueError):
            self.finish(j, 'failed', 'Inference failed or response limit exceeded; request was not replayed', 502)
        finally:
            self.running.discard(j.id)
            self.wakeup.set()


def create_app(cfg=None, transport=None):
    cfg = cfg or Settings.read()

    @asynccontextmanager
    async def lifespan(app):
        if not cfg.service_key:
            raise RuntimeError('GATEWAY_SERVICE_KEY missing; run setup.sh')
        async with httpx.AsyncClient(timeout=httpx.Timeout(cfg.run_seconds, connect=5),
                                     trust_env=False, transport=transport) as client:
            q = Queue(cfg, client)
            app.state.queue = q
            worker = asyncio.create_task(q.scheduler())
            try:
                yield
            finally:
                worker.cancel()
                tasks = [j.task for j in q.jobs.values() if j.task and not j.task.done()]
                for t in tasks:
                    t.cancel()
                await asyncio.gather(worker, *tasks, return_exceptions=True)

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware('http')
    async def no_cache(request, call_next):
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        return response

    async def user(request):
        token = request.headers.get('authorization', '')
        if hmac.compare_digest(token, 'Bearer ' + cfg.service_key):
            return request.headers.get('x-openwebui-user-id') or 'webui-service'
        if cfg.mode == 'local':
            return 'local'
        if not token.startswith('Bearer ') or len(token) > 4096:
            raise HTTPException(401, 'A personal Open WebUI API key is required')
        try:
            # Never share WebUI session cookies between users or with inference.
            async with httpx.AsyncClient(timeout=5, trust_env=False, transport=transport) as auth_client:
                response = await auth_client.get(cfg.webui + '/api/v1/auths/',
                                                 headers={'Authorization': token})
            if response.status_code != 200:
                raise HTTPException(401, 'Invalid API key')
            identity = response.json()
            if identity.get('role') not in ('user', 'admin') or not identity.get('id'):
                raise HTTPException(403, 'Account is not approved')
            return identity['id']
        except (httpx.HTTPError, ValueError):
            raise HTTPException(503, 'Authentication service unavailable')

    async def parse(request, kind):
        data = bytearray()
        async for chunk in request.stream():
            data.extend(chunk)
            if len(data) > cfg.max_body:
                raise HTTPException(413, 'Request exceeds configured limit')
        try:
            body = json.loads(data)
        except ValueError:
            raise HTTPException(400, 'Invalid JSON')
        if not isinstance(body, dict):
            raise HTTPException(400, 'Expected a JSON object')
        if kind == 'chat':
            if body.get('model') not in (cfg.model, cfg.model.removesuffix(':latest')):
                raise HTTPException(400, 'Model is not enabled for this mode')
            if not isinstance(body.get('messages'), list) or not body['messages']:
                raise HTTPException(400, 'messages must be a nonempty list')
            if not isinstance(body.get('stream', False), bool):
                raise HTTPException(400, 'stream must be a boolean')
            # Keep backend-only paths, remote media and arbitrary backend parameters out.
            for message in body['messages']:
                if not isinstance(message, dict):
                    raise HTTPException(400, 'Invalid message')
                content = message.get('content')
                if isinstance(content, list) and any(not isinstance(p, dict) or p.get('type') != 'text' for p in content):
                    raise HTTPException(400, 'Only text content is supported')
                if content is not None and not isinstance(content, (str, list)):
                    raise HTTPException(400, 'Invalid content')
            allowed = {'model', 'messages', 'stream', 'temperature', 'top_p', 'max_tokens',
                       'stop', 'tools', 'tool_choice', 'parallel_tool_calls', 'seed',
                       'frequency_penalty', 'presence_penalty', 'stream_options', 'response_format'}
            if cfg.backend == 'ollama':
                allowed.add('reasoning_effort')
            body = {k: v for k, v in body.items() if k in allowed}
            # Web search leaves only through Brave, so the model never sees
            # another provider's search tool (the prompt alone didn't stop it).
            if isinstance(body.get('tools'), list):
                kept = [t for t in body['tools'] if not foreign_web_search(t)]
                if len(kept) != len(body['tools']):
                    names = {t['function'].get('name') for t in kept
                             if isinstance(t, dict) and isinstance(t.get('function'), dict)}
                    choice = body.get('tool_choice')
                    chosen = choice.get('function') if isinstance(choice, dict) else None
                    if not kept or (isinstance(chosen, dict) and chosen.get('name') not in names):
                        body.pop('tool_choice', None)
                    if kept:
                        body['tools'] = kept
                    else:
                        body.pop('tools')
                        body.pop('parallel_tool_calls', None)
        else:
            if body.get('model') != 'nomic-embed-text' or 'input' not in body:
                raise HTTPException(400, 'Only nomic-embed-text embeddings are enabled')
            body = {k: v for k, v in body.items() if k in {'model', 'input', 'encoding_format'}}
        return body

    @app.get('/health')
    async def health():
        q = app.state.queue
        return dict(status='ok', backend=cfg.backend, model=cfg.model,
                    running=len(q.running), waiting=len(q.order()))

    @app.get('/v1/models')
    async def models(request: Request):
        await user(request)
        # context_length lets clients that read it (Android Studio) compress
        # their history before it fills the model's context.
        return {'object': 'list', 'data': [{'id': cfg.model, 'object': 'model', 'owned_by': 'local-stack',
                                            'context_length': cfg.context}]}

    @app.post('/v1/jobs', status_code=202)
    async def submit(request: Request):
        identity = await user(request)
        body = await parse(request, 'chat')
        if body.get('stream'):
            raise HTTPException(400, 'Jobs return a complete result; use stream=false')
        j = app.state.queue.submit(identity, body, 'chat', request.headers.get('idempotency-key'))
        return app.state.queue.status(j)

    @app.get('/v1/jobs/{jid}')
    async def status(jid: str, request: Request):
        identity = await user(request)
        q = app.state.queue
        return q.status(q.owned(jid, identity))

    @app.delete('/v1/jobs/{jid}')
    async def cancel(jid: str, request: Request):
        identity = await user(request)
        q = app.state.queue
        j = q.owned(jid, identity)
        q.cancel(j)
        return q.status(j)

    async def completion(request, kind):
        identity = await user(request)
        body = await parse(request, kind)
        q = app.state.queue
        j = q.submit(identity, body, kind, request.headers.get('idempotency-key'))
        headers = {'X-Request-ID': j.id, 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'}
        if body.get('stream'):
            async def events():
                index = 0
                try:
                    while True:
                        while index < len(j.chunks):
                            yield 'data: ' + j.chunks[index] + '\n\n'
                            index += 1
                        if j.state in TERMINAL:
                            if j.state != 'completed':
                                yield 'data: ' + json.dumps({'error': {'message': j.error, 'type': j.state}}) + '\n\n'
                                yield 'data: [DONE]\n\n'
                            break
                        # SSE comments keep idle streams alive without polluting model output.
                        yield ': ' + j.state + '\n\n'
                        await asyncio.sleep(1)
                finally:
                    # Standard streams cannot safely replay partially consumed tool calls.
                    q.cancel(j)
            return StreamingResponse(events(), media_type='text/event-stream', headers=headers)
        try:
            while j.state not in TERMINAL:
                if await request.is_disconnected():
                    q.cancel(j)
                    break
                await asyncio.sleep(0.1)
            if j.state == 'completed':
                return JSONResponse(j.result, headers=headers)
            return JSONResponse({'error': {'message': j.error, 'type': j.state}}, status_code=j.code, headers=headers)
        finally:
            q.cancel(j)

    @app.post('/v1/chat/completions')
    async def chat(request: Request):
        return await completion(request, 'chat')

    @app.post('/v1/embeddings')
    async def embeddings(request: Request):
        return await completion(request, 'embed')

    return app


def loopback_sockets(port):
    """Bound sockets on 127.0.0.1 and ::1, never another interface. ::1 too
    because clients that try "localhost" as ::1 first can otherwise get stuck:
    Android Studio's OpenAI client (OkHttp with retryOnConnectionFailure off)
    marks 127.0.0.1 failed after one timed-out request and then only tries ::1
    until restarted. Skips ::1 where IPv6 is unavailable."""
    sockets = []
    for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
        try:
            sock = socket.socket(family, socket.SOCK_STREAM)
        except OSError:
            if family == socket.AF_INET6:
                continue
            raise
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        try:
            sock.bind((host, port))
        except OSError:
            sock.close()
            if family == socket.AF_INET6 and sockets:
                continue
            raise
        sockets.append(sock)
    return sockets


if __name__ == '__main__':
    import uvicorn
    port = int(urlparse(Settings.read().gateway).port)
    # One process for both sockets: the queue state is in memory.
    uvicorn.Server(uvicorn.Config(create_app, factory=True, access_log=False)).run(sockets=loopback_sockets(port))
