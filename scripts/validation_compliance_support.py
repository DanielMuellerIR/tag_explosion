"""Gemeinsame Datei-, Hash- und Downloadmechanik für die Prüfpakete."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import urllib.request
import zipfile


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


def fetch_all(artifacts, cache, *, workers):
    unique = {item["sha256"]: item for item in artifacts}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        paths = pool.map(lambda item: fetch(item, cache), unique.values())
        return dict(zip(unique, paths))


def prepare_legal_files(bundle, sources, policy, policy_path, archives):
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
        origin = policy_path.parent / name
        if digest(origin) != checksum:
            raise ComplianceError("Veränderter Lizenztext: " + name)
        destination = bundle / "legal/licenses" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(origin, destination)
    shutil.copy2(policy_path, bundle / "legal/components.lock.json")
    shutil.copy2(policy_path, sources / "components.lock.json")


def write_inventories(bundle, sources, binary_metadata):
    source_index = sources / "sources-manifest.json"
    source_manifest = {"policySHA256": binary_metadata["policySHA256"], "files": files_in(sources)}
    source_index.write_text(json.dumps(source_manifest, indent=2) + "\n", encoding="utf-8")
    compliance = {
        **binary_metadata,
        "sourceManifestSHA256": digest(source_index),
        "files": files_in(bundle),
    }
    (bundle / "compliance.json").write_text(json.dumps(compliance, indent=2) + "\n", encoding="utf-8")


def verify_inventories(bundle, sources, compliance, source_manifest, *, allow_binary_symlinks=False):
    binary_files = files_in(bundle)
    binary_files.pop("compliance.json", None)
    source_files = files_in(sources)
    source_files.pop("sources-manifest.json", None)
    protected_binary_files = (
        item for name, item in binary_files.items()
        if not allow_binary_symlinks or name == "legal" or name.startswith("legal/")
    )
    if any("symlink" in item for item in source_files.values()) or any(
        "symlink" in item for item in protected_binary_files
    ):
        raise ComplianceError("Lizenz-/Quellenpaket enthält Dateiverweise statt Inhalt")
    if binary_files != compliance.get("files"):
        raise ComplianceError("Binär-/Lizenzdateien fehlen oder wurden verändert")
    if (source_files != source_manifest.get("files")
            or digest(sources / "sources-manifest.json") != compliance.get("sourceManifestSHA256")):
        raise ComplianceError("Quellcodepaket passt nicht zum Binärpaket")


def verify_legal_files(bundle, sources, policy, policy_sha):
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
    if (digest(bundle / "legal/components.lock.json") != policy_sha
            or digest(sources / "components.lock.json") != policy_sha):
        raise ComplianceError("Komponentenliste fehlt oder stimmt nicht")
    return len(artifacts)
