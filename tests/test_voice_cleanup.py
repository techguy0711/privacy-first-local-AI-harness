import os
import sys
import tempfile
import time
import types
import unittest
import uuid
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'services' / 'voice_cleanup.py'


class VoiceCleanupTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name) / 'audio' / 'transcriptions'
        self.dir.mkdir(parents=True)
        # Loaded the way Open WebUI loads a function: exec'd, with its CACHE_DIR.
        config = types.SimpleNamespace(CACHE_DIR=tmp.name)
        with mock.patch.dict(sys.modules, {'open_webui': types.ModuleType('open_webui'), 'open_webui.config': config}):
            module = {}
            exec(SOURCE.read_text(), module)
        self.handler = module['Event']()

    def files(self, *names, age=0):
        for name in names:
            path = self.dir / name
            path.write_bytes(b'audio')
            if age:
                os.utime(path, (time.time() - age, time.time() - age))

    def left(self):
        return sorted(p.name for p in self.dir.iterdir())

    def test_deletes_the_transcribed_recording_only(self):
        done, busy = str(uuid.uuid4()), str(uuid.uuid4())
        self.files(f'{done}.wav', f'{done}.mp3', f'{done}.json', f'{done}_compressed_chunk_0.json', f'{busy}.wav')
        self.handler.event({'event': 'audio.transcription_requested', 'subject': {'type': 'audio', 'id': done}})
        self.assertEqual(self.left(), [f'{busy}.wav'])

    def test_deletes_files_failed_transcriptions_left(self):
        failed, busy = str(uuid.uuid4()), str(uuid.uuid4())
        self.files(f'{failed}.wav', f'{failed}.mp3', age=7200)
        self.files(f'{busy}.wav')
        self.handler.event({'event': 'audio.transcription_requested', 'subject': {'id': str(uuid.uuid4())}})
        self.assertEqual(self.left(), [f'{busy}.wav'])

    def test_ignores_other_events_and_ids_that_are_not_uuids(self):
        rec = str(uuid.uuid4())
        self.files(f'{rec}.wav')
        for event in ({'event': 'chat.created', 'subject': {'id': rec}},
                      {'event': 'audio.transcription_requested', 'subject': {'id': ''}},
                      {'event': 'audio.transcription_requested', 'subject': {'id': '../x'}},
                      {'event': 'audio.transcription_requested'}):
            self.handler.event(event)
        self.assertEqual(self.left(), [f'{rec}.wav'])


if __name__ == '__main__':
    unittest.main()
