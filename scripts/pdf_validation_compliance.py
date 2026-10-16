"""Lizenz-, Quellen- und Bytecodeprüfung der unveränderten veraPDF-CLI."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import zipfile
from validation_compliance import ComplianceError, digest, fetch, files_in

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "licenses/pdf-validation/components.lock.json"
LICENSES = {"MPL-2.0", "Apache-2.0", "BSD-3-Clause", "CDDL-1.1", "MPL-2.0 AND BSD-3-Clause"}


def load_policy():
    policy = json.loads(POLICY.read_text())
    if policy.get("schemaVersion") != 1 or policy.get("engineVersion") != "1.30.3":
        raise ComplianceError("Unbekanntes PDF-Lizenzinventar")
    for component in policy["javaComponents"]:
        if component["license"] not in LICENSES or not component["downloads"].get("source"):
            raise ComplianceError("Ungeklärte PDF-Komponente: " + component["coordinate"])
    return policy


def all_downloads(policy):
    items = list(policy["sourceArtifacts"])
    for component in policy["javaComponents"]:
        items.extend(component["downloads"].values())
    return {item["sha256"]: item for item in items}


def audit_classes(jar, policy, downloads):
    approved = {}
    for component in policy["javaComponents"]:
        if component["coordinate"] == "org.verapdf.apps:cli:1.30.3":
            continue
        with zipfile.ZipFile(downloads[component["downloads"]["binary"]["sha256"]]) as archive:
            for name in archive.namelist():
                if name.endswith(".class"):
                    approved.setdefault(name, set()).add(hashlib.sha256(archive.read(name)).hexdigest())
    own = policy["classAudit"]["ownClasses"]
    with zipfile.ZipFile(downloads[policy["classAudit"]["ownSourceSHA256"]]) as source:
        if not all(item["source"] in source.namelist() for item in own.values()):
            raise ComplianceError("Passende veraPDF-CLI-Quelle fehlt")
    with zipfile.ZipFile(jar) as archive:
        classes = [name for name in archive.namelist() if name.endswith(".class")]
        if len(classes) != policy["classAudit"]["classes"] or len(set(classes)) != len(classes):
            raise ComplianceError("PDF-Klasseninventar stimmt nicht")
        for name in classes:
            checksum = hashlib.sha256(archive.read(name)).hexdigest()
            if checksum not in approved.get(name, set()) and own.get(name, {}).get("sha256") != checksum:
                raise ComplianceError("Nicht zugeordneter PDF-Bytecode: " + name)


def audit_profile_sources(jar, source):
    with zipfile.ZipFile(source) as archive:
        hashes = {hashlib.sha256(archive.read(name)).hexdigest()
                  for name in archive.namelist() if name.endswith(".xml")}
    with zipfile.ZipFile(jar) as archive:
        profiles = [name for name in archive.namelist()
                    if name.startswith("org/verapdf/pdfa/validation/") and name.endswith(".xml")]
        if len(profiles) != 15 or any(hashlib.sha256(archive.read(name)).hexdigest() not in hashes for name in profiles):
            raise ComplianceError("Passende Originalquellen der PDF-Prüfprofile fehlen")


def prepare(bundle, sources, cache):
    policy = load_policy()
    with ThreadPoolExecutor(max_workers=6) as pool:
        downloads = dict(pool.map(lambda item: (item["sha256"], fetch(item, cache)), all_downloads(policy).values()))
    bundle.mkdir()
    sources.mkdir()
    (sources / "artifacts").mkdir()
    shutil.copy2(downloads[policy["jar"]["sha256"]], bundle / "validator.jar")
    audit_classes(bundle / "validator.jar", policy, downloads)
    for component in policy["javaComponents"]:
        source = component["downloads"]["source"]
        shutil.copy2(downloads[source["sha256"]], sources / "artifacts" / source["file"])
        with zipfile.ZipFile(downloads[component["downloads"]["binary"]["sha256"]]) as archive:
            for name, checksum in component["noticeEntries"].items():
                data = archive.read(name)
                if hashlib.sha256(data).hexdigest() != checksum:
                    raise ComplianceError("Veränderte PDF-Original-Notice")
                destination = bundle / "legal/java" / component["coordinate"].replace(":", "_") / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
    for item in policy["sourceArtifacts"]:
        shutil.copy2(downloads[item["sha256"]], sources / "artifacts" / item["name"])
    for name, checksum in policy["licenseFiles"].items():
        origin = POLICY.parent / name
        if digest(origin) != checksum:
            raise ComplianceError("Veränderter PDF-Lizenztext: " + name)
        destination = bundle / "legal/licenses" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(origin, destination)
    shutil.copy2(POLICY, bundle / "legal/components.lock.json")
    shutil.copy2(POLICY, sources / "components.lock.json")
    shutil.copytree(bundle / "legal", sources / "legal")
    (bundle / "manifest.json").write_text(json.dumps({"schemaVersion": 1, "engineVersion": "1.30.3",
        "packaging": "verapdf-unmodified-cli-v1", "policySHA256": digest(POLICY)}, indent=2) + "\n")
    (bundle / "legal/README.txt").write_text(
        "Unveränderte veraPDF CLI 1.30.3. Eigene Integration: MIT. Fremdcode behält seine Lizenzen.\n"
        "Für veraPDF, Saxon und Rhino wird MPL-2.0 gewählt; ältere JAXB-Teile nutzen CDDL-1.1.\n"
        "Originale zusätzliche BSD-/Apache-Lizenzen und sämtliche Quellkopfhinweise bleiben erhalten.\n"
        "XMP: MPL für veraPDF-Anteile und BSD für die Adobe-Basis; auch der ursprüngliche Hersteller-Lizenztext bleibt erhalten.\n"
        "Das passende PDF-Sources-Paket muss gemeinsam mit diesem Binärstand bereitgestellt werden.\n")
    (sources / "sources-manifest.json").write_text(json.dumps({"policySHA256": digest(POLICY),
        "files": files_in(sources)}, indent=2) + "\n")
    (bundle / "compliance.json").write_text(json.dumps({"policySHA256": digest(POLICY),
        "sourceManifestSHA256": digest(sources / "sources-manifest.json"), "files": files_in(bundle)}, indent=2) + "\n")
    verify(bundle, sources)


def verify(bundle, sources):
    policy = load_policy()
    compliance = json.loads((bundle / "compliance.json").read_text())
    source_manifest = json.loads((sources / "sources-manifest.json").read_text())
    manifest = json.loads((bundle / "manifest.json").read_text())
    if any(data.get("policySHA256") != digest(POLICY) for data in [compliance, source_manifest, manifest]):
        raise ComplianceError("PDF-Inventar passt nicht zum geprüften Stand")
    if manifest.get("engineVersion") != "1.30.3" or manifest.get("packaging") != "verapdf-unmodified-cli-v1":
        raise ComplianceError("Ungeprüfte PDF-Verpackung")
    if digest(bundle / "validator.jar") != policy["jar"]["sha256"]:
        raise ComplianceError("veraPDF-JAR verändert")
    binary_files = files_in(bundle)
    binary_files.pop("compliance.json", None)
    source_files = files_in(sources)
    source_files.pop("sources-manifest.json", None)
    if any("symlink" in value for value in [*binary_files.values(), *source_files.values()]):
        raise ComplianceError("PDF-Lizenz-/Quellenpaket enthält Dateiverweise statt Inhalt")
    if binary_files != compliance.get("files") or source_files != source_manifest.get("files"):
        raise ComplianceError("PDF-Dateien oder Quellen fehlen oder wurden verändert")
    if digest(sources / "sources-manifest.json") != compliance.get("sourceManifestSHA256"):
        raise ComplianceError("PDF-Quellen passen nicht zum Binärpaket")
    artifacts = {item["name"]: item["sha256"] for item in policy["sourceArtifacts"]}
    for component in policy["javaComponents"]:
        source = component["downloads"]["source"]
        artifacts[source["file"]] = source["sha256"]
        for name, checksum in component["noticeEntries"].items():
            if digest(bundle / "legal/java" / component["coordinate"].replace(":", "_") / name) != checksum:
                raise ComplianceError("PDF-Original-Notice fehlt")
    for name, checksum in artifacts.items():
        if digest(sources / "artifacts" / name) != checksum:
            raise ComplianceError("PDF-Originalquelle fehlt: " + name)
    profiles = next(item for item in policy["sourceArtifacts"] if item["name"].startswith("veraPDF-profiles-"))
    audit_profile_sources(bundle / "validator.jar", sources / "artifacts" / profiles["name"])
    for name, checksum in policy["licenseFiles"].items():
        if digest(bundle / "legal/licenses" / name) != checksum:
            raise ComplianceError("PDF-Lizenztext fehlt: " + name)
    if digest(bundle / "legal/components.lock.json") != digest(POLICY) or digest(sources / "components.lock.json") != digest(POLICY):
        raise ComplianceError("PDF-Komponentenliste fehlt")
    return {"status": "passed", "javaArtifacts": len(policy["javaComponents"]),
            "classes": policy["classAudit"]["classes"], "sourceArtifacts": len(artifacts)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--sources", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.bundle.resolve(), args.sources.resolve())))
    except (ComplianceError, OSError, ValueError, KeyError) as error:
        parser.exit(1, "PDF-Lizenz-/Quellenprüfung fehlgeschlagen: " + str(error) + "\n")
