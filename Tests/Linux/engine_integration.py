#!/usr/bin/env python3
"""Reale IPC-, Konflikt- und Schreibwege ohne Browser prüfen."""
import argparse
import json
import os
from pathlib import Path
import select
import selectors
import shutil
import signal
import subprocess
import tempfile
import time
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine', type=Path, default=Path('.build/debug/tagx-engine'))
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='tagx-ipc-') as temporary:
    work = Path(temporary)
    environment = dict(os.environ, HOME=str(work), XDG_DATA_HOME=str(work / 'data'), XDG_CONFIG_HOME=str(work / 'config'))
    tools = work / 'tools'; tools.mkdir()
    marker = work / 'mediainfo-started'
    fake = tools / 'mediainfo'
    fake.write_text(
        f'#!{sys.executable}\n'
        'from pathlib import Path\nimport json\nimport os\nimport signal\nimport time\n'
        'stdin = os.fstat(0)\nnull = os.stat(os.devnull)\n'
        'isolated = (stdin.st_dev, stdin.st_ino) == (null.st_dev, null.st_ino)\n'
        'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
        'child = os.fork()\n'
        'if child == 0:\n'
        '    os.close(1)\n    os.close(2)\n    time.sleep(60)\n    os._exit(0)\n'
        f'marker = Path({str(marker)!r})\n'
        'staging = marker.with_suffix(".tmp")\n'
        'staging.write_text(json.dumps({"stdin": isolated and not os.read(0, 1),\n'
        '                               "tool": os.getpid(), "child": child}))\n'
        'staging.rename(marker)\n'
        'time.sleep(60)\n'
    )
    fake.chmod(0o755)
    environment['PATH'] = str(tools) + os.pathsep + os.environ.get('PATH', '')
    engine = subprocess.Popen([str(args.engine.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(engine.stdout, selectors.EVENT_READ)
    sequence = 0
    responses = {}
    tool_fds = []
    def call(method, params=None, session='main', error=None):
        global sequence
        sequence += 1
        engine.stdin.write(json.dumps({'id': sequence, 'session': session, 'method': method, 'params': params or {}}).encode() + b'\n')
        engine.stdin.flush()
        while sequence not in responses:
            assert selector.select(30), 'Engine antwortet nicht: ' + method
            incoming = json.loads(engine.stdout.readline())
            responses[incoming['id']] = incoming
        response = responses.pop(sequence)
        if error:
            assert response['error']['code'] == error, response
            return
        assert not response.get('error'), response
        return response.get('result')

    def start_info(session, path):
        global sequence
        marker.unlink(missing_ok=True)
        sequence += 1
        engine.stdin.write(json.dumps({
            'id': sequence, 'session': session, 'method': 'info', 'params': {'path': str(path)},
        }).encode() + b'\n')
        engine.stdin.flush()
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        assert marker.exists(), 'MediaInfo-Auftrag wurde nicht gestartet'
        started = json.loads(marker.read_text())
        assert started['stdin'], 'Werkzeug hat keinen getrennten stdin'
        fds = []
        for key in ('tool', 'child'):
            descriptor = os.pidfd_open(started[key])
            tool_fds.append(descriptor)
            fds.append(descriptor)
        return sequence, *fds

    def info_cancelled(request_id):
        while request_id not in responses:
            assert selector.select(5), 'MediaInfo-Abbruch blieb hängen'
            incoming = json.loads(engine.stdout.readline())
            responses[incoming['id']] = incoming
        assert responses.pop(request_id)['result']['cancelled'] is True

    def assert_tool_exited(tool_fd, child_fd):
        assert select.select([tool_fd], [], [], 0)[0], 'MediaInfo läuft nach der Abschlussantwort noch'
        # Der Worker wartet auf den Prozessleiter. Der Nachkomme kann erst
        # beim nächsten Scheduling auf den Gruppenabbruch reagieren.
        assert select.select([child_fd], [], [], 2)[0], 'Nachkomme überlebte den Gruppenabbruch'

    try:
        requested_language = {'LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LANG', 'TAGX_DESKTOP_LANGUAGE'}
        locale_base = {key: value for key, value in environment.items() if key not in requested_language}
        invalid = b'{"id":1,"session":"locale","method":"unknown","params":{}}\n'
        for locale, expected in [
            ({'LC_MESSAGES': 'de_DE.UTF-8', 'LANG': 'en_US.UTF-8'}, 'Der Vorgang ist unbekannt.'),
            ({'LANGUAGE': 'fr:en:de', 'LC_MESSAGES': 'de_DE.UTF-8'}, 'Unknown desktop operation.'),
        ]:
            probe = subprocess.run([str(args.engine.resolve())], input=invalid, env=locale_base | locale,
                                   capture_output=True, check=True, timeout=10)
            failure = json.loads(probe.stdout)['error']
            assert failure == {'code': 'unknown_method', 'message': expected}, failure
        assert call('hello')['protocolVersion'] == 1
        assert call('state')['total'] == 0
        media = work / 'Signal.mp3'
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=duration=1', '-metadata', 'title=Original', str(media)], check=True)
        state = call('open', {'paths': [str(media)]})
        assert state['total'] == 1, state
        values = call('entry', {'path': str(media)})
        values['properties'] = [{'key': 'TITLE', 'value': 'Geändert'}, {'key': 'ARTIST', 'value': 'Überprüfung'}]
        call('edit', {'path': str(media), 'values': values, 'revision': -1}, error='revision_changed')
        state = call('edit', {'path': str(media), 'values': values, 'revision': state['revision']})
        assert state['dirty']
        other = call('open', {'paths': [str(media)]}, session='other')
        assert not other['dirty']
        state = call('saveAll', {'revision': state['revision']})
        assert not state['dirty'] and not state.get('alert'), state
        tags = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags', '-of', 'json', str(media)]))['format']['tags']
        assert tags['title'] == 'Geändert' and tags['artist'] == 'Überprüfung', tags
        # Das zweite Fenster hat noch die alte Dateifassung. Kein stiller Verlust.
        old = call('entry', {'path': str(media)}, session='other')
        old['properties'] = [{'key': 'TITLE', 'value': 'Stale'}]
        other = call('edit', {'path': str(media), 'values': old, 'revision': other['revision']}, session='other')
        other = call('saveAll', {'revision': other['revision']}, session='other')
        assert other.get('staleWrite'), other
        call('resolve', {'overwrite': False}, session='other')
        assert any(item['key'] == 'TITLE' and item['value'] == 'Geändert' for item in call('entry', {'path': str(media)})['properties'])
        close = call('close', session='other')
        assert not close['closed'] and close['state'].get('conflict'), close
        call('resolve', {'dirty': 'cancel'}, session='other')
        assert call('state', session='other')['dirty']
        assert call('beginUpdate') is True
        call('edit', {'path': str(media), 'values': values, 'revision': state['revision']}, error='busy')
        call('endUpdate')
        second = work / '02 - Zweiter Titel.mp3'
        shutil.copyfile(media, second)
        state = call('open', {'paths': [str(second)]})
        state = call('select', {'paths': [str(media), str(second)]})
        schema = call('batchInfo')
        assert schema['common']['TITLE'] == ['Geändert'], schema
        state = call('batchEdit', {'changes': {'ARTIST': ['Gemeinsamer Interpret']}, 'revision': state['revision']})
        state = call('batchNumber', {'revision': state['revision']})
        cover = Path(__file__).resolve().parents[1] / 'TagExplosionCoreTests/Fixtures/generated/cover.png'
        if cover.is_file():
            state = call('batchCover', {'action': 'set', 'source': str(cover), 'revision': state['revision']})
            assert call('batchCoverPreview')
        pipe = work / 'cover.fifo'
        os.mkfifo(pipe)
        call('batchCover', {'action': 'set', 'source': str(pipe), 'revision': state['revision']}, error='invalid_file')
        oversized = work / 'oversized.png'
        with oversized.open('wb') as file:
            file.truncate(16 * 1024 * 1024 + 1)
        call('batchCover', {'action': 'set', 'source': str(oversized), 'revision': state['revision']}, error='input_too_large')
        state = call('saveAll', {'revision': state['revision']})
        assert not state['dirty'] and not state.get('alert'), state
        for index, path in enumerate([media, second]):
            tags = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags', '-of', 'json', str(path)]))['format']['tags']
            assert tags['artist'] == 'Gemeinsamer Interpret' and tags['track'] == str(index + 1) + '/2', tags
        if shutil.which('exiftool'):
            pictures = [work / 'Bild1.png', work / 'Bild2.png']
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=s=32x32', '-frames:v', '1', '-threads', '1', str(pictures[0])], check=True)
            shutil.copyfile(pictures[0], pictures[1])
            state = call('open', {'paths': [str(p) for p in pictures]})
            state = call('select', {'paths': [str(p) for p in pictures]})
            assert 'rating' in call('batchInfo')['supportedFields']
            state = call('batchEdit', {'changes': {'rating': 3}, 'revision': state['revision']})
            state = call('saveAll', {'revision': state['revision']})
            assert not state['dirty'] and not state.get('alert'), state
            for picture in pictures:
                assert subprocess.check_output(['exiftool', '-s3', '-XMP-xmp:Rating', str(picture)], text=True).strip() == '3'
            sidecar = pictures[0].with_suffix('.xmp')
            subprocess.run(['exiftool', '-o', str(sidecar), '-XMP-dc:Title=Sidecar-Titel', str(pictures[0])], check=True, stdout=subprocess.DEVNULL)
            state = call('open', {'paths': [str(pictures[0])]}, session='image-sidecar')
            groups = call('imageMetadata', {'path': str(pictures[0])}, session='image-sidecar')
            assert any(g['name'].startswith('Sidecar · ') and any(f['value'] == 'Sidecar-Titel' for f in g['fields']) for g in groups), groups
            assert call('entry', {'path': str(pictures[0])}, session='image-sidecar')['writeDestination']
        # Das Schließen bricht den laufenden Werkzeugauftrag selbst ab und
        # wartet auf sein Ende, bevor die Sitzung freigegeben wird.
        call('open', {'paths': [str(media)]}, session='closing')
        closing_info_id, tool_fd, child_fd = start_info('closing', media)
        assert call('close', session='closing')['closed'] is True
        assert_tool_exited(tool_fd, child_fd)
        info_cancelled(closing_info_id)
        assert call('prepareUpdate') is True
        # Ein lang laufendes Werkzeug muss unabhängig von der UI-Auftragskette
        # abbrechbar bleiben und währenddessen den Paketwechsel sperren.
        info_id, tool_fd, child_fd = start_info('main', media)
        assert call('prepareUpdate') is False
        started = time.monotonic()
        call('cancel', {'operation': 'info'})
        info_cancelled(info_id)
        assert_tool_exited(tool_fd, child_fd)
        assert time.monotonic() - started < 5
        assert call('prepareUpdate') is True
        # Ungültige JSON-Zeile beendet den Worker mit definiertem Fehler, ohne
        # einen vorher akzeptierten Speichervorgang ungeprüft zu wiederholen.
        engine.stdin.write(b'{not-json}\n')
        engine.stdin.flush()
        engine.stdin.close()
        engine.wait(timeout=10)
        print('IPC: Version, Revision, getrennte Fenster, Unicode-Speichern, veraltete Datei, Schließen, Bildbewertung, Sidecar-Anzeige, Werkzeugabbruch und Updatesperre bestanden.')
    finally:
        for descriptor in tool_fds:
            try:
                signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            except ProcessLookupError:
                pass
            finally:
                os.close(descriptor)
        selector.close()
        if engine.poll() is None:
            engine.terminate()
            engine.wait(timeout=5)
