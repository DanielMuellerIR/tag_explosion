#!/usr/bin/env python3
"""Debug-Host im echten AppImage-Mount für den lokalen Updatewechsel packen."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
tool = root / '.build/appimage-tool/appimagetool-1.9.1-x86_64.AppImage'
assert hashlib.sha256(tool.read_bytes()).hexdigest() == 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='tagx-update-probe-') as temporary:
    appdir = Path(temporary) / 'TagExplosion.AppDir'
    shutil.copytree(root / 'Linux/target/release/bundle/appimage/TagExplosion.AppDir', appdir, symlinks=True)
    shutil.copy2(root / 'Linux/target/debug/tag-explosion-linux', appdir / 'usr/bin/tag-explosion-linux')
    subprocess.run([str(tool), '--appimage-extract-and-run', '--runtime-file', str(root / '.build/appimage-tool/runtime-x86_64'), '--mksquashfs-opt', '-processors', '--mksquashfs-opt', '3', str(appdir), str(args.output.resolve())], check=True, env=dict(os.environ, ARCH='x86_64', NO_STRIP='1'))
