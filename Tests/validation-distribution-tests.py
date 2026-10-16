#!/usr/bin/env python3
"""Negative Auslieferungsfälle gegen die tatsächlich erzeugten Quellen-ZIPs."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('distribution', ROOT / 'scripts/verify-validation-distribution.py')
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--artifacts', type=Path, required=True)
parser.add_argument('--version', required=True)
options = parser.parse_args()


class DistributionTests(unittest.TestCase):
    def test_actual_source_zips_match_app(self):
        result = distribution.verify_app(options.app, options.artifacts, options.version)
        self.assertEqual(result['sources']['xml']['classes'], 4954)
        self.assertEqual(result['sources']['pdf']['classes'], 6824)

    def test_missing_pdf_sources_blocks_distribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            name = f'TagExplosion-{options.version}-validation-sources.zip'
            shutil.copyfile(options.artifacts / name, target / name)
            with self.assertRaises(distribution.core.ComplianceError):
                distribution.verify_app(options.app, target, options.version)

    def test_other_app_version_is_rejected(self):
        with self.assertRaises(distribution.core.ComplianceError):
            distribution.verify_app(options.app, options.artifacts, '999.0.0')

    def test_unsafe_archive_is_rejected(self):
        for name, mode in [('source/../../outside', stat.S_IFREG), ('source/link', stat.S_IFLNK)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / 'source.zip'
                with zipfile.ZipFile(archive, 'w') as output:
                    entry = zipfile.ZipInfo(name)
                    entry.external_attr = (mode | 0o644) << 16
                    output.writestr(entry, 'target')
                destination = root / 'unpacked'
                destination.mkdir()
                with self.assertRaises(distribution.core.ComplianceError):
                    distribution.unpack_sources(archive, destination)

    def test_case_collision_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.zip'
            with zipfile.ZipFile(archive, 'w') as output:
                output.writestr('source/NOTICE', 'first')
                output.writestr('source/notice', 'second')
            destination = root / 'unpacked'
            destination.mkdir()
            with self.assertRaises(distribution.core.ComplianceError):
                distribution.unpack_sources(archive, destination)


unittest.main(argv=[sys.argv[0]], verbosity=2)
