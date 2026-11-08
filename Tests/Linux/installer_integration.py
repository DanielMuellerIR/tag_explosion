#!/usr/bin/env python3
"""Den veröffentlichten Installer gegen echte signierte AppImage-Bytes prüfen."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('appimage', type=Path)
parser.add_argument('--signature', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
image = args.appimage.resolve()
signature = (args.signature or Path(str(image) + '.sig')).resolve()
with tempfile.TemporaryDirectory(prefix='tagx-installer-') as temporary:
    work = Path(temporary)
    destination = work / 'installation with spaces'
    data = work / 'data'
    environment = dict(os.environ, XDG_DATA_HOME=str(data))
    def install(source=image, target=destination, success=True):
        result = subprocess.run(['python3', str(root / 'Linux/install.py'), str(source), '--signature', str(signature), '--destination', str(target)], env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
    install()
    current = destination / 'TagExplosion.AppImage'
    expected = hashlib.sha256(image.read_bytes()).digest()
    assert hashlib.sha256(current.read_bytes()).digest() == expected and os.access(current, os.X_OK)
    desktop = data / 'applications/io.github.danielmuellerir.tagexplosion.desktop'
    assert 'Exec="' + str(current) + '" %F' in desktop.read_text()
    assert (data / 'icons/hicolor/512x512/apps/tag-explosion.png').is_file()
    if shutil.which('desktop-file-validate'):
        subprocess.run(['desktop-file-validate', str(desktop)], check=True)
    install()
    assert hashlib.sha256((destination / 'TagExplosion.previous.AppImage').read_bytes()).digest() == expected
    corrupt = work / 'corrupt.AppImage'; shutil.copy2(image, corrupt)
    with corrupt.open('r+b') as stream:
        stream.seek(4096); value = stream.read(1); stream.seek(4096); stream.write(bytes([value[0] ^ 1]))
    install(corrupt, success=False)
    assert hashlib.sha256(current.read_bytes()).digest() == expected
    guarded = work / 'guarded'; guarded.mkdir()
    protected = work / 'user-data'; protected.write_text('protected')
    (guarded / 'TagExplosion.AppImage').symlink_to(protected)
    install(target=guarded, success=False)
    assert protected.read_text() == 'protected' and (guarded / 'TagExplosion.AppImage').is_symlink()
    print('INSTALL: Signatur, Desktop-Eintrag, erneute Installation, vorige Version, beschädigter Download und Dateiverweise bestanden.')
