import asyncio
import json
import unittest
from dataclasses import replace

import httpx
from services.config import Settings
from services.gateway import Queue, create_app


BODY = {'model': 'coder-server:latest', 'messages': [{'role': 'user', 'content': 'test'}]}


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        self.gates = []
        self.block = False
        self.fail_backend = False
        self.cfg = Settings.read({'MODE': 'server', 'GATEWAY_SERVICE_KEY': 'test-service'})
        async def upstream(request):
            self.assertNotIn('cookie', request.headers)
            if request.url.path == '/api/v1/auths/':
                token = request.headers.get('authorization', '')
                if token in ('Bearer alice', 'Bearer bob'):
                    return httpx.Response(200, json={'id': token[7:], 'role': 'user'}, headers={'set-cookie': 'token=test-session; Path=/'})
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

    async def test_ollama_keeps_model_sampling_defaults(self):
        self.app.state.queue.cfg = replace(self.cfg, backend='ollama')
        jid = (await self.submit({**BODY, 'tools': [{'type': 'function', 'function': {'name': 'write_file'}}]})).json()['id']
        await self.wait_for(lambda: self.app.state.queue.jobs[jid].state == 'completed')
        self.assertNotIn('temperature', self.calls[-1][1])

    async def test_auth_isolation_and_spoofed_headers(self):
        j = (await self.submit()).json()['id']
        for method in ('get', 'delete'):
            r = await getattr(self.client, method)('/v1/jobs/' + j, headers={'Authorization': 'Bearer bob', 'X-OpenWebUI-User-Id': 'alice'})
            self.assertEqual(r.status_code, 404)
        self.assertEqual((await self.submit(user='invalid')).status_code, 401)
        self.assertEqual((await self.client.get('/v1/models', headers={'Authorization': 'Bearer invalid'})).status_code, 401)

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


class ConfigTests(unittest.TestCase):
    def test_defaults_and_override(self):
        self.assertEqual(Settings.read({}).backend, 'ollama')
        self.assertEqual(Settings.read({'MODE': 'server'}).backend, 'ollama')
        self.assertEqual(Settings.read({'INFERENCE_BACKEND': 'ollama'}).model, 'coder-local:latest')
        for env in ({'MODE': 'oops'}, {'INFERENCE_BACKEND': 'other'}, {'QUEUE_ACTIVE': '0'},
                    {'WEBUI_HOST': '0.0.0.0'}, {'OLLAMA_BASE_URL': 'https://external.test'},
                    {'EMBED_MODEL': 'other'}, {'INFERENCE_BACKEND': 'unsupported'}):
            with self.assertRaises(ValueError):
                Settings.read(env)


if __name__ == '__main__':
    unittest.main()
