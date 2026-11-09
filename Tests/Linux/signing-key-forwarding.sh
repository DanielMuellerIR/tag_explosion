#!/usr/bin/env bash
# Nur eigene bedeutungslose Datei, Docker und Generatoren sind gemockt.
set -euo pipefail
python3 - <<'PY'
import os, pathlib, subprocess, tempfile
source = pathlib.Path('Linux/build.sh').read_text()
with tempfile.TemporaryDirectory(prefix='tagx-key-forwarding-') as temp:
    root = pathlib.Path(temp)
    (root / 'Linux').mkdir()
    (root / 'Linux/build.sh').write_text(source)
    tools = root / 'tools'
    tools.mkdir()
    log = root / 'arguments'
    for name, body in {
        'python3': '#!/bin/sh\nexit 0\n',
        'docker': '#!/bin/sh\nprintf "%s\\0" "$@" >> "$ARGUMENT_LOG"\n',
    }.items():
        path = tools / name
        path.write_text(body)
        path.chmod(0o700)
    key = root / 'meaningless key'
    key.write_text('meaningless generated fixture')
    env = {k:v for k,v in os.environ.items() if not k.startswith('TAURI_SIGNING_')}
    env.update(PATH=str(tools)+':'+os.environ['PATH'], ARGUMENT_LOG=str(log), TAGX_IN_BUILDER='0')
    def run(*options, succeeds=True, error=None):
        log.write_bytes(b'')
        result = subprocess.run(['bash', str(root/'Linux/build.sh'), *options], env=env, capture_output=True)
        assert (result.returncode == 0) == succeeds, 'Unerwartetes Mock-Bauergebnis'
        args = log.read_bytes().decode().split('\0')
        if not succeeds:
            assert not any(args), 'Ungültige Schlüsselkonfiguration muss vor Docker-Bauten scheitern'
        if error is not None:
            assert error in result.stderr.decode(), 'Verständliche Konfliktmeldung fehlt'
        return args
    def no_file(args):
        assert not any('TAURI_SIGNING_PRIVATE_KEY_PATH=' in a or '/run/tagx-signing-key' in a for a in args), 'Unnötiger Dateischlüsselzugriff'
    missing = root / 'missing directory' / 'missing key'
    env['TAURI_SIGNING_PRIVATE_KEY_PATH'] = str(missing)
    for options in [('--debug',), (), ('--release', '--debug'), ('--release', '--no-package')]:
        # Kein --release: Standard ist ein unsignierter Paketbau.
        no_file(run(*options))
    env['TAURI_SIGNING_PRIVATE_KEY'] = 'meaningless inline fixture'
    conflict = 'Inline-Updateschlüssel und Updateschlüsseldatei sind gegenseitig ausgeschlossen'
    run('--release', succeeds=False, error=conflict)
    for options in [('--debug',), (), ('--release', '--debug'), ('--release', '--no-package')]:
        args = run(*options)
        no_file(args)
        assert not any('TAURI_SIGNING_' in a for a in args), 'Unnötige Schlüsselweitergabe'
    del env['TAURI_SIGNING_PRIVATE_KEY']
    run('--release', succeeds=False)
    env['TAURI_SIGNING_PRIVATE_KEY_PATH'] = str(key)
    key.chmod(0)
    try:
        no_file(run('--debug'))
        if not os.access(key, os.R_OK):
            run('--release', succeeds=False)
        else:
            print('Grenze: Prozess kann chmod-000-Fixture lesen; Unlesbarkeit nicht prüfbar')
    finally:
        key.chmod(0o600)
    del env['TAURI_SIGNING_PRIVATE_KEY_PATH']
    no_file(run('--release'))
    env['TAURI_SIGNING_PRIVATE_KEY_PATH'] = str(key)
    args = run('--release')
    forwarded = [a.split('=',1)[1] for a in args if a.startswith('TAURI_SIGNING_PRIVATE_KEY_PATH=')]
    assert len(forwarded) == 1, 'Dateischlüsselpfad fehlt im Container'
    assert str(key)+':'+forwarded[0]+':ro' in args, 'Schlüssel muss separat read-only eingebunden sein'
    for options in [('--debug',), (), ('--release', '--no-package')]:
        no_file(run(*options))
    env['TAURI_SIGNING_PRIVATE_KEY'] = 'meaningless inline fixture'
    run('--release', succeeds=False, error=conflict)
    del env['TAURI_SIGNING_PRIVATE_KEY_PATH']
    args = run('--release')
    no_file(args)
    assert 'TAURI_SIGNING_PRIVATE_KEY' in args, 'Alleiniger Inline-Key wird nicht weitergegeben'
    del env['TAURI_SIGNING_PRIVATE_KEY']
    env['TAURI_SIGNING_PRIVATE_KEY_PATH'] = 'meaningless key'
    args = run('--release')
    assert str(key)+':'+forwarded[0]+':ro' in args, 'Relativer Schlüsselpfad wird nicht aufgelöst'
print('Gemockte Schlüsselpfadweitergabe bestanden (kein Inhalt ausgegeben)')
PY
