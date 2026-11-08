#!/usr/bin/env python3
"""Linux-AppDir vervollständigen, prüfen und erst danach neu als AppImage packen."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
version = (root / 'VERSION').read_text().strip()
bundles = root / 'Linux/target/release/bundle/appimage'
appdir = bundles / 'TagExplosion.AppDir'
if appdir.exists():
    shutil.rmtree(appdir)
(appdir / 'usr/bin').mkdir(parents=True)
shutil.copy2(root / 'Linux/target/release/tag-explosion-linux', appdir / 'usr/bin/tag-explosion-linux')
shutil.copy2(root / '.build/release/tagx-engine', appdir / 'usr/bin/tagx-engine')
(appdir / 'tag-explosion.desktop').write_text('[Desktop Entry]\nType=Application\nName=Tag Explosion\nExec=tag-explosion-linux %F\nIcon=tag-explosion\nCategories=Utility;\nTerminal=false\n')
shutil.copy2(root / 'Linux/icons/icon.png', appdir / 'tag-explosion.png')
resources = appdir / 'usr/share/tag-explosion'
resources.mkdir(parents=True, exist_ok=True)
output = root / 'build/linux'
output.mkdir(parents=True, exist_ok=True)

# Die Laufzeitinventare und passenden Quellen bleiben dieselben verbindlichen
# Prüfer wie im Mac-Release; Linux bekommt lediglich die passende Temurin-JRE.
policy = hashlib.sha256((root / 'licenses/validation/components.lock.json').read_bytes()).hexdigest()[:16]
kosit = root / '.validation-build' / ('linux-xrechnung-' + policy)
kosit_sources = Path(str(kosit) + '-sources')
if not kosit.exists():
    subprocess.run(['python3', str(root / 'scripts/prepare-xrechnung-validator.py'), '--os', 'linux', '--arch', 'x86_64', '--output', str(kosit), '--sources-output', str(kosit_sources)], check=True)
subprocess.run(['python3', str(root / 'scripts/validation_compliance.py'), str(kosit), '--sources', str(kosit_sources)], check=True)
pdf_policy = hashlib.sha256((root / 'licenses/pdf-validation/components.lock.json').read_bytes()).hexdigest()[:16]
pdf = root / '.validation-build' / ('pdf-' + pdf_policy)
pdf_sources = Path(str(pdf) + '-sources')
if not pdf.exists():
    subprocess.run(['python3', str(root / 'scripts/prepare-pdf-validator.py'), '--output', str(pdf), '--sources-output', str(pdf_sources)], check=True)
subprocess.run(['python3', str(root / 'scripts/pdf_validation_compliance.py'), str(pdf), '--sources', str(pdf_sources)], check=True)
for origin, name in [(kosit, 'XRechnungValidator'), (pdf, 'PDFValidator')]:
    destination = resources / name
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(origin, destination, symlinks=True)
for sources, suffix in [(kosit_sources, 'validation-sources'), (pdf_sources, 'pdf-validation-sources')]:
    archive = output / f'TagExplosion-{version}-linux-{suffix}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
        for path in sorted(sources.rglob('*')):
            if path.is_file():
                package.write(path, sources.name + '/' + str(path.relative_to(sources)))
    with zipfile.ZipFile(archive) as package:
        bad = package.testzip()
        if bad:
            raise SystemExit('Beschädigtes Quellen-ZIP: ' + bad)

# GTK/WebKit und die Grafikbibliotheken bleiben beim Desktop. Ein altes GTK
# neben einem neuen System-WebKit mischt ABIs. Nur die Engine bekommt einen
# eigenen Suchpfad für ihre fest zusammengestellten Bibliotheken.
library_root = appdir / 'usr/lib'
if library_root.exists():
    shutil.rmtree(library_root)
library_directory = library_root / 'tagx'
library_directory.mkdir(parents=True, exist_ok=True)
system_libraries = re.compile(r'^(ld-linux|lib(?:c|m|pthread|dl|rt|resolv|util)\.so)')
engine = appdir / 'usr/bin/tagx-engine'
queue = [engine]
inspected = set()
origins = {}
while queue:
    binary = queue.pop()
    if binary in inspected:
        continue
    inspected.add(binary)
    result = subprocess.run(['ldd', str(binary)], capture_output=True, text=True,
                            env=dict(os.environ, LD_LIBRARY_PATH=str(library_directory)))
    if result.returncode or 'not found' in result.stdout:
        raise SystemExit('Bibliotheksprüfung fehlgeschlagen: ' + result.stdout + result.stderr)
    for name, source in re.findall(r'^\s*(\S+)\s+=>\s+(/\S+)', result.stdout, flags=re.M):
        if system_libraries.match(name):
            continue
        destination = library_directory / name
        if not destination.exists():
            origin = Path(source).resolve()
            shutil.copy2(origin, destination)
            origins[name] = str(origin)
        queue.append(destination)
(resources / 'library-origins.json').write_text(json.dumps(origins, indent=2) + '\n')
# RUNPATH wirkt nur beim Laden dieser ELF-Dateien. Ein globaler
# LD_LIBRARY_PATH würde auch Systemwerkzeuge wie MediaInfo beeinflussen.
subprocess.run(['patchelf', '--set-rpath', '$ORIGIN/../lib/tagx', str(engine)], check=True)
for library in library_directory.iterdir():
    subprocess.run(['patchelf', '--set-rpath', '$ORIGIN', str(library)], check=True)
result = subprocess.run(['ldd', str(engine)], capture_output=True, text=True,
                        env={key: value for key, value in os.environ.items() if key != 'LD_LIBRARY_PATH'})
if result.returncode or 'not found' in result.stdout:
    raise SystemExit('Engine-RUNPATH unvollständig: ' + result.stdout + result.stderr)
launcher = appdir / 'AppRun'
if launcher.exists() or launcher.is_symlink():
    launcher.unlink()
launcher.write_text("#!/bin/sh\nset -eu\nhere=\"$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\"\nexport GDK_BACKEND=\"${GDK_BACKEND:-wayland,x11}\"\nexec \"$here/usr/bin/tag-explosion-linux\" \"$@\"\n")
launcher.chmod(0o755)
subprocess.run(['python3', str(root / 'scripts/linux-notices.py'), str(appdir)], check=True)

for name in ['LICENSE', 'THIRD-PARTY-NOTICES.md', 'VERSION']:
    shutil.copy2(root / name, resources / name)
shutil.copy2(root / 'docs/linux.md', resources / 'Linux.md')
manifest = {'identifier': 'io.github.danielmuellerir.tagexplosion', 'version': version, 'os': 'linux', 'architecture': 'x86_64', 'glibcBaseline': '2.39',
            'validationPolicySHA256': hashlib.sha256((root / 'licenses/validation/components.lock.json').read_bytes()).hexdigest(),
            'pdfValidationPolicySHA256': hashlib.sha256((root / 'licenses/pdf-validation/components.lock.json').read_bytes()).hexdigest()}
(resources / 'package.json').write_text(json.dumps(manifest, indent=2) + '\n')

# Gepinntes offizielles AppImage-Werkzeug; auch dessen eingebettete Runtime
# wird wiederverwendet. Es gibt keinen unversionierten Runtime-Nachdownload.
from urllib.request import urlopen
cache = root / '.build/appimage-tool'
cache.mkdir(parents=True, exist_ok=True)
tool = cache / 'appimagetool-1.9.1-x86_64.AppImage'
expected = 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
if not tool.exists():
    with urlopen('https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage', timeout=60) as response:
        tool.write_bytes(response.read())
if hashlib.sha256(tool.read_bytes()).hexdigest() != expected:
    raise SystemExit('AppImage-Bauwerkzeug hat eine unerwartete Prüfsumme')
tool.chmod(0o755)
offset = int(subprocess.check_output([str(tool), '--appimage-offset'], text=True).strip())
runtime = cache / 'runtime-x86_64'
runtime.write_bytes(tool.read_bytes()[:offset])
archive = output / f'TagExplosion-{version}-x86_64.AppImage'
subprocess.run([str(tool), '--appimage-extract-and-run', '--runtime-file', str(runtime), '--mksquashfs-opt', '-processors', '--mksquashfs-opt', '3', str(appdir), str(archive)], check=True,
               env=dict(os.environ, ARCH='x86_64', NO_STRIP='1'))
archive.chmod(0o755)
manifest['appimageSHA256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / 'package-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
shutil.copy2(root / 'Linux/install.py', output / 'install.py')
shutil.copy2(root / 'Linux/updates.pub', output / 'updates.pub')
print('PACKAGE OK:', archive)

shutil.copy2(root / 'Linux/icons/icon.png', output / 'icon.png')
