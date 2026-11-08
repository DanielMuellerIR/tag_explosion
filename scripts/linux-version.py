#!/usr/bin/env python3
"""VERSION in die benötigten Rust-/Tauri-Manifeste übertragen."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
version = (root / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
    raise SystemExit('Ungültige VERSION')
manifest = root / 'Linux/Cargo.toml'
content = re.sub(r'^version = "[^"]+"', 'version = "' + version + '"', manifest.read_text(), count=1, flags=re.M)
if manifest.read_text() != content:
    manifest.write_text(content)
config = root / 'Linux/tauri.conf.json'
value = json.loads(config.read_text())
value['version'] = version
value.setdefault('plugins', {}).setdefault('updater', {})['pubkey'] = (root / 'Linux/updates.pub').read_text().strip()
installer = root / 'Linux/install.py'
installer_content = re.sub(r"^PUBLIC_KEY = '[^']*'", 'PUBLIC_KEY = ' + repr(value['plugins']['updater']['pubkey']), installer.read_text(), count=1, flags=re.M)
if installer.read_text() != installer_content:
    installer.write_text(installer_content)
content = json.dumps(value, ensure_ascii=False, indent=2) + '\n'
if config.read_text() != content:
    config.write_text(content)
lock = root / 'Linux/Cargo.lock'
if lock.exists():
    content = re.sub(r'(name = "tag-explosion-linux"\nversion = ")[^"]+', r'\g<1>' + version, lock.read_text())
    if content != lock.read_text():
        lock.write_text(content)
