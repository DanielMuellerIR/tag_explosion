#!/usr/bin/env python3
"""Linux: echte Engine während blockierter Stapel-Coverkonvertierung abbrechen.

Aufruf: python3 Tests/Linux/review_cover_cancel.py --engine .build/debug/tagx-engine
Benötigt Linux (/proc), Python und ffmpeg; keine vorhandenen Medien/Netzdienste.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def process_info(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    except FileNotFoundError:
        return None
    return {'state': fields[0], 'ppid': int(fields[1]), 'pgid': int(fields[2]), 'start': fields[19]}


class Engine:
    def __init__(self, executable, environment, log):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log, env=environment,
                                        start_new_session=True, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0
        self.pending = b''
        self.responses = {}

    def send(self, method, params=None):
        self.sequence += 1
        message = {'id': self.sequence, 'session': 'main', 'method': method, 'params': params or {}}
        self.process.stdin.write(json.dumps(message).encode() + b'\n')
        self.process.stdin.flush()
        return self.sequence

    def receive(self, request_id, timeout=10):
        deadline = time.monotonic() + timeout
        while request_id not in self.responses:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and self.selector.select(remaining), f'IPC-Deadline für Anfrage {request_id}'
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, f'Engine beendet (Status {self.process.poll()})'
            self.pending += chunk
            assert len(self.pending) <= 24 * 1024 * 1024, 'IPC-Ausgabe zu groß'
            while b'\n' in self.pending:
                line, self.pending = self.pending.split(b'\n', 1)
                response = json.loads(line)
                self.responses[response['id']] = response
        return self.responses.pop(request_id)

    def call(self, method, params=None, timeout=10):
        response = self.receive(self.send(method, params), timeout)
        assert not response.get('error'), response
        return response['result']

    def close(self):
        # Die unreapte eigene Popen-PID reserviert auch die Prozessgruppen-ID.
        try:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=2)
        finally:
            self.selector.close()
            self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.exit(2, 'Umgebungsgrenze: Dieser Test benötigt Linux und /proc; nicht ausgeführt.\n')
    executable = args.engine.resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f'Engine nicht ausführbar: {executable}')
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        parser.exit(2, 'Umgebungsgrenze: ffmpeg fehlt; nicht ausgeführt.\n')

    with tempfile.TemporaryDirectory(prefix='tagx-cover-cancel-') as temporary:
        work = Path(temporary)
        folders = {name: work / name for name in ('home', 'config', 'data', 'cache', 'runtime', 'tmp', 'tools', 'markers')}
        for folder in folders.values():
            folder.mkdir(mode=0o700)
        environment = dict(os.environ, HOME=str(folders['home']), XDG_CONFIG_HOME=str(folders['config']),
                           XDG_DATA_HOME=str(folders['data']), XDG_CACHE_HOME=str(folders['cache']),
                           XDG_STATE_HOME=str(work / 'state'), XDG_RUNTIME_DIR=str(folders['runtime']),
                           TMPDIR=str(folders['tmp']))
        media, covers = [], []
        for index, color in enumerate(('red', 'blue')):
            audio = work / f'Audio-{index}.mp3'
            cover = work / f'Cover-{index}.png'
            subprocess.run([ffmpeg, '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i',
                            'sine=duration=1', str(audio)], check=True, timeout=15, env=environment)
            subprocess.run([ffmpeg, '-nostdin', '-loglevel', 'error', '-f', 'lavfi', '-i',
                            f'color=c={color}:s=32x32', '-frames:v', '1', '-threads', '1', str(cover)],
                           check=True, timeout=15, env=environment)
            assert cover.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
            media.append(audio)
            covers.append(cover)
        release = work / 'release'
        # Kein Shell-/Kindprozess: exakt dieser eigene Prozess muss verschwinden.
        # SIGTERM ignorieren, damit auch die produktive SIGKILL-Eskalation zählt.
        fake_source = '#!' + sys.executable + '\n' + '''import json, os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
markers = Path(os.environ['TAGX_REVIEW_MARKERS'])
release = Path(os.environ['TAGX_REVIEW_RELEASE'])
started = time.monotonic()
pid = os.getpid()
fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
record = {'pid': pid, 'ppid': os.getppid(), 'pgid': os.getpgrp(), 'start': fields[19], 'started': started, 'args': sys.argv[1:]}
marker = markers / f'{pid}.json'
pending = marker.with_suffix('.tmp')
pending.write_text(json.dumps(record))
pending.replace(marker)
while not release.exists():
    if time.monotonic() - started >= 8:
        marker.with_suffix('.expired').touch()
        sys.exit(124)
    time.sleep(.01)
marker.with_suffix('.released').touch()
sys.stdout.buffer.write(Path(os.environ['TAGX_REVIEW_OUTPUT']).read_bytes())
'''
        fake_paths = [folders['tools'] / name for name in ('magick', 'convert')]
        for fake in fake_paths:
            fake.write_text(fake_source)
            fake.chmod(0o700)
        environment.update(PATH=str(folders['tools']) + os.pathsep + os.environ.get('PATH', ''),
                           TAGX_REVIEW_MARKERS=str(folders['markers']), TAGX_REVIEW_RELEASE=str(release),
                           TAGX_REVIEW_OUTPUT=str(covers[1]))
        engine = None

        def own_fake(record):
            info = process_info(record['pid'])
            if info is None or info['start'] != record['start'] or info['pgid'] != record['pid']:
                return False
            try:
                command = Path(f"/proc/{record['pid']}/cmdline").read_bytes().split(b'\0')
            except FileNotFoundError:
                return False
            return any(os.fsencode(path) in command for path in fake_paths)

        with (work / 'engine.log').open('w+') as log:
            try:
                engine = Engine(executable, environment, log)
                assert engine.call('hello')['coverConversion'] is True
                state = engine.call('open', {'paths': list(map(str, media))})
                assert state['total'] == 2, state
                originals = {}
                for audio, cover in zip(media, covers):
                    state = engine.call('setCover', {'path': str(audio), 'source': str(cover), 'revision': state['revision']})
                    originals[str(audio)] = engine.call('cover', {'path': str(audio)})
                    assert base64.b64decode(originals[str(audio)], validate=True) == cover.read_bytes()
                assert len(set(originals.values())) == 2, 'Zwei verschiedene Cover erforderlich'
                state = engine.call('select', {'paths': list(map(str, media))})
                # batchArtwork() im Frontend benutzt diese produktive IPC-Methode.
                batch_id = engine.send('batchCover', {'action': 'convert', 'format': 'png', 'revision': state['revision']})
                deadline = time.monotonic() + 5
                while not list(folders['markers'].glob('*.json')) and time.monotonic() < deadline:
                    assert engine.process.poll() is None, 'Engine vor Konverterstart beendet'
                    time.sleep(.01)
                markers = list(folders['markers'].glob('*.json'))
                assert len(markers) == 1, 'Fake-ImageMagick wurde nicht genau einmal gestartet'
                marker = markers[0]
                record = json.loads(marker.read_text())
                assert record['ppid'] == engine.process.pid and record['pgid'] == record['pid'], record
                assert record['args'][-1] == 'png:-', record
                assert own_fake(record), record
                # Absichtlich viel kürzer als die 8s-Fake-Frist. Synchroner Code
                # scheitert hier, nicht erst an einem späteren Coververgleich.
                blocked_state = engine.call('state', timeout=2)
                assert blocked_state['busy'] is True, blocked_state
                assert not release.exists() and not marker.with_suffix('.expired').exists()
                assert own_fake(record), 'Konverter blockiert nicht mehr'
                assert batch_id not in engine.responses, 'Batch wurde vor dem Abbruch beendet'
                engine.call('cancel', timeout=2)
                batch = engine.receive(batch_id, timeout=2)
                assert batch.get('error', {}).get('code') == 'operation_failed', batch
                state = engine.call('state', timeout=2)
                assert state['busy'] is False, state
                for audio in media:
                    assert engine.call('cover', {'path': str(audio)}) == originals[str(audio)], 'Coverpuffer nach Abbruch verändert'
                deadline = time.monotonic() + 1
                while process_info(record['pid']) is not None and time.monotonic() < deadline:
                    time.sleep(.01)
                assert process_info(record['pid']) is None, 'Eigener Fake-Prozess noch vorhanden (auch Zombie zählt nicht als weg)'
                assert not marker.with_suffix('.released').exists() and not marker.with_suffix('.expired').exists(), 'Nur Freigabe/Timeout statt Abbruch'
                assert len(list(folders['markers'].glob('*.json'))) == 1, 'Nach Abbruch wurde ein weiterer Konverter gestartet'
                print('Linux-IPC: state antwortet während blockierter PNG-Stapelkonvertierung mit busy; Abbruch, beide Originalpuffer, busy-Ende und Prozessende bestanden.')
            except BaseException:
                log.flush()
                log.seek(0)
                details = log.read()[-4000:]
                if details:
                    print('Engine-Diagnose:\n' + details, file=sys.stderr)
                raise
            finally:
                # Auch beim erwarteten Fehler gegen alten synchronen Code lösen.
                release.touch()
                try:
                    if engine is not None:
                        engine.close()
                finally:
                    for marker in folders['markers'].glob('*.json'):
                        record = json.loads(marker.read_text())
                        if own_fake(record):
                            try:
                                os.killpg(record['pid'], signal.SIGKILL)
                            except ProcessLookupError:
                                pass


if __name__ == '__main__':
    main()
