#!/usr/bin/env python3
"""Gemeinsamen Dienst und CLI mit dem echten, geprüften KoSIT-Paket testen."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import time
import urllib.request


def check_interrupt(root, bundle, fixtures, environment):
    tagx = root / ".build/debug/tagx"
    process = subprocess.Popen([str(tagx), "validate-xrechnung", str(fixtures / "ubl.xml"),
                                "--bundle", str(bundle), "--format", "common", "--json"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
    child = None
    child_command = None
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and process.poll() is None:
            listing = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
            for line in listing.splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3 and fields[1] == str(process.pid) and fields[2].startswith(str(bundle / "runtime/Contents/Home/bin/java") + " "):
                    child, child_command = int(fields[0]), fields[2]
                    break
            if child:
                break
            time.sleep(0.02)
        assert child, "Der echte Java-Kindprozess wurde nicht beobachtet"
        process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 130, (process.returncode, stderr)
        result = json.loads(stdout)[0]["validation"]
        assert result["status"] == "cancelled" and result.get("xmlStatus") is None
        remaining = subprocess.run(["ps", "-p", str(child), "-o", "command="], capture_output=True, text=True)
        assert remaining.returncode != 0, "Java-Kind nach Abbruch nicht beendet/geerntet"
        print("CLI-SIGINT: cancelled, Exit 130, Java-Kind beendet", flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)
        if child:
            remaining = subprocess.run(["ps", "-p", str(child), "-o", "command="], capture_output=True, text=True)
            try:
                if remaining.stdout.strip() == child_command and os.getpgid(child) == child:
                    os.killpg(child, signal.SIGKILL)
            except ProcessLookupError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location("prototype_fixtures", root / "scripts/test-xrechnung-prototype.py")
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    with tempfile.TemporaryDirectory(prefix="invoice-validation-fixtures-") as directory:
        for kind, (name, checksum) in fixtures.FIXTURES.items():
            data = urllib.request.urlopen(fixtures.BASE + name, timeout=30).read()
            if hashlib.sha256(data).hexdigest() != checksum:
                raise ValueError("Beispiel-Prüfsumme stimmt nicht: " + name)
            (Path(directory) / (kind + ".xml")).write_bytes(data)
        environment = dict(os.environ, TAGX_VALIDATION_BUNDLE=str(args.bundle.resolve()),
                           TAGX_VALIDATION_FIXTURES=directory, JAVA_HOME="/does-not-exist")
        for name in ["JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"]:
            environment.pop(name, None)
        process = subprocess.run(["swift", "test", "--filter", "InvoiceValidationRuntimeTests"],
                                 cwd=root, env=environment, timeout=180)
        if process.returncode == 0:
            check_interrupt(root, args.bundle.resolve(), Path(directory), environment)
        raise SystemExit(process.returncode)


if __name__ == "__main__":
    main()
