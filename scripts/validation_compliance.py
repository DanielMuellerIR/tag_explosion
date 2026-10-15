"""Lizenz-/Quellcodepaket für die exakt geprüfte KoSIT-Distribution."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "licenses/validation/components.lock.json"
ALLOWED_LICENSES = {"Apache-2.0", "MIT", "BSD-3-Clause", "MPL-2.0"}


class ComplianceError(ValueError):
    pass


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def files_in(directory):
    result = {}
    for base, directories, files in os.walk(directory, followlinks=False):
        for name in list(directories):
            path = Path(base) / name
            if path.is_symlink():
                files.append(name)
                directories.remove(name)
        for name in sorted(files):
            path = Path(base) / name
            relative = path.relative_to(directory).as_posix()
            result[relative] = {"symlink": os.readlink(path)} if path.is_symlink() else {"sha256": digest(path)}
    return dict(sorted(result.items()))


def tree_digest(directory):
    return hashlib.sha256(json.dumps(files_in(directory), sort_keys=True).encode()).hexdigest()


def load_policy(path=POLICY):
    policy = json.loads(Path(path).read_text(encoding="utf-8"))
    if policy.get("schemaVersion") != 1:
        raise ComplianceError("Unbekanntes Lizenzmanifest")
    coordinates = []
    for component in policy["javaComponents"]:
        coordinates.append(component["coordinate"])
        if component.get("license") not in ALLOWED_LICENSES or not component.get("downloads", {}).get("source"):
            raise ComplianceError("Ungeklärte Lizenz/Quelle: " + component["coordinate"])
    if len(set(coordinates)) != len(coordinates):
        raise ComplianceError("Doppeltes Java-Artefakt")
    return policy


def fetch(artifact, cache):
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / artifact["sha256"]
    if destination.exists():
        if digest(destination) != artifact["sha256"]:
            raise ComplianceError("Beschädigter Download-Cache: " + destination.name)
        return destination
    request = urllib.request.Request(artifact["url"], headers={"User-Agent": "TagExplosion-validation-package"})
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as temporary:
        staging = Path(temporary.name)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    temporary.write(chunk)
            temporary.flush()
            if digest(staging) != artifact["sha256"]:
                raise ComplianceError("Download-Prüfsumme stimmt nicht: " + artifact["url"])
            staging.replace(destination)
        finally:
            if staging.exists():
                staging.unlink()
    return destination


def notice_path(component, entry):
    return Path("legal/java") / component["coordinate"].replace(":", "_") / entry


def prepare(bundle, sources, cache):
    policy = load_policy()
    downloads = []
    for component in policy["javaComponents"]:
        downloads.extend(component["downloads"].values())
    downloads.extend(policy["sourceArtifacts"])
    unique = {item["sha256"]: item for item in downloads}
    with ThreadPoolExecutor(max_workers=4) as pool:
        fetched = list(pool.map(lambda item: (item["sha256"], fetch(item, cache)), unique.values()))
    archives = dict(fetched)
    sources.mkdir()
    (sources / "artifacts").mkdir()
    for component in policy["javaComponents"]:
        source = component["downloads"]["source"]
        shutil.copy2(archives[source["sha256"]], sources / "artifacts" / source["file"])
        with zipfile.ZipFile(archives[component["downloads"]["binary"]["sha256"]]) as archive:
            for entry, checksum in component["noticeEntries"].items():
                content = archive.read(entry)
                if hashlib.sha256(content).hexdigest() != checksum:
                    raise ComplianceError("Veränderte Original-Notice: " + entry)
                destination = bundle / notice_path(component, entry)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(content)
    for source in policy["sourceArtifacts"]:
        shutil.copy2(archives[source["sha256"]], sources / "artifacts" / source["name"])
    for name, checksum in policy["licenseFiles"].items():
        origin = ROOT / "licenses/validation" / name
        if digest(origin) != checksum:
            raise ComplianceError("Veränderter Lizenztext: " + name)
        destination = bundle / "legal/licenses" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(origin, destination)
    shutil.copy2(POLICY, bundle / "legal/components.lock.json")
    shutil.copy2(POLICY, sources / "components.lock.json")
    (bundle / "legal/README.txt").write_text(
        "Tag Explosion: eigener Code unter MIT. Die eigenständige Java-Laufzeit, "
        "Bibliotheken und Regelpakete behalten ihre jeweiligen Lizenzen.\n"
        "Lizenztexte: licenses/; Original-Notices: java/; Runtime: ../runtime/Contents/Home/legal/.\n"
        "Das passende Sources-Paket muss gemeinsam mit diesem Binärstand angeboten werden. "
        "Es enthält insbesondere die MPL-/EUPL-/GPL-Quellen und bevorzugten Regelquellen.\n"
        "Verpackungsänderungen: native Jansi-Konsolenbibliotheken und die ungenutzte "
        "KoSIT-Daemon-Weboberfläche entfernt. Java-Klassen und Prüfregeleinträge unverändert.\n"
        "Schemata: originale OASIS-/UNCEFACT-Hinweise in den unveränderten XSD-Dateien.\n",
        encoding="utf-8",
    )
    (sources / "README.txt").write_text(
        "Passende Quellen zur privaten KoSIT-/Temurin-Distribution von Tag Explosion.\n"
        "artifacts/: unveränderte, per SHA-256 gepinnte Quellarchive; components.lock.json: "
        "Versionen, Lizenzen, Herkunft und Prüfsummen. OpenJDK enthält die Build-Skripte; "
        "die Laufzeit selbst wird unverändert von Eclipse Temurin übernommen.\n"
        "Die XML-Schemata stehen bereits in bevorzugter Quellform unter configuration/ "
        "im Binärpaket. Regelquellen und SchXslt liegen zusätzlich in artifacts/.\n"
        "Bei öffentlicher Distribution dieses Paket neben demselben Binärstand bereitstellen; "
        "ein Verweis ausschließlich auf fremde Downloadserver ersetzt dieses Paket nicht.\n",
        encoding="utf-8",
    )
    audit_classes(bundle / "validator.jar", policy, archives)
    source_manifest = {"policySHA256": digest(POLICY), "files": files_in(sources)}
    (sources / "sources-manifest.json").write_text(json.dumps(source_manifest, indent=2) + "\n", encoding="utf-8")
    compliance = {
        "schemaVersion": 1, "policySHA256": digest(POLICY), "packaging": policy["packaging"],
        "sourceManifestSHA256": digest(sources / "sources-manifest.json"), "files": files_in(bundle),
    }
    (bundle / "compliance.json").write_text(json.dumps(compliance, indent=2) + "\n", encoding="utf-8")
    verify(bundle, sources)


def audit_classes(jar, policy, archives):
    approved = {}
    for component in policy["javaComponents"]:
        with zipfile.ZipFile(archives[component["downloads"]["binary"]["sha256"]]) as archive:
            for entry in archive.namelist():
                if entry.endswith(".class"):
                    approved.setdefault(entry, set()).add(hashlib.sha256(archive.read(entry)).hexdigest())
    with zipfile.ZipFile(jar) as archive:
        classes = [entry for entry in archive.namelist() if entry.endswith(".class")]
        if len(classes) != policy["classAudit"]["classes"]:
            raise ComplianceError("Klasseninventar stimmt nicht")
        for entry in classes:
            if hashlib.sha256(archive.read(entry)).hexdigest() not in approved.get(entry, set()):
                raise ComplianceError("Nicht freigegebener Java-Code: " + entry)
        if any(entry.startswith("ui/") for entry in archive.namelist()):
            raise ComplianceError("Nicht benötigte Daemon-Weboberfläche ist noch enthalten")


def verify(bundle, sources):
    policy = load_policy()
    try:
        compliance = json.loads((bundle / "compliance.json").read_text())
        source_manifest = json.loads((sources / "sources-manifest.json").read_text())
        manifest = json.loads((bundle / "manifest.json").read_text())
    except (OSError, ValueError) as error:
        raise ComplianceError("Lizenz-/Quellcodepaket fehlt oder ist unlesbar") from error
    if compliance.get("policySHA256") != digest(POLICY) or source_manifest.get("policySHA256") != digest(POLICY):
        raise ComplianceError("Lizenzinventar passt nicht zum geprüften Stand")
    if compliance.get("packaging") != policy["packaging"] or manifest.get("packaging") != policy["packaging"]:
        raise ComplianceError("Ungeprüfte Verpackung")
    if digest(bundle / "validator.jar") != policy["packagedJarSHA256"]:
        raise ComplianceError("KoSIT-JAR weicht vom freigegebenen Inventar ab")
    if tree_digest(bundle / "configuration") != policy["configurationTreeSHA256"]:
        raise ComplianceError("Regelpaket weicht vom freigegebenen Inventar ab")
    if tree_digest(bundle / "runtime") != policy["runtimeTreeSHA256"][manifest["architecture"]]:
        raise ComplianceError("Runtime weicht vom geprüften Herstellerpaket ab")
    expected_files = files_in(bundle)
    expected_files.pop("compliance.json", None)
    if expected_files != compliance.get("files"):
        raise ComplianceError("Binär-/Lizenzdateien fehlen oder wurden verändert")
    source_files = files_in(sources)
    source_files.pop("sources-manifest.json", None)
    if any("symlink" in item for item in source_files.values()) or any(
        "symlink" in item for item in files_in(bundle / "legal").values()
    ):
        raise ComplianceError("Lizenz-/Quellenpaket darf keine externen Dateiverweise statt Inhalt enthalten")
    if source_files != source_manifest.get("files") or digest(sources / "sources-manifest.json") != compliance.get("sourceManifestSHA256"):
        raise ComplianceError("Quellcodepaket passt nicht zum Binärpaket")
    artifacts = {item["name"]: item["sha256"] for item in policy["sourceArtifacts"]}
    for component in policy["javaComponents"]:
        source = component["downloads"]["source"]
        artifacts[source["file"]] = source["sha256"]
        for entry, checksum in component["noticeEntries"].items():
            if digest(bundle / notice_path(component, entry)) != checksum:
                raise ComplianceError("Original-Notice fehlt: " + component["coordinate"])
    for name, checksum in artifacts.items():
        if digest(sources / "artifacts" / name) != checksum:
            raise ComplianceError("Passende Quelle fehlt: " + name)
    for name, checksum in policy["licenseFiles"].items():
        if digest(bundle / "legal/licenses" / name) != checksum:
            raise ComplianceError("Lizenztext fehlt: " + name)
    if digest(bundle / "legal/components.lock.json") != digest(POLICY) or digest(sources / "components.lock.json") != digest(POLICY):
        raise ComplianceError("Komponentenliste fehlt oder stimmt nicht")
    return {"javaArtifacts": len(policy["javaComponents"]), "classes": policy["classAudit"]["classes"],
            "sourceArchives": len(artifacts), "status": "passed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--sources", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.bundle.resolve(), args.sources.resolve())))
    except (ComplianceError, OSError, KeyError) as error:
        parser.exit(1, "Lizenz-/Quellcodeprüfung fehlgeschlagen: " + str(error) + "\n")


if __name__ == "__main__":
    main()
