"""
title: Delete voice recordings
description: Deletes each voice recording and its transcript as soon as Open WebUI has transcribed it. Installed and kept active by scripts/stack.sh.
"""
# Open WebUI event function: stack.sh stores this file in Open WebUI's database,
# and Open WebUI runs it in its own process (it is not imported by the gateway).
import time
import uuid
from pathlib import Path

from open_webui.config import CACHE_DIR

RECORDINGS = Path(CACHE_DIR) / 'audio' / 'transcriptions'
# Files a failed transcription left behind (it publishes no event): no
# transcription runs this long, so these are no longer in use.
STALE_SECONDS = 3600


class Event:
    def event(self, event: dict) -> None:
        if event.get('event') != 'audio.transcription_requested':
            return
        try:
            # Open WebUI names every file of a recording after its UUID:
            # <id>.wav, <id>.mp3, <id>.json, <id>_compressed…, <id>_chunk_…
            recording = str(uuid.UUID(str((event.get('subject') or {}).get('id'))))
        except ValueError:
            recording = None
        cutoff = time.time() - STALE_SECONDS
        for path in RECORDINGS.glob('*'):
            try:
                if path.is_file() and (
                    (recording and path.name.startswith(recording)) or path.stat().st_mtime < cutoff
                ):
                    path.unlink()
            except FileNotFoundError:
                pass
