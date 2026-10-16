#!/usr/bin/env python3
"""Release-Sperren für veraPDF und das passende Quellenpaket."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import pdf_validation_compliance as compliance
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", type=Path, required=True)
parser.add_argument("--sources", type=Path, required=True)
options = parser.parse_args()


class PDFComplianceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="pdf-compliance-test-")
        cls.root = Path(cls.temporary.name)
        cls.bundle = cls.root / "bundle"
        cls.sources = cls.root / "sources"
        shutil.copytree(options.bundle, cls.bundle)
        shutil.copytree(options.sources, cls.sources)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def verify(self):
        return compliance.verify(self.bundle, self.sources)

    def mutate(self, path, operation):
        data = path.read_bytes()
        try:
            operation(path)
            with self.assertRaises((compliance.ComplianceError, OSError, ValueError)):
                self.verify()
        finally:
            path.write_bytes(data)

    def test_complete_package(self):
        self.assertEqual(self.verify()["status"], "passed")
        self.assertEqual(self.verify()["classes"], 6824)

    def test_unknown_bytecode(self):
        def add(path):
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("unapproved/Unknown.class", b"unknown")
        self.mutate(self.bundle / "validator.jar", add)

    def test_missing_cddl_license(self):
        self.mutate(self.bundle / "legal/licenses/CDDL-GPL-1.1.txt", lambda path: path.unlink())

    def test_missing_source_copyright(self):
        policy = compliance.load_policy()
        name = next(item["sourceNoticeFile"] for item in policy["javaComponents"] if item.get("sourceNoticeFile"))
        self.mutate(self.bundle / "legal/licenses" / name, lambda path: path.unlink())

    def test_missing_preferred_sources(self):
        self.mutate(self.sources / "artifacts/veraPDF-validation-1.30.3-source.zip", lambda path: path.unlink())

    def test_missing_original_profile_sources(self):
        self.mutate(self.sources / "artifacts/veraPDF-profiles-c4f57ef-source.zip", lambda path: path.unlink())

    def test_source_symlink_even_with_matching_index(self):
        source = self.sources / "artifacts/veraPDF-validation-1.30.3-source.zip"
        held = self.root / "held.zip"
        index = self.sources / "sources-manifest.json"
        binary = self.bundle / "compliance.json"
        saved_index, saved_binary = index.read_bytes(), binary.read_bytes()
        source.rename(held)
        source.symlink_to(held)
        try:
            manifest = json.loads(index.read_text())
            manifest["files"]["artifacts/veraPDF-validation-1.30.3-source.zip"] = {"symlink": str(held)}
            index.write_text(json.dumps(manifest))
            manifest = json.loads(binary.read_text())
            manifest["sourceManifestSHA256"] = compliance.digest(index)
            binary.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(compliance.ComplianceError, "Dateiverweise"):
                self.verify()
        finally:
            source.unlink()
            held.rename(source)
            index.write_bytes(saved_index)
            binary.write_bytes(saved_binary)


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
