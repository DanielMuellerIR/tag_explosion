#!/usr/bin/env python3
"""Prüft die tatsächlich verteilten Quellen-ZIPs gegen App oder DMG."""
import argparse
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import unicodedata
import zipfile

import validation_compliance as core
import pdf_validation_compliance as pdf


def unpack_sources(archive, destination):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > 10_000 or sum(item.file_size for item in entries) > 512 * 1024 * 1024:
            raise core.ComplianceError("Quellen-ZIP überschreitet die Verpackungsgrenze")
        names = set()
        for item in entries:
            path = PurePosixPath(item.filename)
            normalized = unicodedata.normalize("NFC", item.filename.rstrip("/")).casefold()
            mode = item.external_attr >> 16
            if (path.is_absolute() or ".." in path.parts or "\\" in item.filename
                    or not path.parts or "__MACOSX" in path.parts
                    or normalized in names or stat.S_ISLNK(mode)
                    or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise core.ComplianceError("Unsicherer oder doppelter Quellen-ZIP-Eintrag")
            names.add(normalized)
        source.extractall(destination)
    roots = list(destination.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise core.ComplianceError("Quellen-ZIP benötigt genau ein Stammverzeichnis")
    return roots[0]


def verify_app(app, artifacts, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version):
        raise core.ComplianceError("Ungültige Releaseversion")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleIdentifier") != "io.github.danielmuellerir.tagexplosion"
            or info.get("CFBundleShortVersionString") != version
            or info.get("CFBundleVersion") != version):
        raise core.ComplianceError("App und Releaseversion passen nicht zusammen")
    for source, name in [(core.ROOT / "LICENSE", "LICENSE"),
                         (core.ROOT / "THIRD-PARTY-NOTICES.md", "Third-Party-Licenses.md")]:
        target = app / "Contents/Resources" / name
        if not target.is_file() or target.is_symlink() or core.digest(target) != core.digest(source):
            raise core.ComplianceError("Vollständiger App-Lizenzhinweis fehlt oder wurde verändert: " + name)
    result = {"version": version, "status": "passed", "sources": {}}
    with tempfile.TemporaryDirectory(prefix="tagx-release-sources-") as temporary:
        for label, verifier, bundle, suffix in [
            ("xml", core, "XRechnungValidator", "validation-sources"),
            ("pdf", pdf, "PDFValidator", "pdf-validation-sources"),
        ]:
            archive = artifacts / f"TagExplosion-{version}-{suffix}.zip"
            if not archive.is_file() or archive.is_symlink():
                raise core.ComplianceError("Verpflichtendes Quellen-ZIP fehlt: " + archive.name)
            destination = Path(temporary) / label
            destination.mkdir()
            sources = unpack_sources(archive, destination)
            verification = verifier.verify(app / "Contents/Resources" / bundle, sources)
            result["sources"][label] = {"file": archive.name, "sha256": core.digest(archive), **verification}
    return result


def verify_dmg(image, artifacts, version):
    subprocess.run(["xcrun", "stapler", "validate", str(image)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(image)], check=True)
    with tempfile.TemporaryDirectory(prefix="tagx-release-mount-") as temporary:
        mount = Path(temporary).resolve() / "volume"
        mount.mkdir()
        device = None
        try:
            completion = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist",
                "-mountpoint", str(mount), str(image)], check=True, capture_output=True)
            entities = plistlib.loads(completion.stdout).get("system-entities", [])
            device = next((item["dev-entry"] for item in entities
                           if item.get("mount-point") and Path(item["mount-point"]).resolve() == mount), None)
            if not device:
                raise core.ComplianceError("Eigenes DMG-Gerät nicht ermittelt")
            apps = list(mount.glob("*.app"))
            if len(apps) != 1 or apps[0].is_symlink():
                raise core.ComplianceError("DMG benötigt genau ein App-Bundle")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(apps[0])], check=True)
            subprocess.run(["xcrun", "stapler", "validate", str(apps[0])], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["spctl", "--assess", "--type", "execute", str(apps[0])], check=True)
            result = verify_app(apps[0], artifacts, version)
            result["dmg"] = {"file": image.name, "sha256": core.digest(image)}
            return result
        finally:
            if device:
                subprocess.run(["hdiutil", "detach", device, "-quiet"], check=True)
            elif mount.is_mount():
                # Der einzigartige Pfad gehört diesem Attach-Versuch; niemals fremde Volumes aushängen.
                subprocess.run(["hdiutil", "detach", str(mount), "-quiet"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path, help="App-Bundle oder notarisiertes DMG")
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        verifier = verify_dmg if args.target.suffix.lower() == ".dmg" else verify_app
        print(json.dumps(verifier(args.target.resolve(), args.artifacts.resolve(), args.version)))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, "Auslieferungsprüfung fehlgeschlagen: " + str(error) + "\n")


if __name__ == "__main__":
    main()
