#!/usr/bin/env python3
"""Geprüfte veraPDF-CLI ohne zusätzliche Nutzerlaufzeit vorbereiten."""
import argparse
import os
from pathlib import Path
import tempfile
from pdf_validation_compliance import POLICY, digest, prepare

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
parser.add_argument("--sources-output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
destination = (args.output or root / ".validation-build" / ("pdf-" + digest(POLICY)[:16])).resolve()
sources = (args.sources_output or Path(str(destination) + "-sources")).resolve()
if destination.exists() or sources.exists() or destination == sources:
    parser.error("Vorhandene Ziele werden nicht überschrieben.")
if destination in sources.parents or sources in destination.parents:
    parser.error("Binär- und Quellenziel dürfen nicht ineinander liegen.")
destination.parent.mkdir(parents=True, exist_ok=True)
sources.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="pdf-prepare-", dir=destination.parent) as temporary:
    work = Path(temporary)
    prepare(work / "package", work / "sources", root / ".validation-build/pdf-downloads")
    os.rename(work / "sources", sources)
    try:
        os.rename(work / "package", destination)
    except OSError:
        os.rename(sources, work / "sources")
        raise
print(destination)
print("Sources: " + str(sources))
