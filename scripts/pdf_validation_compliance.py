"""Lizenz-, Quellen- und Bytecodeprüfung der unveränderten veraPDF-CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile
from validation_compliance_support import (
    ComplianceError, digest, fetch, fetch_all, files_in,
    prepare_legal_files, verify_inventories, verify_legal_files, write_inventories,
)

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "licenses/pdf-validation/components.lock.json"
ENGINE_VERSION = "1.30.3"
PACKAGING = "verapdf-unmodified-cli-v1"
LICENSES = {"MPL-2.0", "Apache-2.0", "BSD-3-Clause", "CDDL-1.1", "MPL-2.0 AND BSD-3-Clause"}


def load_policy():
    policy = json.loads(POLICY.read_text())
    if policy.get("schemaVersion") != 1 or policy.get("engineVersion") != ENGINE_VERSION:
        raise ComplianceError("Unbekanntes PDF-Lizenzinventar")
    for component in policy["javaComponents"]:
        if component["license"] not in LICENSES or not component["downloads"].get("source"):
            raise ComplianceError("Ungeklärte PDF-Komponente: " + component["coordinate"])
    return policy


def audit_classes(jar, policy, downloads):
    approved = {}
    for component in policy["javaComponents"]:
        if component["coordinate"] == f"org.verapdf.apps:cli:{ENGINE_VERSION}":
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
    artifacts = list(policy["sourceArtifacts"])
    for component in policy["javaComponents"]:
        artifacts.extend(component["downloads"].values())
    downloads = fetch_all(artifacts, cache, workers=6)
    bundle.mkdir()
    sources.mkdir()
    (sources / "artifacts").mkdir()
    shutil.copy2(downloads[policy["jar"]["sha256"]], bundle / "validator.jar")
    audit_classes(bundle / "validator.jar", policy, downloads)
    prepare_legal_files(bundle, sources, policy, POLICY, downloads)
    shutil.copytree(bundle / "legal", sources / "legal")
    policy_sha = digest(POLICY)
    (bundle / "manifest.json").write_text(json.dumps({"schemaVersion": 1, "engineVersion": ENGINE_VERSION,
        "packaging": PACKAGING, "policySHA256": policy_sha}, indent=2) + "\n")
    (bundle / "legal/README.txt").write_text(
        f"Unveränderte veraPDF CLI {ENGINE_VERSION}. Eigene Integration: MIT. Fremdcode behält seine Lizenzen.\n"
        "Für veraPDF, Saxon und Rhino wird MPL-2.0 gewählt; ältere JAXB-Teile nutzen CDDL-1.1.\n"
        "Originale zusätzliche BSD-/Apache-Lizenzen und sämtliche Quellkopfhinweise bleiben erhalten.\n"
        "XMP: MPL für veraPDF-Anteile und BSD für die Adobe-Basis; auch der ursprüngliche Hersteller-Lizenztext bleibt erhalten.\n"
        "Das passende PDF-Sources-Paket muss gemeinsam mit diesem Binärstand bereitgestellt werden.\n")
    write_inventories(bundle, sources, {"policySHA256": policy_sha})
    verify(bundle, sources)


def verify(bundle, sources):
    policy = load_policy()
    compliance = json.loads((bundle / "compliance.json").read_text())
    source_manifest = json.loads((sources / "sources-manifest.json").read_text())
    manifest = json.loads((bundle / "manifest.json").read_text())
    policy_sha = digest(POLICY)
    if any(data.get("policySHA256") != policy_sha for data in [compliance, source_manifest, manifest]):
        raise ComplianceError("PDF-Inventar passt nicht zum geprüften Stand")
    if manifest.get("engineVersion") != ENGINE_VERSION or manifest.get("packaging") != PACKAGING:
        raise ComplianceError("Ungeprüfte PDF-Verpackung")
    if digest(bundle / "validator.jar") != policy["jar"]["sha256"]:
        raise ComplianceError("veraPDF-JAR verändert")
    verify_inventories(bundle, sources, compliance, source_manifest)
    source_count = verify_legal_files(bundle, sources, policy, policy_sha)
    profiles = next(item for item in policy["sourceArtifacts"] if item["name"].startswith("veraPDF-profiles-"))
    audit_profile_sources(bundle / "validator.jar", sources / "artifacts" / profiles["name"])
    return {"status": "passed", "javaArtifacts": len(policy["javaComponents"]),
            "classes": policy["classAudit"]["classes"], "sourceArtifacts": source_count}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--sources", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.bundle.resolve(), args.sources.resolve())))
    except (ComplianceError, OSError, ValueError, KeyError) as error:
        parser.exit(1, "PDF-Lizenz-/Quellenprüfung fehlgeschlagen: " + str(error) + "\n")
