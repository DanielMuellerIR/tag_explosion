#!/usr/bin/env python3
"""Signiertes AppImage im Benutzerkonto mit Desktop-Eintrag installieren."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PUBLIC_KEY = 'dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEY2QTBDNEI5RUYyOTM2OTQKUldTVU5pbnZ1Y1NnOXI4U05nQTliSVh1cHptNzFYdWozZ2YzbElZeldGQnQzRW1vaThjYlpUSW8K'


def verify(image, signature):
    key = base64.b64decode(base64.b64decode(PUBLIC_KEY).decode().splitlines()[1], validate=True)
    lines = base64.b64decode(signature.read_text().strip(), validate=True).decode().splitlines()
    signed = base64.b64decode(lines[1], validate=True)
    global_signature = base64.b64decode(lines[3], validate=True)
    if len(key) != 42 or len(signed) != 74 or signed[:2] != b'ED' or key[2:10] != signed[2:10] or not lines[2].startswith('trusted comment: '):
        raise ValueError('Ungültige Herausgebersignatur')
    digest = hashlib.blake2b()
    with image.open('rb') as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    with tempfile.TemporaryDirectory(prefix='tagx-signature-') as temporary:
        work = Path(temporary)
        (work / 'public.der').write_bytes(bytes.fromhex('302a300506032b6570032100') + key[10:])
        for content, proof in [(digest.digest(), signed[10:]), (signed[10:] + lines[2][17:].encode(), global_signature)]:
            (work / 'content').write_bytes(content)
            (work / 'signature').write_bytes(proof)
            checked = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(work / 'public.der'), '-rawin', '-in', str(work / 'content'), '-sigfile', str(work / 'signature')], capture_output=True)
            if checked.returncode:
                raise ValueError('Signaturprüfung fehlgeschlagen; Installation unverändert')


def own_file(path):
    if path.is_symlink() or (path.exists() and (not path.is_file() or path.stat().st_uid != os.getuid())):
        raise ValueError('Ziel ist keine eigene reguläre Datei: ' + str(path))


def atomic_copy(source, destination):
    own_file(destination)
    with tempfile.NamedTemporaryFile(prefix='.tagx-install-', dir=destination.parent, delete=False) as staged:
        path = Path(staged.name)
        try:
            with source.open('rb') as incoming:
                shutil.copyfileobj(incoming, staged)
            staged.flush()
            os.fsync(staged.fileno())
            path.chmod(0o755)
            os.replace(path, destination)
        finally:
            path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('appimage', type=Path)
    parser.add_argument('--signature', type=Path)
    parser.add_argument('--destination', type=Path, default=Path.home() / '.local/opt/tag-explosion')
    parser.add_argument('--no-desktop', action='store_true')
    args = parser.parse_args()
    image = args.appimage.resolve(strict=True)
    signature = args.signature or Path(str(image) + '.sig')
    verify(image, signature)
    with image.open('rb') as source:
        header = source.read(11)
    if header[:4] != b'\x7fELF' or header[8:11] != b'AI\x02':
        raise ValueError('Kein AppImage vom Typ 2')
    directory = args.destination.expanduser().absolute()
    if directory.is_symlink():
        raise ValueError('Installationsverzeichnis darf kein Dateiverweis sein')
    directory.mkdir(parents=True, exist_ok=True)
    if directory.stat().st_uid != os.getuid():
        raise ValueError('Installationsverzeichnis gehört einem anderen Benutzer')
    current = directory / 'TagExplosion.AppImage'
    own_file(current)
    previous = directory / 'TagExplosion.previous.AppImage'
    own_file(previous)
    # Erst die geprüfte neue Datei vollständig vorbereiten; die laufende Datei
    # bleibt bei Fehlern und bis zum atomaren Wechsel erreichbar.
    with tempfile.TemporaryDirectory(prefix='.tagx-install-', dir=directory) as temporary:
        candidate = Path(temporary) / 'TagExplosion.AppImage'
        atomic_copy(image, candidate)
        if current.exists():
            atomic_copy(current, previous)
        os.replace(candidate, current)
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if not args.no_desktop:
        data = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
        applications = data / 'applications'
        applications.mkdir(parents=True, exist_ok=True)
        desktop = applications / 'io.github.danielmuellerir.tagexplosion.desktop'
        own_file(desktop)
        # Desktop-Exec besitzt eigene Escape-Regeln; Prozentzeichen sind Feldcodes.
        escaped = str(current).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
        desktop.write_text('[Desktop Entry]\nType=Application\nName=Tag Explosion\nComment=Medien-Metadaten anzeigen und bearbeiten\nExec="' + escaped + '" %F\nIcon=tag-explosion\nTerminal=false\nCategories=Utility;\nMimeType=audio/mpeg;audio/flac;audio/ogg;audio/mp4;video/mp4;image/jpeg;image/png;application/pdf;application/epub+zip;\n')
        icon = Path(__file__).with_name('icon.png')
        if not icon.is_file():
            icon = Path(__file__).parent / 'icons/icon.png'
        if icon.is_file():
            target = data / 'icons/hicolor/512x512/apps/tag-explosion.png'
            target.parent.mkdir(parents=True, exist_ok=True)
            own_file(target)
            shutil.copyfile(icon, target)
        if shutil.which('update-desktop-database'):
            subprocess.run(['update-desktop-database', str(applications)], check=False, stdout=subprocess.DEVNULL)
    print('Installiert: ' + str(current))
    print('Vorige Version, falls vorhanden: ' + str(previous))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, IndexError, UnicodeError) as error:
        raise SystemExit(str(error))
