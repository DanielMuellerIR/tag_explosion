#!/usr/bin/env python3
"""Echte KoSIT-CLI-Läufe mit gepinnten Beispielen und gezielten Fehlern prüfen."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET


BASE = ("https://projekte.kosit.org/xrechnung/xrechnung-testsuite/-/raw/"
        "1ce1dafffd035e5ce59a7ab0d3bf44ac14af16c9/src/test/business-cases/standard/")
FIXTURES = {
    "ubl": ("01.01a-INVOICE_ubl.xml", "74fb09c609d5fba15a8c543060998d3b92858f56a81fb5b0ed244d6794e498d1"),
    "cii": ("01.01a-INVOICE_uncefact.xml", "727b51982a84c9b406599a7384783570910440ed405c9bb6d918b22442636886"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--tagx", type=Path, default=Path(".build/debug/tagx"))
    parser.add_argument("--summary", type=Path, default=Path(".build/kosit-prototype-summary.json"))
    parser.add_argument("--probe-app", type=Path, help="Zusätzlich verschobene App-Hülle ohne Netz/System-Java prüfen")
    args = parser.parse_args()
    tagx, bundle = args.tagx.resolve(), args.bundle.resolve()
    results = []
    with tempfile.TemporaryDirectory(prefix="tagx-kosit-test-") as directory:
        work = Path(directory)
        fixtures = {}
        for kind, (name, checksum) in FIXTURES.items():
            data = urllib.request.urlopen(BASE + name, timeout=30).read()
            if hashlib.sha256(data).hexdigest() != checksum:
                raise ValueError("Beispiel-Prüfsumme stimmt nicht: " + name)
            fixtures[kind] = data.decode("utf-8")

        def check(name, content, expected_exit, status=None, step=None, code=None, selected_bundle=None):
            file = work / (name + ".xml")
            data = content if isinstance(content, bytes) else content.encode("utf-8")
            file.write_bytes(data)
            environment = dict(os.environ, PATH="/usr/bin:/bin", JAVA_HOME="/does-not-exist")
            for variable in ["JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"]:
                environment.pop(variable, None)
            start = time.monotonic()
            process = subprocess.run(
                [str(tagx), "validate-xrechnung", str(file), "--bundle", str(selected_bundle or bundle), "--json"],
                capture_output=True, text=True, timeout=75, env=environment,
            )
            if process.returncode != expected_exit:
                raise AssertionError((name, process.returncode, process.stdout, process.stderr))
            report = json.loads(process.stdout)[0]["validation"] if status else None
            if report:
                assert report["status"] == status, (name, report)
                assert "ohne Gewähr" in report["notice"]
                if step:
                    assert any(item["id"] == step and not item["valid"] for item in report["steps"]), report
                if code:
                    assert any(item.get("code") == code for item in report["issues"]), report
            assert file.read_bytes() == data, "Originaldatei wurde verändert"
            results.append({"case": name, "exit": process.returncode, "status": status,
                            "seconds": round(time.monotonic() - start, 3),
                            "codes": sorted({item["code"] for item in report["issues"] if item.get("code")}) if report else []})
            print(name + ": OK", flush=True)

        check("valid-ubl", fixtures["ubl"], 0, "passed")
        check("valid-cii", fixtures["cii"], 0, "passed")
        for kind, prefix in [("ubl", "cbc"), ("cii", "ram")]:
            changed, count = re.subn(r"<" + prefix + r":BuyerReference>.*?</" + prefix + r":BuyerReference>", "", fixtures[kind])
            assert count == 1
            check("missing-buyer-" + kind, changed, 3, "failed", "val-sch.2", "BR-DE-15")
        changed = fixtures["ubl"].replace("<cbc:ID>", "<cbc:UnknownField>", 1).replace("</cbc:ID>", "</cbc:UnknownField>", 1)
        check("invalid-xsd", changed, 3, "failed", "val-xsd")
        changed = fixtures["ubl"].replace('>336.9</cbc:PayableAmount>', '>999.99</cbc:PayableAmount>')
        assert changed != fixtures["ubl"]
        check("incorrect-sum", changed, 3, "failed", "val-sch.1", "BR-CO-16")
        check("unsupported-profile", fixtures["ubl"].replace("xrechnung_3.0", "xrechnung_9.9"), 4, "unsupported")
        check("plain-en16931", fixtures["ubl"].replace("#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0", ""), 4, "unsupported")
        check("malformed-xml", "<Invoice>", 3, "failed", "val-xml")
        doctype = '<!DOCTYPE Invoice [<!ENTITY x SYSTEM "file:///etc/passwd">]><Invoice>&x;</Invoice>'
        check("external-entity", doctype, 1)
        check("external-entity-utf16", doctype.encode("utf-16"), 1)
        check("input-limit", b" " * (16 * 1024 * 1024 + 1), 1)
        check("missing-runtime", fixtures["ubl"], 1, selected_bundle=work)
        broken = work / "broken-bundle"
        (broken / "runtime/Contents/Home/bin").mkdir(parents=True)
        (broken / "configuration").mkdir()
        (broken / "runtime/Contents/Home/bin/java").symlink_to(bundle / "runtime/Contents/Home/bin/java")
        shutil.copy2(bundle / "manifest.json", broken / "manifest.json")
        shutil.copy2(bundle / "configuration/scenarios.xml", broken / "configuration/scenarios.xml")
        (broken / "validator.jar").write_bytes(b"not a Java archive")
        check("broken-tool", fixtures["ubl"], 1, selected_bundle=broken)

        if args.probe_app:
            # Netz und globales Java werden nur für das Kind gesperrt. Die
            # öffentlichen Testdaten wurden vorher geladen und geprüft.
            app = work / "relocated app with spaces" / "XRechnungRuntimeProbe.app"
            shutil.copytree(args.probe_app.resolve(), app, symlinks=True)
            embedded = app / "Contents/Resources/XRechnungValidator"
            output = work / "offline-reports"
            output.mkdir()
            policy = ('(version 1) (allow default) (deny network*) '
                      '(deny file-read* (subpath "/Library/Java") (subpath "/System/Library/Java") '
                      '(subpath "/opt/homebrew") (literal "/usr/bin/java"))')
            invocation = [
                "/usr/bin/sandbox-exec", "-p", policy, str(app / "Contents/MacOS/XRechnungRuntimeProbe"),
                "-Xmx512m", "-Djava.awt.headless=true", "-Djansi.mode=strip",
                "-Djavax.xml.accessExternalDTD=", "-Djavax.xml.accessExternalSchema=file",
                "-Djavax.xml.accessExternalStylesheet=file", "-jar", str(embedded / "validator.jar"),
                "-s", str(embedded / "configuration/scenarios.xml"), "-r", str(embedded / "configuration"),
                "-o", str(output), str(work / "valid-ubl.xml"), str(work / "valid-cii.xml"),
            ]
            start = time.monotonic()
            process = subprocess.run(invocation, capture_output=True, text=True, timeout=75,
                                     env={"PATH": "/usr/bin:/bin", "JAVA_HOME": "/does-not-exist",
                                          "HOME": os.environ["HOME"], "TMPDIR": str(work)})
            assert process.returncode == 0, (process.stdout, process.stderr)
            namespace = {"r": "http://www.xoev.de/de/validator/varl/1"}
            reports = list(output.glob("*-report.xml"))
            assert len(reports) == 2
            for file in reports:
                root = ET.parse(file).getroot()
                assert root.attrib["valid"] == "true"
                assert root.find("r:assessment/r:accept", namespace) is not None
                steps = root.findall("r:scenarioMatched/r:validationStepResult", namespace)
                for step in ["val-xml", "val-xsd", "val-sch.1", "val-sch.2"]:
                    assert any(item.attrib["id"] == step and item.attrib["valid"] == "true" for item in steps)
            results.append({"case": "offline-relocated-app", "exit": 0, "reports": 2,
                            "networkDenied": True, "systemJavaAndHomebrewDenied": True,
                            "seconds": round(time.monotonic() - start, 3)})
            print("offline-relocated-app: OK", flush=True)

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(json.dumps({"cases": results}, indent=2) + "\n", encoding="utf-8")
    print(str(len(results)) + " Integrationsfälle bestanden; " + str(args.summary))


if __name__ == "__main__":
    main()
