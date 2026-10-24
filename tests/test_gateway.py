import asyncio
import base64
import json
import socket
import unittest
from dataclasses import replace
from datetime import date

import httpx
from services.config import Settings
from services.gateway import Queue, create_app, loopback_sockets


BODY = {'model': 'coder-server:latest', 'messages': [{'role': 'user', 'content': 'test'}]}
PNG = 'data:image/png;base64,' + base64.b64encode(b'\x89PNG\r\n\x1a\n' + bytes(32)).decode()


def with_images(*urls, role='user'):
    parts = [{'type': 'text', 'text': 'What is this?'}]
    parts += [{'type': 'image_url', 'image_url': {'url': url, 'detail': 'high'}} for url in urls]
    return {**BODY, 'messages': [{'role': role, 'content': parts}]}


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        self.gates = []
        self.block = False
        self.fail_backend = False
        self.cfg = Settings.read({'MODE': 'server', 'GATEWAY_SERVICE_KEY': 'test-service'})
        async def upstream(request):
            self.assertNotIn('cookie', request.headers)
            if request.url.path == '/api/v1/users/user/status':
                token = request.headers.get('authorization', '')
                if token in ('Bearer alice', 'Bearer bob'):
                    return httpx.Response(200, json={'id': token[7:], 'role': 'user'}, headers={'set-cookie': 'token=test-session; Path=/'})
                if token == 'Bearer no-keys':  # API keys off or not permitted for the account
                    return httpx.Response(403)
                return httpx.Response(401)
            self.calls.append((str(request.url), json.loads(request.content)))
            if self.block:
                event = asyncio.Event()
                self.gates.append(event)
                await event.wait()
            if self.fail_backend:
                return httpx.Response(503)
            body = json.loads(request.content)
            if body.get('stream'):
                data = {'choices': [{'delta': {'content': 'ok'}}]}
                return httpx.Response(200, text='data: ' + json.dumps(data) + '\n\ndata: [DONE]\n\n')
            if request.url.path.endswith('/embeddings'):
                return httpx.Response(200, json={'data': [{'embedding': [0.1]}]})
            return httpx.Response(200, json={'choices': [{'message': {'content': 'ok', 'tool_calls': []}}]})
        self.transport = httpx.MockTransport(upstream)
        self.app = create_app(self.cfg, self.transport)
        self.lifespan = self.app.router.lifespan_context(self.app)
        await self.lifespan.__aenter__()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url='http://test',
                                       headers={'Authorization': 'Bearer alice'})

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.lifespan.__aexit__(None, None, None)

    async def submit(self, body=None, user='alice', key=None):
        headers = {'Authorization': 'Bearer ' + user}
        if key:
            headers['Idempotency-Key'] = key
        return await self.client.post('/v1/jobs', json=body or BODY, headers=headers)

    async def wait_for(self, predicate):
        for _ in range(200):
            if predicate():
                return
            await asyncio.sleep(.01)
        self.fail('Timed out waiting for test condition')

    async def test_job_reconnect_and_idempotency(self):
        first = await self.submit(key='same')
        jid = first.json()['id']
        second = await self.submit(key='same')
        self.assertEqual(jid, second.json()['id'])
        self.assertEqual((await self.submit({**BODY, 'max_tokens': 3}, key='same')).status_code, 409)
        q = self.app.state.queue
        await self.wait_for(lambda: q.jobs[jid].state == 'completed')
        replay = await self.client.get('/v1/jobs/' + jid)
        self.assertEqual(replay.json()['result']['choices'][0]['message']['content'], 'ok')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], 'http://127.0.0.1:11434/v1/chat/completions')
        self.assertEqual(self.calls[0][1]['messages'][0]['role'], 'system')
        self.assertIn(f"Today's date is {date.today():%A %d %B %Y}.", self.calls[0][1]['messages'][0]['content'])

    async def test_ollama_keeps_model_sampling_defaults(self):
        self.app.state.queue.cfg = replace(self.cfg, backend='ollama')
        jid = (await self.submit({**BODY, 'tools': [{'type': 'function', 'function': {'name': 'write_file'}}]})).json()['id']
        await self.wait_for(lambda: self.app.state.queue.jobs[jid].state == 'completed')
        self.assertNotIn('temperature', self.calls[-1][1])

    async def test_non_brave_web_search_tools_removed(self):
        def tool(name, description=''):
            return {'type': 'function', 'function': {'name': name, 'description': description}}
        tools = [tool('web_search', 'Search the web for up-to-date results'), tool('search_web'), tool('read_file'),
                 tool('brave_web_search'), tool('web_search', 'Search the public web (Brave)'),
                 tool('docs_search', 'Search Apple documentation')]
        choice = {'type': 'function', 'function': {'name': 'search_web'}}
        jid = (await self.submit({**BODY, 'tools': tools, 'tool_choice': choice})).json()['id']
        await self.wait_for(lambda: self.app.state.queue.jobs[jid].state == 'completed')
        sent = self.calls[-1][1]
        self.assertEqual([t['function']['name'] for t in sent['tools']],
                         ['read_file', 'brave_web_search', 'web_search', 'docs_search'])
        self.assertNotIn('tool_choice', sent)
        jid = (await self.submit({**BODY, 'tools': [tool('google_search')], 'tool_choice': 'required',
                                  'parallel_tool_calls': False})).json()['id']
        await self.wait_for(lambda: self.app.state.queue.jobs[jid].state == 'completed')
        self.assertFalse({'tools', 'tool_choice', 'parallel_tool_calls'} & self.calls[-1][1].keys())

    async def test_auth_isolation_and_spoofed_headers(self):
        j = (await self.submit()).json()['id']
        for method in ('get', 'delete'):
            r = await getattr(self.client, method)('/v1/jobs/' + j, headers={'Authorization': 'Bearer bob', 'X-OpenWebUI-User-Id': 'alice'})
            self.assertEqual(r.status_code, 404)
        self.assertEqual((await self.submit(user='invalid')).status_code, 401)
        self.assertEqual((await self.submit(user='no-keys')).status_code, 403)
        self.assertEqual((await self.client.get('/v1/models', headers={'Authorization': 'Bearer invalid'})).status_code, 401)
        model = (await self.client.get('/v1/models')).json()['data'][0]
        self.assertEqual((model['id'], model['context_length']), ('coder-server:latest', 16384))

    async def test_limits_and_fairness(self):
        self.block = True
        a1 = (await self.submit()).json()['id']
        await self.wait_for(lambda: len(self.gates) == 1)
        a2 = (await self.submit()).json()['id']
        excess = await self.submit()
        self.assertEqual(excess.status_code, 429)
        self.assertEqual(excess.headers['retry-after'], '5')
        b1 = (await self.submit(user='bob')).json()['id']
        q = self.app.state.queue
        self.assertEqual(q.order(), [b1, a2])
        self.gates[0].set()
        await self.wait_for(lambda: len(self.gates) == 2)
        self.assertEqual(q.jobs[b1].state, 'running')
        self.assertEqual(q.jobs[a2].state, 'queued')
        self.assertEqual(len(q.running), 1)
        await self.client.delete('/v1/jobs/' + a2)
        self.assertEqual(q.jobs[a2].state, 'cancelled')

    async def test_running_cancellation_releases_slot(self):
        self.block = True
        jid = (await self.submit()).json()['id']
        await self.wait_for(lambda: len(self.gates) == 1)
        await self.client.delete('/v1/jobs/' + jid)
        await self.wait_for(lambda: not self.app.state.queue.running)
        self.assertEqual(self.app.state.queue.jobs[jid].state, 'cancelled')

    async def test_deadlines_and_expiry(self):
        self.block = True
        q = self.app.state.queue
        q.cfg = replace(q.cfg, wait_seconds=1, run_seconds=1, retention=1)
        a = (await self.submit()).json()['id']
        await self.wait_for(lambda: len(self.gates) == 1)
        b = (await self.submit()).json()['id']
        q.jobs[b].created -= 2
        q.wakeup.set()
        await self.wait_for(lambda: q.jobs[b].state == 'expired')
        await self.wait_for(lambda: q.jobs[a].state == 'failed')
        self.assertEqual(q.jobs[a].code, 504)
        q.jobs[b].finished -= 2
        self.assertEqual((await self.client.get('/v1/jobs/' + b)).status_code, 404)

    async def test_stream_and_embeddings(self):
        response = await self.client.post('/v1/chat/completions', json={**BODY, 'stream': True})
        self.assertIn('data: [DONE]', response.text)
        self.assertIn('"content": "ok"', response.text)
        self.assertNotIn('Queued —', response.text)
        self.assertIn('x-request-id', response.headers)
        response = await self.client.post('/v1/embeddings', json={'model': 'nomic-embed-text', 'input': 'test'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[-1][0], 'http://127.0.0.1:11434/v1/embeddings')

    async def test_backend_failure_not_replayed(self):
        self.fail_backend = True
        r = await self.client.post('/v1/chat/completions', json=BODY)
        self.assertEqual(r.status_code, 502)
        self.assertEqual(len(self.calls), 1)

    async def test_validation_and_memory_limits(self):
        self.assertEqual((await self.submit({**BODY, 'model': 'unknown'})).status_code, 400)
        body = {**BODY, 'messages': [{'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': 'https://example.org/a'}}]}]}
        self.assertEqual((await self.submit(body)).status_code, 400)
        self.assertEqual((await self.client.post('/v1/jobs', content=b'x' * (self.cfg.max_body + 1))).status_code, 413)
        q = self.app.state.queue
        q.cfg = replace(q.cfg, max_jobs=1)
        self.assertEqual((await self.submit()).status_code, 202)
        self.assertEqual((await self.submit(user='bob')).status_code, 429)

    async def test_inline_images_only(self):
        jid = (await self.submit(with_images(PNG))).json()['id']
        await self.wait_for(lambda: self.app.state.queue.jobs[jid].state == 'completed')
        # Passed on as just the data URL (no detail or other backend fields).
        self.assertEqual(self.calls[-1][1]['messages'][-1]['content'][1], {'type': 'image_url', 'image_url': {'url': PNG}})
        gif = base64.b64encode(b'GIF89a' + bytes(32)).decode()
        jpeg_bytes = base64.b64encode(b'\xff\xd8\xff' + bytes(32)).decode()
        webp = base64.b64encode(b'RIFF\0\0\0\0WEBPVP8 ' + bytes(32)).decode()
        for url in ('data:image/jpeg;base64,' + jpeg_bytes, 'data:image/webp;base64,' + webp):
            self.assertEqual((await self.submit(with_images(url), user='bob')).status_code, 202, url)
        # Ollama refuses GIF and image links; the gateway never fetches a URL.
        for url in ('https://example.org/a.png', 'data:image/gif;base64,' + gif, 'data:image/png;base64,' + gif,
                    'data:image/png;base64,not base64!', 'data:text/plain;base64,' + PNG[22:], '/api/v1/files/1/content'):
            self.assertEqual((await self.client.post('/v1/chat/completions', json=with_images(url))).status_code, 400, url)
        audio = {**BODY, 'messages': [{'role': 'user', 'content': [{'type': 'input_audio', 'input_audio': {'data': '', 'format': 'wav'}}]}]}
        for body in (audio, with_images(PNG, role='assistant')):
            self.assertEqual((await self.client.post('/v1/chat/completions', json=body)).status_code, 400)

    async def test_image_budget_separate_from_body_limit(self):
        image = 'data:image/png;base64,' + base64.b64encode(b'\x89PNG\r\n\x1a\n' + bytes(3000)).decode()
        for max_image, body, status in ((6000, with_images(image), 200),  # 4 KB of base64 past a 2 KB body limit
                                        (6000, with_images(image, image), 413),  # 6016 decoded bytes
                                        (6000, {**with_images(image), 'stop': ['x' * 3000]}, 413),  # text over 2 KB
                                        (0, with_images(PNG), 413)):  # 0 refuses images
            app = create_app(replace(self.cfg, max_body=2048, max_image=max_image), self.transport)
            async with app.router.lifespan_context(app), httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url='http://test',
                    headers={'Authorization': 'Bearer alice'}) as client:
                self.assertEqual((await client.post('/v1/chat/completions', json=body)).status_code, status)
                self.assertEqual((await client.post('/v1/embeddings', content=b'x' * 2049)).status_code, 413)

    async def test_ollama_adapter_uses_same_protocol(self):
        q = self.app.state.queue
        q.cfg = Settings.read({'MODE': 'server', 'INFERENCE_BACKEND': 'ollama'})
        r = await self.client.post('/v1/chat/completions', json=BODY)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.calls[0][0], 'http://127.0.0.1:11434/v1/chat/completions')

    async def test_result_limit_and_waiting_capacity(self):
        q = self.app.state.queue
        q.cfg = replace(q.cfg, max_result=8)
        r = await self.client.post('/v1/chat/completions', json=BODY)
        self.assertEqual(r.status_code, 502)
        self.block = True
        q.cfg = replace(q.cfg, waiting=1)
        await self.submit()
        await self.wait_for(lambda: len(self.gates) == 1)
        await self.submit(user='bob')
        self.assertEqual((await self.submit()).status_code, 429)

    async def test_disconnect_midstream_is_failure(self):
        async def truncated(request):
            return httpx.Response(200, text='data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')
        q = self.app.state.queue
        await q.client.aclose()
        q.client = httpx.AsyncClient(transport=httpx.MockTransport(truncated))
        try:
            j = q.submit('alice', {**BODY, 'stream':True}, 'chat')
            await self.wait_for(lambda: j.state == 'failed')
            self.assertEqual(j.code, 502)
            self.assertNotIn('[DONE]', j.chunks)
        finally:
            await q.client.aclose()

    async def test_trusted_webui_identity(self):
        r = await self.client.post('/v1/jobs', json=BODY, headers={'Authorization': 'Bearer test-service', 'X-OpenWebUI-User-Id': 'bob'})
        jid = r.json()['id']
        self.assertEqual((await self.client.get('/v1/jobs/' + jid)).status_code, 404)
        self.assertEqual((await self.client.get('/v1/jobs/' + jid, headers={'Authorization': 'Bearer bob'})).status_code, 200)

    async def test_delivered_requests_free_job_slots(self):
        # Open WebUI embeds a document one chunk per request; delivered
        # results must not fill QUEUE_MAX_JOBS for every other user.
        q = self.app.state.queue
        q.cfg = replace(q.cfg, max_jobs=2)
        for _ in range(3):
            r = await self.client.post('/v1/embeddings', json={'model': 'nomic-embed-text', 'input': 'test'})
            self.assertEqual(r.status_code, 200)
        r = await self.client.post('/v1/chat/completions', json={**BODY, 'stream': True}, headers={'Authorization': 'Bearer bob'})
        self.assertIn('data: [DONE]', r.text)
        self.assertEqual(q.jobs, {})
        # With an Idempotency-Key the result stays retained for a replay.
        r = await self.client.post('/v1/chat/completions', json=BODY, headers={'Idempotency-Key': 'k'})
        self.assertIn(r.headers['x-request-id'], q.jobs)

    async def test_non_ascii_authorization_rejected(self):
        for token in (b'Bearer \xe9', b'\xff'):
            self.assertEqual((await self.client.get('/v1/models', headers={'Authorization': token})).status_code, 401)

    async def test_unexpected_backend_data_ends_job(self):
        async def odd(request):
            return httpx.Response(200, text='data: 5\n\ndata: [DONE]\n\n')
        q = self.app.state.queue
        await q.client.aclose()
        q.client = httpx.AsyncClient(transport=httpx.MockTransport(odd))
        try:
            j = q.submit('alice', {**BODY, 'stream': True}, 'chat')
            await self.wait_for(lambda: j.state == 'failed')
            self.assertEqual(j.code, 502)
        finally:
            await q.client.aclose()


class LoopbackSocketTests(unittest.TestCase):
    def test_binds_both_loopbacks_only(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        sockets = loopback_sockets(port)
        try:
            hosts = [s.getsockname()[0] for s in sockets]
            self.assertEqual(hosts[0], '127.0.0.1')
            self.assertEqual(hosts[1:], ['::1'] if socket.has_ipv6 and len(hosts) > 1 else [])
            self.assertTrue(all(s.getsockname()[1] == port for s in sockets))
        finally:
            for s in sockets:
                s.close()


class ConfigTests(unittest.TestCase):
    def test_defaults_and_override(self):
        self.assertEqual(Settings.read({}).backend, 'ollama')
        self.assertEqual(Settings.read({'MODE': 'server'}).backend, 'ollama')
        self.assertEqual(Settings.read({'INFERENCE_BACKEND': 'ollama'}).model, 'coder-local:latest')
        self.assertEqual(Settings.read({}).context, 32768)
        self.assertEqual(Settings.read({'MODE': 'server'}).context, 16384)
        cfg = Settings.read({'LLAMA_ARG_CACHE_RAM': '-1'})
        self.assertEqual((cfg.ctx_checkpoints, cfg.cache_ram), ('4', '-1'))
        self.assertEqual(Settings.read({'LLAMA_ARG_CTX_CHECKPOINTS': ''}).ctx_checkpoints, '')
        self.assertEqual(Settings.read({}).max_image, 16777216)
        self.assertEqual(Settings.read({'QUEUE_MAX_IMAGE_BYTES': '0'}).max_image, 0)
        for env in ({'MODE': 'oops'}, {'INFERENCE_BACKEND': 'other'}, {'QUEUE_ACTIVE': '0'}, {'QUEUE_MAX_IMAGE_BYTES': '-1'},
                    {'WEBUI_HOST': '0.0.0.0'}, {'OLLAMA_BASE_URL': 'https://external.test'},
                    {'EMBED_MODEL': 'other'}, {'INFERENCE_BACKEND': 'unsupported'},
                    {'LLAMA_ARG_CTX_CHECKPOINTS': '-1'}, {'LLAMA_ARG_CACHE_RAM': '1g'}):
            with self.assertRaises(ValueError):
                Settings.read(env)


if __name__ == '__main__':
    unittest.main()
