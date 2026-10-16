"""Originale Factur-X-Artefakte und exakt begrenzte KoSIT-Szenarien."""
import shutil
import re
from pathlib import Path
import xml.etree.ElementTree as ET
from validation_compliance import fetch, load_policy


NAMESPACE = "http://www.xoev.de/de/validator/framework/1/scenarios"
PROFILES = [
    ("MINIMUM", "urn:factur-x.eu:1p0:minimum"),
    ("BASICWL", "urn:factur-x.eu:1p0:basicwl"),
    ("BASIC", "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic"),
    ("EN16931", "urn:cen.eu:en16931:2017"),
    ("EXTENDED", "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended"),
]


def prepare(configuration, cache):
    policy = load_policy()
    artifacts = {item["name"]: item for item in policy["sourceArtifacts"]}
    for item in policy["facturXArtifacts"]:
        destination = configuration / item["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(fetch(artifacts[item["source"]], cache), destination)
    scenarios = configuration / "scenarios.xml"
    text = scenarios.read_text(encoding="utf-8")
    # Der allgemeine CII-Fallback verwendet dieselbe BT-24-Kennung wie EN16931.
    # KoSIT lehnt Mehrfachtreffer ab; die aktuelle Profilprüfung ersetzt ihn.
    text, count = re.subn(r"  <scenario>\s*<name>EN16931 \(CII\)</name>.*?</scenario>", "", text, flags=re.DOTALL)
    if count != 1:
        raise ValueError("Allgemeines CII-Szenario nicht eindeutig")
    shutil.copy2(Path(__file__).parent / "resources/facturx-report.xsl", configuration / "resources/facturx-report.xsl")
    additions = []
    for profile, guideline in PROFILES:
        folder = "resources/facturx/" + profile
        schematron_profile = "BASIC-WL" if profile == "BASICWL" else profile
        additions.append(f'''  <scenario>
    <name>Factur-X 1.09.2 / ZUGFeRD 2.5.2 ({profile})</name>
    <description><p>XML-Schema und Profilregeln des aktuellen Factur-X-Regelstands; keine Aussage zur historischen Dokumentversion oder zum PDF-Träger.</p></description>
    <namespace prefix="rsm">urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100</namespace>
    <namespace prefix="ram">urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100</namespace>
    <namespace prefix="rep">http://www.xoev.de/de/validator/varl/1</namespace>
    <match>exists(/rsm:CrossIndustryInvoice/rsm:ExchangedDocumentContext/ram:GuidelineSpecifiedDocumentContextParameter/ram:ID[. = '{guideline}'])</match>
    <validateWithXmlSchema><resource><name>Factur-X {profile} XSD D22B</name><location>{folder}/Factur-X_1.09.2_{profile}.xsd</location></resource></validateWithXmlSchema>
    <validateWithSchematron><resource><name>Factur-X {profile} Schematron 1.09.2</name><location>{folder}/_XSLT_{schematron_profile}/FACTUR-X_{schematron_profile}.xslt</location></resource></validateWithSchematron>
    <createReport><resource><name>XML-Prüfbericht</name><location>resources/facturx-report.xsl</location></resource></createReport>
    <acceptMatch>/rep:report/rep:assessment[1]/rep:accept[1]</acceptMatch>
  </scenario>''')
    if text.count("<noScenarioReport>") != 1 or "Factur-X 1.09.2 / ZUGFeRD" in text:
        raise ValueError("Unerwartete oder bereits erweiterte KoSIT-Konfiguration")
    text = text.replace("<noScenarioReport>", "\n".join(additions) + "\n  <noScenarioReport>")
    ET.fromstring(text)
    scenarios.write_text(text, encoding="utf-8")
