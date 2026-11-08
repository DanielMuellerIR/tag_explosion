#!/usr/bin/env python3
"""Signaturen, echte Paketwechsel und beide Neustartwege im AppImage prüfen."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
from selenium import webdriver
from selenium.webdriver.remote.remote_connection import RemoteConnection

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--current', type=Path, required=True)
parser.add_argument('--next', type=Path, required=True)
parser.add_argument('--signature', type=Path, required=True)
parser.add_argument('--base-version', required=True)
parser.add_argument('--version', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
signature = args.signature.read_text().strip()
signature_lines = base64.b64decode(signature).decode().splitlines()
proof = bytearray(base64.b64decode(signature_lines[1])); proof[-1] ^= 1
signature_lines[1] = base64.b64encode(proof).decode()
bad_signature = base64.b64encode(('\n'.join(signature_lines) + '\n').encode()).decode()
mode = 'bad-signature'

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.path == '/feed.json':
            value = {'version': str(int(args.version.split('.')[0]) + 1) + '.0.0' if mode == 'wrong-version' else args.version,
                     'pub_date': '2026-11-08T00:00:00Z', 'notes': 'Lokaler Update-Test',
                     'platforms': {'linux-x86_64-appimage': {'signature': bad_signature if mode == 'bad-signature' else signature,
                                  'url': f'http://127.0.0.1:{self.server.server_port}/download.AppImage'}}}
            data = json.dumps(value).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        elif self.path == '/download.AppImage':
            self.send_response(200); self.send_header('Content-Length', str(args.next.stat().st_size)); self.end_headers()
            with args.next.open('rb') as source:
                if mode == 'truncated': self.wfile.write(source.read(4096))
                else: shutil.copyfileobj(source, self.wfile)
        else:
            self.send_error(404)

def digest(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()

with tempfile.TemporaryDirectory(prefix='tagx-update-smoke-') as temporary:
    work = Path(temporary)
    current = work / 'TagExplosion.AppImage'
    shutil.copy2(args.current, current)
    before = digest(current)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = dict(os.environ, HOME=str(work), XDG_DATA_HOME=str(work / 'data'), XDG_CONFIG_HOME=str(work / 'config'),
                       XDG_CACHE_HOME=str(work / 'cache'), APPIMAGE_EXTRACT_AND_RUN='1', LANG='de_DE.UTF-8',
                       TAGX_TEST_UPDATE_FEED=f'http://127.0.0.1:{server.server_port}/feed.json')
    environment.pop('TAGX_ENGINE', None)
    process = subprocess.Popen([str(root / '.build/driver/bin/tauri-driver'), '--port', '4444'], env=environment,
                               stdout=(work / 'driver.log').open('w'), stderr=subprocess.STDOUT)
    driver = None
    RemoteConnection.set_timeout(120)
    def connect(application):
        options = webdriver.common.options.ArgOptions()
        options.set_capability('tauri:options', {'application': str(application)})
        options.set_capability('timeouts', {'implicit': 0, 'pageLoad': 30000, 'script': 120000})
        return webdriver.Remote(command_executor='http://127.0.0.1:4444', options=options)
    def invoke(command, params=None, failure=False):
        result = driver.execute_async_script("const done=arguments[arguments.length-1]; window.__TAURI__.core.invoke(arguments[0],arguments[1]).then(value=>done({value})).catch(error=>done({error:String(error)}));", command, params or {})
        if failure:
            assert result.get('error'), result
        else:
            assert not result.get('error'), result
        return result.get('value')
    def media(method, params=None):
        return invoke('media', {'method': method, 'params': params or {}})
    def version():
        return driver.execute_async_script('const done=arguments[arguments.length-1]; window.__TAURI__.app.getVersion().then(done);')
    def close_session():
        # extract-and-run besitzt einen Runtime-Elternprozess. WebKitWebDriver
        # beendet nur diesen Launcher; deshalb regulär das App-Fenster schließen.
        try:
            driver.execute_script("void window.__TAURI__.core.invoke('close_window')")
        except Exception:
            pass
        time.sleep(.5)
        RemoteConnection.set_timeout(15)
        try:
            driver.quit()
        finally:
            RemoteConnection.set_timeout(120)
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen('http://127.0.0.1:4444/status', timeout=1); break
            except OSError: time.sleep(.1)
        driver = connect(current)
        assert version() == args.base_version
        media_file = work / 'Unchanged.mp3'
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=duration=1', '-metadata', 'title=Original', str(media_file)], check=True)
        state = media('open', {'paths': [str(media_file)]})
        entry = media('entry', {'path': str(media_file)})
        entry['properties'] = [{'key': 'TITLE', 'value': 'Ungespeicherter Entwurf'}]
        state = media('edit', {'path': str(media_file), 'values': entry, 'revision': state['revision']})
        for rejected in ['bad-signature', 'truncated', 'wrong-version']:
            print('Update-Prüfung: ' + rejected, flush=True)
            mode = rejected
            found = invoke('check_update')
            assert found['available']
            invoke('install_update', {'version': found['version']}, failure=True)
            assert digest(current) == before and not (work / 'TagExplosion.previous.AppImage').exists()
        mode = 'valid'
        found = invoke('check_update'); invoke('install_update', {'version': found['version']})
        previous = work / 'TagExplosion.previous.AppImage'
        assert digest(current) == digest(args.next) and digest(previous) == before
        assert version() == args.base_version, 'Der laufende alte Mount muss bis zum regulären Beenden bestehen bleiben'
        assert media('state')['dirty']
        assert any(item['value'] == 'Ungespeicherter Entwurf' for item in media('entry', {'path': str(media_file)})['properties'])
        closing = invoke('close_window')
        assert not closing['closed'] and closing['state'].get('conflict')
        media('resolve', {'dirty': 'cancel'})
        assert media('state')['dirty']
        state = media('state')
        media('revert', {'revision': state['revision']})
        close_session(); driver = connect(current)
        assert version() == args.version and media('hello')['protocolVersion'] == 1
        close_session(); driver = connect(previous)
        assert version() == args.base_version and media('hello')['protocolVersion'] == 1
        tags = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags=title', '-of', 'json', str(media_file)]))['format']['tags']
        assert tags['title'] == 'Original'
        print('UPDATE: falsche Signatur, Abbruch und falsche Version abgewiesen; Entwurf und alter Mount erhalten; neuer und voriger Stand tatsächlich gestartet.')
    finally:
        if driver:
            try:
                state = media('state')
                if state['dirty']: media('revert', {'revision': state['revision']})
            except Exception:
                pass
            close_session()
        process.terminate(); process.wait(timeout=5)
        server.shutdown(); server.server_close()
