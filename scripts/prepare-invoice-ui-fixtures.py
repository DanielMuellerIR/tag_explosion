#!/usr/bin/env python3
"""Gepinnte KoSIT-Beispiele und eigene PDF-/Fehlerfälle für die App-Abnahme."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request


def pdf(xml):
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R /AF [5 0 R] /Names << /EmbeddedFiles << /Names [(xrechnung.xml) 5 0 R] >> >> >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>",
        b"<< /Length 0 >>\nstream\n\nendstream",
        b"<< /Type /Filespec /F (xrechnung.xml) /AFRelationship /Data /EF << /F 6 0 R >> >>",
        ("<< /Type /EmbeddedFile /Length %d >>\nstream\n" % len(xml)).encode() + xml + b"\nendstream",
    ]
    data = b"%PDF-1.7\n"
    offsets = []
    for index, body in enumerate(objects):
        offsets.append(len(data))
        data += ("%d 0 obj\n" % (index + 1)).encode() + body + b"\nendobj\n"
    xref = len(data)
    data += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)).encode()
    for offset in offsets:
        data += ("%010d 00000 n \n" % offset).encode()
    return data + ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--facturx", action="store_true", help="Eigene aktuelle Factur-X-Profilfälle ergänzen")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("kosit_fixtures", Path(__file__).with_name("test-xrechnung-prototype.py"))
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    data = {}
    for kind, (name, checksum) in fixtures.FIXTURES.items():
        data[kind] = urllib.request.urlopen(fixtures.BASE + name, timeout=30).read()
        if hashlib.sha256(data[kind]).hexdigest() != checksum:
            raise ValueError("Beispiel-Prüfsumme stimmt nicht: " + name)
        (args.output / (kind + ".xml")).write_bytes(data[kind])
    ubl = data["ubl"].decode("utf-8")
    changed, count = re.subn(r"<cbc:BuyerReference>.*?</cbc:BuyerReference>", "", ubl)
    assert count == 1
    (args.output / "failed.xml").write_text(changed, encoding="utf-8")
    (args.output / "unknown.xml").write_text(ubl.replace("xrechnung_3.0", "xrechnung_9.9"), encoding="utf-8")
    (args.output / "invoice.pdf").write_bytes(pdf(data["ubl"]))
    if args.facturx:
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="invoice-fixture-generator-") as temporary:
            work = Path(temporary)
            (work / "main.swift").write_text('''import Foundation
for profile in InvoiceValidationFixtures.facturXProfiles {
    try Data(InvoiceValidationFixtures.facturX(profile: profile.name).utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(profile.name + ".xml"))
}
''')
            subprocess.run(["xcrun", "swiftc", str(root / "Tests/Support/InvoiceValidationFixtures.swift"),
                            str(root / "Tests/Support/FacturXValidationFixtures.swift"), str(work / "main.swift"),
                            "-o", str(work / "generate")], check=True)
            subprocess.run([str(work / "generate"), str(args.output.resolve())], check=True)
        minimum = (args.output / "MINIMUM.xml").read_text()
        (args.output / "FACTURX-schema.xml").write_text(minimum.replace("<ram:TypeCode>380", "<ram:Unexpected/><ram:TypeCode>380"))
        (args.output / "FACTURX-rule.xml").write_text(minimum.replace(
            "<ram:SpecifiedLegalOrganization><ram:ID>TEST-SELLER</ram:ID></ram:SpecifiedLegalOrganization>", "").replace(
            '<ram:SpecifiedTaxRegistration><ram:ID schemeID="VA">DE123456789</ram:ID></ram:SpecifiedTaxRegistration>', ""))
        basic = (args.output / "BASIC.xml").read_text()
        warning = basic.replace('<ram:ActualDeliverySupplyChainEvent><ram:OccurrenceDateTime><udt:DateTimeString format="102">20261016</udt:DateTimeString></ram:OccurrenceDateTime></ram:ActualDeliverySupplyChainEvent>', "")
        (args.output / "FACTURX-warning.xml").write_text(warning)
        (args.output / "FACTURX-pdf.pdf").write_bytes(pdf((args.output / "EXTENDED.xml").read_bytes()))
    print(args.output)


if __name__ == "__main__":
    main()
