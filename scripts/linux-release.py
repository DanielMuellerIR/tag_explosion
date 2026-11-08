#!/usr/bin/env python3
"""Geprüfte Linux-Artefakte signieren und einen statischen Updatefeed erzeugen."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone

root = Path(__file__).resolve().parent.parent
version = (root / 'VERSION').read_text().strip()
output = root / 'build/linux'
archive = output / f'TagExplosion-{version}-x86_64.AppImage'
if not os.environ.get('TAURI_SIGNING_PRIVATE_KEY') and not os.environ.get('TAURI_SIGNING_PRIVATE_KEY_PATH'):
    raise SystemExit('Linux-Release benötigt den eigenen TAURI_SIGNING_PRIVATE_KEY oder dessen Dateipfad; kein Zugriff auf fremde Projektschlüssel')
if not archive.is_file():
    raise SystemExit('Das geprüfte Linux-AppImage fehlt')
manifest = json.loads((output / 'package-manifest.json').read_text())
if manifest.get('version') != version or manifest.get('appimageSHA256') != hashlib.sha256(archive.read_bytes()).hexdigest():
    raise SystemExit('Paket und Prüfmanifest stimmen nicht überein')
subprocess.run(['npm', 'exec', '--cache', str(root / '.build/npm-cache'), '--yes', '--package', '@tauri-apps/cli@2.11.4', '--', 'tauri', 'signer', 'sign', str(archive)], check=True, stdin=subprocess.DEVNULL)
signature = Path(str(archive) + '.sig').read_text().strip()
feed = {'version': version, 'pub_date': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'notes': 'Tag Explosion ' + version,
        'platforms': {'linux-x86_64-appimage': {'signature': signature,
            'url': f'https://github.com/DanielMuellerIR/tag_explosion/releases/download/v{version}/{archive.name}'}}}
(output / 'linux-updates.json').write_text(json.dumps(feed, indent=2) + '\n')
checksums = []
for path in sorted(output.iterdir()):
    if path.is_file() and path.name != 'SHA256SUMS':
        checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name)
(output / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n')
print('RELEASE OK:', output)
