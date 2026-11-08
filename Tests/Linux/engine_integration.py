#!/usr/bin/env python3
"""Reale IPC-, Konflikt- und Schreibwege ohne Browser prüfen."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
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
    fake.write_text('#!' + sys.executable + '\nfrom pathlib import Path\nimport time\nPath(' + repr(str(marker)) + ').touch()\ntime.sleep(60)\n')
    fake.chmod(0o755)
    environment['PATH'] = str(tools) + os.pathsep + os.environ.get('PATH', '')
    engine = subprocess.Popen([str(args.engine.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(engine.stdout, selectors.EVENT_READ)
    sequence = 0
    responses = {}
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
    try:
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
        # Ein lang laufendes Werkzeug muss unabhängig von der UI-Auftragskette
        # abbrechbar bleiben und währenddessen den Paketwechsel sperren.
        sequence += 1
        info_id = sequence
        engine.stdin.write(json.dumps({'id': info_id, 'session': 'main', 'method': 'info', 'params': {'path': str(media)}}).encode() + b'\n')
        engine.stdin.flush()
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline: time.sleep(.02)
        assert marker.exists(), 'MediaInfo-Auftrag wurde nicht gestartet'
        assert call('prepareUpdate') is False
        started = time.monotonic()
        call('cancel', {'operation': 'info'})
        while info_id not in responses:
            assert selector.select(5), 'MediaInfo-Abbruch blieb hängen'
            incoming = json.loads(engine.stdout.readline()); responses[incoming['id']] = incoming
        assert responses.pop(info_id)['result']['cancelled'] is True
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
        selector.close()
        if engine.poll() is None:
            engine.terminate()
            engine.wait(timeout=5)
