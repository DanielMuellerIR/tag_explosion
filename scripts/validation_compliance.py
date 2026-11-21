"""Lizenz-/Quellcodepaket für die exakt geprüfte KoSIT-Distribution."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

from validation_compliance_support import (
    ComplianceError, digest, fetch, fetch_all, files_in, notice_path,
    prepare_legal_files, tree_digest, verify_inventories, verify_legal_files, write_inventories,
)

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "licenses/validation/components.lock.json"
ALLOWED_LICENSES = {"Apache-2.0", "MIT", "BSD-3-Clause", "MPL-2.0"}


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


def prepare(bundle, sources, cache):
    policy = load_policy()
    downloads = []
    for component in policy["javaComponents"]:
        downloads.extend(component["downloads"].values())
    downloads.extend(policy["sourceArtifacts"])
    archives = fetch_all(downloads, cache, workers=4)
    sources.mkdir()
    (sources / "artifacts").mkdir()
    prepare_legal_files(bundle, sources, policy, POLICY, archives)
    (bundle / "legal/README.txt").write_text(
        "Tag Explosion: eigener Code unter MIT. Die eigenständige Java-Laufzeit, "
        "Bibliotheken und Regelpakete behalten ihre jeweiligen Lizenzen.\n"
        "Lizenztexte: licenses/; Original-Notices: java/; Runtime: ../runtime/Contents/Home/legal/ (macOS) oder ../runtime/legal/ (Linux).\n"
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
    write_inventories(bundle, sources, {
        "schemaVersion": 1, "policySHA256": digest(POLICY), "packaging": policy["packaging"],
    })
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
    policy_sha = digest(POLICY)
    if compliance.get("policySHA256") != policy_sha or source_manifest.get("policySHA256") != policy_sha:
        raise ComplianceError("Lizenzinventar passt nicht zum geprüften Stand")
    if compliance.get("packaging") != policy["packaging"] or manifest.get("packaging") != policy["packaging"]:
        raise ComplianceError("Ungeprüfte Verpackung")
    if digest(bundle / "validator.jar") != policy["packagedJarSHA256"]:
        raise ComplianceError("KoSIT-JAR weicht vom freigegebenen Inventar ab")
    if tree_digest(bundle / "configuration") != policy["configurationTreeSHA256"]:
        raise ComplianceError("Regelpaket weicht vom freigegebenen Inventar ab")
    if tree_digest(bundle / "runtime") != policy["runtimeTreeSHA256"][(manifest.get("operatingSystem", "macos") + "-" + manifest["architecture"])]:
        raise ComplianceError("Runtime weicht vom geprüften Herstellerpaket ab")
    verify_inventories(bundle, sources, compliance, source_manifest, allow_binary_symlinks=True)
    source_count = verify_legal_files(bundle, sources, policy, policy_sha)
    return {"javaArtifacts": len(policy["javaComponents"]), "classes": policy["classAudit"]["classes"],
            "sourceArchives": source_count, "status": "passed"}


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
