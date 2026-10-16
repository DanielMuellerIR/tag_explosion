#!/usr/bin/env python3
"""Release-Sperren am tatsächlich vorbereiteten Lizenz-/Quellenpaket prüfen."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("validation_compliance", ROOT / "scripts/validation_compliance.py")
compliance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compliance)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", type=Path, required=True)
parser.add_argument("--sources", type=Path, required=True)
options = parser.parse_args()


class ReleaseComplianceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="validation-release-test-")
        cls.root = Path(cls.temporary.name)
        cls.bundle = cls.root / "bundle"
        cls.sources = cls.root / "sources"
        shutil.copytree(options.bundle.resolve(), cls.bundle, symlinks=True)
        shutil.copytree(options.sources.resolve(), cls.sources, symlinks=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def verify(self):
        return compliance.verify(self.bundle, self.sources)

    def mutate(self, path, operation):
        original = path.read_bytes()
        try:
            operation(path)
            with self.assertRaises((compliance.ComplianceError, OSError)):
                self.verify()
        finally:
            path.write_bytes(original)

    def test_original_package_is_complete(self):
        self.assertEqual(self.verify()["status"], "passed")

    def test_missing_copyright_notice_blocks_release(self):
        notice = self.bundle / "legal/java/org.apache.commons_commons-lang3_3.20.0/META-INF/NOTICE.txt"
        self.mutate(notice, lambda path: path.unlink())

    def test_missing_openjdk_sources_blocks_release(self):
        source = self.sources / "artifacts/openjdk-source.tar.gz"
        moved = self.root / "temporarily-held-source.tar.gz"
        source.rename(moved)
        try:
            with self.assertRaises((compliance.ComplianceError, OSError)):
                self.verify()
        finally:
            moved.rename(source)

    def test_changed_rule_blocks_release(self):
        rule = self.bundle / "configuration/resources/ubl/2.1/xsl/EN16931-UBL-validation.xsl"
        self.mutate(rule, lambda path: path.write_bytes(path.read_bytes() + b"\n<!-- changed -->\n"))

    def test_changed_facturx_codelist_blocks_release(self):
        codelist = self.bundle / "configuration/resources/facturx/MINIMUM/_XSLT_MINIMUM/FACTUR-X_MINIMUM_codedb.xml"
        self.mutate(codelist, lambda path: path.write_bytes(path.read_bytes() + b"\n<!-- changed -->\n"))

    def test_missing_facturx_schematron_source_blocks_release(self):
        source = self.sources / "artifacts/facturx-MINIMUM-FACTUR-X_MINIMUM.sch"
        self.mutate(source, lambda path: path.unlink())

    def test_added_unknown_bytecode_blocks_release(self):
        def add_code(path):
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("unreviewed/NewLibrary.class", b"unapproved code")
        self.mutate(self.bundle / "validator.jar", add_code)

    def test_changed_runtime_blocks_release(self):
        self.mutate(self.bundle / "runtime/Contents/Home/release", lambda path: path.write_text("OTHER_RUNTIME=1\n"))

    def test_missing_runtime_license_blocks_release(self):
        self.mutate(self.bundle / "runtime/Contents/Home/legal/java.base/LICENSE", lambda path: path.unlink())

    def test_unreviewed_license_is_rejected(self):
        policy = json.loads(compliance.POLICY.read_text())
        policy["javaComponents"][0]["license"] = "UNKNOWN"
        path = self.root / "unreviewed-policy.json"
        path.write_text(json.dumps(policy))
        with self.assertRaises(compliance.ComplianceError):
            compliance.load_policy(path)

    def test_source_archive_must_be_included_as_content(self):
        source = self.sources / "artifacts/kosit-source.zip"
        held = self.root / "held-original-source.zip"
        source_index = self.sources / "sources-manifest.json"
        binary_index = self.bundle / "compliance.json"
        original_source_index = source_index.read_bytes()
        original_binary_index = binary_index.read_bytes()
        source.rename(held)
        source.symlink_to(held)
        try:
            # Selbst ein konsistentes Manifest darf einen Verweis auf einen
            # nur lokal vorhandenen Download nicht als mitgelieferte Quelle werten.
            data = json.loads(source_index.read_text())
            data["files"]["artifacts/kosit-source.zip"] = {"symlink": str(held)}
            source_index.write_text(json.dumps(data))
            data = json.loads(binary_index.read_text())
            data["sourceManifestSHA256"] = compliance.digest(source_index)
            binary_index.write_text(json.dumps(data))
            with self.assertRaisesRegex(compliance.ComplianceError, "Dateiverweise"):
                self.verify()
        finally:
            source.unlink()
            held.rename(source)
            source_index.write_bytes(original_source_index)
            binary_index.write_bytes(original_binary_index)

    def test_missing_sources_prevents_probe_creation(self):
        output = self.root / "must-not-be-created"
        environment = dict(os.environ, VALIDATION_SOURCES=str(self.root / "missing-sources"))
        process = subprocess.run(
            [str(ROOT / "scripts/probe-xrechnung-distribution.sh"), str(self.bundle), str(output)],
            env=environment, capture_output=True, text=True, timeout=20,
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(output.exists())
        self.assertIn("Quellcode", process.stderr)

    def test_preparation_does_not_overwrite_existing_files(self):
        output = self.root / "protected-package"
        output.mkdir()
        marker = output / "keep.txt"
        marker.write_text("existing user data")
        process = subprocess.run(
            ["python3", str(ROOT / "scripts/prepare-xrechnung-validator.py"), "--output", str(output)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(process.returncode, 2)
        self.assertEqual(marker.read_text(), "existing user data")

    def test_preparation_rejects_nested_output_paths(self):
        output = self.root / "nested-package"
        process = subprocess.run(
            ["python3", str(ROOT / "scripts/prepare-xrechnung-validator.py"), "--output", str(output),
             "--sources-output", str(output / "sources")],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(process.returncode, 2)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
