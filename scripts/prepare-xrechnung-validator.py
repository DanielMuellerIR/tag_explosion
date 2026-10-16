#!/usr/bin/env python3
"""Gepinntes KoSIT-Prüfpaket mit privater macOS-Java-Laufzeit vorbereiten."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from validation_compliance import prepare as prepare_compliance
from validation_facturx import prepare as prepare_facturx


RELEASE = "https://github.com/itplr-kosit"
JAVA_RELEASE = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1"
ARTIFACTS = {
    "validator.jar": (
        RELEASE + "/validator/releases/download/v1.6.3/validator-1.6.3-standalone.jar",
        "799e64befca97d4080e03608c80b85dd5a5ecc5f4ae4f35d1116ec2855b9a7c9",
    ),
    "configuration.zip": (
        RELEASE + "/validator-configuration-xrechnung/releases/download/v2026-08-31/"
        "xrechnung-3.0.2-validator-configuration-2026-08-31.zip",
        "2530cd107c414511c5d0462ec10f886910395abfca820db82e83d70bf01221a8",
    ),
}
RUNTIMES = {
    "arm64": ("aarch64", "dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84"),
    "x86_64": ("x64", "6717ec641fd9ce0bb209ca083ee23b42202ac68cb6fcc5753496e0e4a0f41989"),
}


def download(url, sha256, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "TagExplosion-KoSIT-prototype"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != sha256:
        raise ValueError("SHA-256 stimmt nicht: " + destination.name)


def package_validator(source, destination):
    # Die KoSIT-Distribution enthält unsignierte Jansi-Konsolenbibliotheken,
    # darunter 32-Bit-Code. Apple lehnt diese auch innerhalb eines JARs ab.
    # Für maschinenlesbare CLI-Läufe sind sie entbehrlich; Klassen, Regeln
    # und Lizenzressourcen bleiben bytegleich erhalten.
    removed = []
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "w") as packaged:
        for entry in original.infolist():
            if entry.filename.startswith("org/fusesource/jansi/internal/native/") and not entry.is_dir():
                removed.append(entry.filename)
            elif entry.filename.startswith("ui/"):
                # Die native App verwendet die Daemon-Weboberfläche nicht.
                # Deren ungenutzte Frontend-Abhängigkeiten werden nicht gebündelt.
                continue
            else:
                packaged.writestr(entry, original.read(entry))
    if len(removed) != 15:
        raise ValueError("Unerwartete Jansi-Ressourcen im gepinnten KoSIT-JAR")
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=RUNTIMES, default=platform.machine())
    parser.add_argument("--output", type=Path)
    parser.add_argument("--sources-output", type=Path, help="Passendes Quellenpaket; Standard: <output>-sources")
    args = parser.parse_args()
    if platform.system() != "Darwin" or args.arch not in RUNTIMES:
        parser.error("Der Paket-Prototyp unterstützt macOS arm64 und x86_64.")
    root = Path(__file__).resolve().parent.parent
    destination = (args.output or root / ".build" / ("xrechnung-validator-" + args.arch)).resolve()
    source_destination = (args.sources_output or Path(str(destination) + "-sources")).resolve()
    if destination.exists():
        parser.error("Ziel existiert bereits; vorhandene Prüfpakete werden nicht überschrieben.")
    if source_destination.exists() or source_destination == destination:
        parser.error("Quellenziel existiert bereits oder entspricht dem Binärziel.")
    if source_destination in destination.parents or destination in source_destination.parents:
        parser.error("Binär- und Quellenziel dürfen nicht ineinander liegen.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_destination.parent.mkdir(parents=True, exist_ok=True)
    java_arch, java_hash = RUNTIMES[args.arch]
    artifacts = dict(ARTIFACTS)
    artifacts["runtime.tar.gz"] = (
        JAVA_RELEASE + "/OpenJDK21U-jre_" + java_arch + "_mac_hotspot_21.0.12.1_1.tar.gz", java_hash
    )
    # Erst nach vollständigem Download und Prüfung veröffentlichen. Ein
    # abgebrochener Lauf hinterlässt kein scheinbar fertiges Prüfpaket.
    with tempfile.TemporaryDirectory(prefix="kosit-prepare-", dir=destination.parent) as temporary:
        work = Path(temporary)
        package = work / "package"
        package.mkdir()
        for name, (url, digest) in artifacts.items():
            print("Lade und prüfe " + name, flush=True)
            download(url, digest, work / name)
        removed = package_validator(work / "validator.jar", package / "validator.jar")
        with zipfile.ZipFile(work / "configuration.zip") as archive:
            archive.extractall(package / "configuration")
        prepare_facturx(package / "configuration", root / ".validation-build/downloads")
        runtime = work / "runtime"
        runtime.mkdir()
        subprocess.run(["/usr/bin/tar", "-xzf", str(work / "runtime.tar.gz"), "-C", str(runtime)], check=True)
        java_bundles = list(runtime.glob("*/Contents"))
        if len(java_bundles) != 1:
            raise ValueError("Unerwartete Struktur des Java-Archivs")
        shutil.move(str(java_bundles[0].parent), package / "runtime")
        manifest = {
            "validatorVersion": "1.6.3",
            "configurationRelease": "2026-08-31",
            "xrechnungVersion": "3.0.2",
            "facturXVersion": "1.09.2",
            "zugferdVersion": "2.5.2",
            "javaVersion": "Temurin 21.0.12.1+1",
            "architecture": args.arch,
            "packaging": "omit-jansi-native-and-daemon-ui-v2",
            "omittedNativeConsoleLibraries": removed,
            "packagedJarSHA256": hashlib.sha256((package / "validator.jar").read_bytes()).hexdigest(),
            "artifacts": {name: {"url": url, "sha256": sha} for name, (url, sha) in artifacts.items()},
            "javaSource": JAVA_RELEASE + "/OpenJDK21U-jdk-sources_21.0.12.1_1.tar.gz",
        }
        (package / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        # Die vollständige Runtime einschließlich legal/ bleibt unverändert.
        # Die native Produktintegration und deren Abnahme folgen getrennt.
        (package / "PROTOTYPE.txt").write_text(
            "Lokaler technischer Prototyp, keine freigegebene Distribution.\n"
            "Öffentliche Binärdistribution nur zusammen mit dem passenden Quellenpaket "
            "und nach Prüfung der endgültigen App.\n",
            encoding="utf-8",
        )
        source_package = work / "sources"
        prepare_compliance(package, source_package, root / ".build/validation-downloads")
        os.rename(source_package, source_destination)
        try:
            os.rename(package, destination)
        except OSError:
            # Nur das soeben selbst veröffentlichte Quellenpaket zurücknehmen.
            os.rename(source_destination, source_package)
            raise
    print(destination)
    print("Sources: " + str(source_destination))


if __name__ == "__main__":
    main()
