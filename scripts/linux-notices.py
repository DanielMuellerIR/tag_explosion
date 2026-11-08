#!/usr/bin/env python3
"""Originalhinweise und passende Bibliotheksquellen des Linux-Pakets sammeln."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from urllib.request import urlopen
import zipfile

root = Path(__file__).resolve().parent.parent
appdir = Path(sys.argv[1]).resolve()
resources = appdir / 'usr/share/tag-explosion'
legal = resources / 'legal'
legal.mkdir(parents=True, exist_ok=True)
cache = root / '.validation-build/linux-library-sources'
cache.mkdir(parents=True, exist_ok=True)
origins = json.loads((resources / 'library-origins.json').read_text())
inventory = {'libraries': [], 'rust': [], 'swift': '6.2.1', 'taglib': '2.3.1'}
packages = {}
for name, path in origins.items():
    if path.startswith('/usr/local/'):
        if not name.startswith('libtag'):
            raise SystemExit('Nicht inventarisierte lokale Bibliothek: ' + name)
        inventory['libraries'].append({'file': name, 'source': 'taglib', 'version': '2.3.1'})
        continue
    paths = [path, path.removeprefix('/usr') if path.startswith('/usr/lib/') else '/usr' + path]
    owner = None
    for candidate in paths:
        result = subprocess.run(['dpkg-query', '-S', candidate], capture_output=True, text=True)
        if result.returncode == 0:
            owner = result.stdout.split(': /', 1)[0].strip()
            break
    if not owner:
        raise SystemExit('Paketzuordnung fehlt: ' + name)
    source, version = subprocess.check_output(['dpkg-query', '-W', '-f=${source:Package}\t${source:Version}', owner], text=True).split('\t')
    packages[(source, version)] = owner
    notice = Path('/usr/share/doc') / owner.split(':')[0] / 'copyright'
    if not notice.is_file():
        raise SystemExit('Originalhinweis fehlt: ' + owner)
    target = legal / 'system' / owner.replace(':', '_')
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(notice.resolve(), target / 'copyright')
    inventory['libraries'].append({'file': name, 'package': owner, 'source': source, 'version': version,
                                   'sha256': hashlib.sha256((appdir / 'usr/lib/tagx' / name).read_bytes()).hexdigest()})

for (package, version), owner in sorted(packages.items()):
    directory = cache / (package + '-' + version.replace(':', '_'))
    directory.mkdir(parents=True, exist_ok=True)
    stamp = directory / 'complete.json'
    if stamp.exists():
        files = json.loads(stamp.read_text())
        if not files or any(not (directory / name).is_file() or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest for name, digest in files.items()):
            raise SystemExit('Beschädigter Quellen-Cache: ' + package)
    else:
        subprocess.run(['apt-get', 'source', '--download-only', package + '=' + version], cwd=directory, check=True)
        files = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in directory.iterdir() if path.is_file()}
        if not any(name.endswith('.dsc') for name in files):
            raise SystemExit('Quellenbeschreibung fehlt: ' + package)
        stamp.write_text(json.dumps(files, indent=2) + '\n')

taglib = cache / 'taglib-2.3.1.tar.gz'
if not taglib.exists():
    with urlopen('https://taglib.org/releases/taglib-2.3.1.tar.gz', timeout=60) as response:
        taglib.write_bytes(response.read())
if hashlib.sha256(taglib.read_bytes()).hexdigest() != 'a19d90e6fd41d09a0281ec0fe762d51491d7a6ccffc923c4f7868c5e647ca230':
    raise SystemExit('TagLib-Quelltext stimmt nicht mit dem Bau überein')
with tarfile.open(taglib) as package:
    for member in package.getmembers():
        if member.isfile() and Path(member.name).name.startswith(('COPYING', 'LICENSE')):
            destination = legal / 'taglib' / Path(member.name).name
            destination.parent.mkdir(exist_ok=True)
            destination.write_bytes(package.extractfile(member).read())
shutil.copy2('/usr/share/swift/LICENSE.txt', legal / 'Swift-LICENSE.txt')
directory = root / '.build/checkouts/ZIPFoundation'
notices = [path for path in directory.glob('*') if path.is_file() and path.name.upper().startswith(('LICENSE', 'NOTICE', 'COPYING'))]
if not notices:
    raise SystemExit('ZIPFoundation ohne Lizenzhinweis')
(legal / 'ZIPFoundation').mkdir(exist_ok=True)
for path in notices:
    shutil.copy2(path, legal / 'ZIPFoundation' / path.name)

metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--manifest-path', str(root / 'Linux/Cargo.toml'), '--locked', '--filter-platform', 'x86_64-unknown-linux-gnu', '--format-version', '1']))
output = root / 'build/linux'
output.mkdir(parents=True, exist_ok=True)
version = (root / 'VERSION').read_text().strip()
archive = output / f'TagExplosion-{version}-linux-library-sources.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, strict_timestamps=False) as sources:
    for path in sorted(cache.rglob('*')):
        if path.is_file():
            sources.write(path, 'system/' + str(path.relative_to(cache)))
    for package in metadata['packages']:
        if package['source'] is None:
            continue
        if not package.get('license'):
            raise SystemExit('Rust-Abhängigkeit ohne Lizenzangabe: ' + package['name'])
        directory = Path(package['manifest_path']).parent
        prefix = package['name'] + '-' + package['version']
        inventory['rust'].append({'name': package['name'], 'version': package['version'], 'license': package['license']})
        for path in sorted(directory.rglob('*')):
            if path.is_file() and not path.is_symlink():
                relative = str(path.relative_to(directory))
                sources.write(path, 'rust/' + prefix + '/' + relative)
                if path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'COPYRIGHT')):
                    target = legal / 'rust' / prefix / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, target)
    directory = root / '.build/checkouts/ZIPFoundation'
    for path in sorted(directory.rglob('*')):
        if '.git' not in path.parts and path.is_file() and not path.is_symlink():
            sources.write(path, 'swift/ZIPFoundation/' + str(path.relative_to(directory)))
with zipfile.ZipFile(archive) as sources:
    if sources.testzip():
        raise SystemExit('Bibliotheksquellen-ZIP beschädigt')
(legal / 'components.json').write_text(json.dumps(inventory, indent=2) + '\n')
print('LIBRARY NOTICES AND SOURCES OK:', len(inventory['libraries']), 'ELF libraries;', len(inventory['rust']), 'Rust packages')
