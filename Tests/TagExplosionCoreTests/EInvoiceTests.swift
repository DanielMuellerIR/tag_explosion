// Erkennung, Profilauflösung und Darstellung von Rechnungs- und Bestell-XML.
@testable import EInvoiceCore
import Foundation
import TagExplosionCore
import Testing

@Suite("EInvoice")
struct EInvoiceTests {

    @Test("Fremde Namensräume erhalten keine EN-16931-Zuordnung",
          arguments: ["urn:example:foreign", "urn:oasis:names:specification:ubl:schema:xsd:FakeCommonBasicComponents-2"])
    func foreignNamespacesDoNotMap(uri: String) throws {
        let xml = """
        <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
          xmlns:cbc="\(uri)"><cbc:ID>FREMDE-ID</cbc:ID></Invoice>
        """
        let doc = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
        #expect(doc.summary.invoiceNumber == nil)
        #expect(field(doc, term: "BT-1") == nil)
        #expect(doc.warnings.contains { $0.code == "BR-02" })
    }

    @Test("Fremde Gruppen lösen auch keine dynamische Feldzuordnung aus", arguments: ["cac", "evil-cac"])
    func foreignPartyDoesNotMap(prefix: String) throws {
        let xml = """
        <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
          xmlns:\(prefix)="urn:example:foreign"
          xmlns:a="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
          xmlns:b="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
          <\(prefix):AccountingSupplierParty><a:Party><a:PartyTaxScheme>
            <b:CompanyID>FREMD</b:CompanyID><a:TaxScheme><b:ID>VAT</b:ID></a:TaxScheme>
          </a:PartyTaxScheme></a:Party></\(prefix):AccountingSupplierParty>
        </Invoice>
        """
        let doc = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
        #expect(field(doc, term: "BT-31") == nil)
    }

    @Test("Fremde UN/CEFACT-ähnliche URIs werden nicht kanonisiert")
    func foreignCIIURI() throws {
        let xml = Self.ciiXML.replacingOccurrences(
            of: "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100",
            with: "urn:example:ReusableAggregateBusinessInformationEntity:100")
        let doc = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
        #expect(doc.summary.invoiceNumber == nil)
        #expect(field(doc, term: "BT-1") == nil)
    }

    // MARK: - Helfer

    private func field(_ doc: EInvoiceDocument, term: String) -> EInvoiceField? {
        doc.fields.first { $0.term == term }
    }

    /// Feld einer Bestellung über seine Order-X-Bezeichnung (kein BT-Term).
    private func labeled(_ doc: EInvoiceDocument, _ label: String) -> EInvoiceField? {
        doc.fields.first { $0.term == nil && $0.termName == label }
    }

    /// Temporäres Verzeichnis für Dateien, die ein Test braucht.
    func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("einvoice-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    // MARK: - Erkennung

    @Test("Inhaltstest erkennt CII, UBL-Rechnung, UBL-Gutschrift, Order-X und UBL-Bestellungen")
    func sniffAcceptsInvoiceSyntaxes() {
        #expect(EInvoiceReader.sniffXML(Data(Self.ciiXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.ublXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.ublCreditNoteXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.orderXXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.ublOrderXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.ublOrderResponseXML.utf8)))
        // Der Order-X-Wurzelname allein reicht nicht — der Namensraum muss passen.
        let foreign = "<o:SCRDMCCBDACIOMessageStructure xmlns:o=\"urn:example:SCRDMCCBDACIOMessageStructure:1\"/>"
        #expect(!EInvoiceReader.sniffXML(Data(foreign.utf8)))
    }

    @Test("Fremd-XML wird abgelehnt — auch wenn 'Invoice' im Text vorkommt")
    func sniffRejectsForeignXML() {
        let plist = "<?xml version=\"1.0\"?><plist><dict><key>Invoice</key></dict></plist>"
        #expect(!EInvoiceReader.sniffXML(Data(plist.utf8)))
        #expect(throws: EInvoiceError.notAnInvoice) {
            try EInvoiceReader.document(fromXML: Data(plist.utf8), source: .xmlFile)
        }
    }

    @Test("Ein Kommentar mit 'CrossIndustryInvoice' macht Fremd-XML nicht zur Rechnung")
    func sniffIgnoresCommentsAndDoctype() {
        let foreign = """
        <?xml version="1.0"?>
        <!-- exportiert aus CrossIndustryInvoice-Konverter -->
        <!DOCTYPE settings>
        <settings><entry>CrossIndustryInvoice</entry></settings>
        """
        #expect(!EInvoiceReader.sniffXML(Data(foreign.utf8)))

        // Dieselben übersprungenen Konstrukte VOR einer echten Rechnung
        // dürfen die Erkennung nicht verhindern.
        let commented = "<!-- Vorspann -->\n" + Self.ciiXML.replacingOccurrences(
            of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        #expect(EInvoiceReader.sniffXML(Data(commented.utf8)))
    }

    @Test("Rechnungserkennung liest bis zum Wurzelelement statt nur 8 KiB")
    func sniffReadsPastLongPreamble() throws {
        let body = Self.ciiXML.replacingOccurrences(
            of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        let xml = "<!-- \(String(repeating: "Vorspann", count: 1_500)) -->\n" + body
        #expect(Data(xml.utf8).count > 8_192)
        #expect(EInvoiceReader.sniffXML(Data(xml.utf8)))

        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("langer-vorspann.xml")
            try Data(xml.utf8).write(to: url)
            #expect(MediaFormats.kind(of: url) == .invoice)
            #expect(MediaFormats.expandMediaFiles([dir]) == [
                MediaFormats.canonicalFileURL(url),
            ])
        }
    }

    @Test("CII-Wurzelname braucht den passenden Rechnungs-Namensraum")
    func sniffRequiresInvoiceNamespace() throws {
        let foreign = """
        <?xml version="1.0"?>
        <a:CrossIndustryInvoice xmlns:a="urn:example:CrossIndustryInvoice:not-standard"/>
        """
        #expect(!EInvoiceReader.sniffXML(Data(foreign.utf8)))

        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("nur-gleicher-name.xml")
            try Data(foreign.utf8).write(to: url)
            #expect(MediaFormats.kind(of: url) == nil)
            #expect(MediaFormats.expandMediaFiles([dir]).isEmpty)
        }
    }

    @Test("UTF-16-Rechnungen (mit und ohne BOM) werden erkannt")
    func sniffAcceptsUTF16() throws {
        let xml = Self.ciiXML.replacingOccurrences(of: "encoding=\"UTF-8\"",
                                                   with: "encoding=\"UTF-16\"")
        var littleEndianWithBOM = Data([0xFF, 0xFE])
        littleEndianWithBOM.append(contentsOf: xml.utf16.flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })
        #expect(EInvoiceReader.sniffXML(littleEndianWithBOM))

        let bigEndianWithoutBOM = Data(xml.utf16.flatMap {
            [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        })
        #expect(EInvoiceReader.sniffXML(bigEndianWithoutBOM))
    }

    @Test("MediaFormats nimmt nur Rechnungs-XML an; Ordner-Drop filtert Fremd-XML")
    func mediaFormatsAcceptsOnlyInvoiceXML() throws {
        try withTempDirectory { dir in
            let invoiceURL = dir.appendingPathComponent("rechnung.xml")
            try Data(Self.ciiXML.utf8).write(to: invoiceURL)
            #expect(MediaFormats.kind(of: invoiceURL) == .invoice)

            let foreignURL = dir.appendingPathComponent("fremd.xml")
            try Data("<?xml version=\"1.0\"?><settings/>".utf8).write(to: foreignURL)
            #expect(MediaFormats.kind(of: foreignURL) == nil)

            let expanded = MediaFormats.expandMediaFiles([dir])
            #expect(expanded.map(\.lastPathComponent) == ["rechnung.xml"])
        }
    }

    // MARK: - Profil-Auflösung

    @Test("Spezifikationskennungen (BT-24) werden korrekt aufgelöst")
    func profileResolution() {
        func resolved(_ urn: String) -> EInvoiceProfile {
            EInvoiceProfile.resolve(guidelineID: urn, syntax: .cii)
        }
        #expect(resolved("urn:cen.eu:en16931:2017").standard == "EN 16931")
        #expect(resolved("urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic")
            .profile == "BASIC")
        #expect(resolved("urn:factur-x.eu:1p0:minimum").profile == "MINIMUM")
        #expect(resolved("urn:factur-x.eu:1p0:basicwl").profile == "BASIC WL")
        #expect(resolved("urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended")
            .profile == "EXTENDED")
        #expect(resolved("urn:cen.eu:en16931:2017#compliant#urn:zugferd.de:2p0:basic")
            .standard == "ZUGFeRD 2.0")
        #expect(resolved("urn:ferd:CrossIndustryDocument:invoice:1p0:comfort")
            .standard == "ZUGFeRD 1.0")
        // Order-X und Peppol-Bestellungen
        #expect(resolved("urn:order-x.eu:1p0:basic").standard == "Order-X")
        #expect(resolved("urn:order-x.eu:1p0:basic").profile == "BASIC")
        #expect(resolved("urn:order-x.eu:1p0:comfort").profile == "COMFORT")
        #expect(resolved("urn:order-x.eu:1p0:extended").profile == "EXTENDED")
        #expect(resolved("urn:fdc:peppol.eu:poacc:trns:order:3").profile == "Peppol BIS Order")
        #expect(resolved("urn:fdc:peppol.eu:poacc:trns:order_response:3").profile
            == "Peppol BIS Order Response")
        let xr30 = resolved("urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0")
        #expect(xr30.standard == "XRechnung")
        #expect(xr30.profile == "XRechnung 3.0")
        let xr23ext = resolved("urn:cen.eu:en16931:2017#conformant#urn:xoev-de:kosit:extension:xrechnung_2.3")
        #expect(xr23ext.profile == "XRechnung 2.3 (mit Extension)")
        #expect(resolved("urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0")
            .standard == "Peppol BIS")
        for unknown in ["order_custom:3", "order_response_custom:3"] {
            #expect(resolved("urn:fdc:peppol.eu:poacc:trns:" + unknown).standard == "EN 16931-basiert?")
        }
        // Bloße Namensähnlichkeit darf einen fremden Bezeichner nicht als
        // bekannten Standard ausgeben.
        #expect(resolved("urn:example:xrechnung_demo").standard == "EN 16931-basiert?")
        #expect(resolved("urn:example:peppol.eu:not-billing").standard
            == "EN 16931-basiert?")
        // Auch ein VOLLSTÄNDIG eingebetteter bekannter Stamm zählt nur, wenn
        // er am Anfang einer #-Komponente steht — sonst würde eine fremde
        // URN, die einen echten Stamm als Suffix trägt, falsch klassifiziert.
        #expect(resolved("urn:example:urn:factur-x.eu:1p0:basic").standard
            == "EN 16931-basiert?")
        #expect(resolved("urn:example:urn:xoev-de:kosit:standard:xrechnung_2.2").standard
            == "EN 16931-basiert?")
        #expect(resolved("urn:example:urn:fdc:peppol.eu:2017:poacc:billing:3.0").standard
            == "EN 16931-basiert?")
        #expect(resolved("urn:example:urn:zugferd.de:2p0:basic").standard
            == "EN 16931-basiert?")
        // Review-Fund 2026-08-17: Version, Extension und Profil kommen NUR aus
        // der gematchten, normalisierten Komponente.
        // Grossgeschriebene Komponente: Die Erkennung lief schon immer auf der
        // kleingeschriebenen Fassung, die Version wurde aber aus der ROHEN
        // Kennung gezogen — dort stand "XRECHNUNG_3.0", und "xrechnung_" fand
        // sich nicht. Ergebnis war "XRechnung URN" ohne Versionsnummer.
        let grossgeschrieben = resolved(
            "urn:cen.eu:en16931:2017#compliant#URN:XEINKAUF.DE:KOSIT:XRECHNUNG_3.0")
        #expect(grossgeschrieben.standard == "XRechnung")
        #expect(grossgeschrieben.profile == "XRechnung 3.0")
        // Nachgestellte fremde Komponente: Sie darf weder ein
        // Extension-Kennzeichen noch ein Factur-X-Profil beisteuern.
        let mitFremdteil = resolved(
            "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"
                + "#urn:example:kosit:extension")
        #expect(mitFremdteil.profile == "XRechnung 3.0")
        let facturXMitFremdteil = resolved(
            "urn:factur-x.eu:1p0:basic#urn:example:extended")
        #expect(facturXMitFremdteil.profile == "BASIC")
        // Unbekannte URN bleibt sichtbar statt geraten.
        #expect(resolved("urn:example:foo").profile == "urn:example:foo")
    }

    // MARK: - CII

    @Test("CII: Felder, dynamische Zuordnungen und Zusammenfassung stimmen")
    func ciiDocument() throws {
        let doc = try EInvoiceReader.document(fromXML: Data(Self.ciiXML.utf8), source: .xmlFile)
        #expect(doc.syntax == .cii)
        #expect(doc.profile.profile == "EN 16931 (COMFORT)")

        #expect(field(doc, term: "BT-1")?.value == "R-1")
        // Datum: Roh-Wert bleibt, ISO-Lesehilfe kommt dazu.
        #expect(field(doc, term: "BT-2")?.value == "20260814")
        #expect(field(doc, term: "BT-2")?.valueNote == "2026-08-14")
        #expect(field(doc, term: "BT-3")?.valueNote == "Rechnung")
        #expect(field(doc, term: "BT-27")?.value == "Verkäufer GmbH")
        #expect(field(doc, term: "BT-44")?.value == "Käufer AG")
        // Steuernummer (FC) und USt-IdNr. (VA) auseinanderhalten
        #expect(field(doc, term: "BT-32")?.value == "1/23/456")
        #expect(field(doc, term: "BT-31")?.value == "DE999999999")
        // Menge samt Einheit — das unitCode-Attribut trägt seine eigene
        // BT-Nummer (BT-130 an BT-129, BT-150 an BT-149).
        #expect(field(doc, term: "BT-129")?.value == "2")
        #expect(field(doc, term: "BT-129")?.attributes
            == [XMLTreeAttribute(name: "unitCode", value: "HUR")])
        #expect(field(doc, term: "BT-129")?.valueNote == "Stunde(n)")
        #expect(field(doc, term: "BT-129")?.attributeTerms
            == [EInvoiceAttributeTerm(attribute: "unitCode", term: "BT-130",
                                      termName: EN16931.name(for: "BT-130"))])
        #expect(field(doc, term: "BT-149")?.attributeTerms
            == [EInvoiceAttributeTerm(attribute: "unitCode", term: "BT-150",
                                      termName: EN16931.name(for: "BT-150"))])
        // Positions-Nachlass vs. Dokument-Nachlass vs. Dokument-Zuschlag —
        // die Indikatoren nutzen die XML-Schema-Booleans 0/1.
        #expect(field(doc, term: "BT-136")?.value == "1.00")
        #expect(field(doc, term: "BT-92")?.value == "5.00")
        #expect(field(doc, term: "BT-97")?.value == "Treuerabatt")
        #expect(field(doc, term: "BT-99")?.value == "3.00")
        #expect(field(doc, term: "BT-104")?.value == "Versand")
        #expect(field(doc, term: "BG-20")?.element == "ram:SpecifiedTradeAllowanceCharge")
        #expect(field(doc, term: "BG-21")?.element == "ram:SpecifiedTradeAllowanceCharge")
        // Ein unbekannter Indikator ("vielleicht") bekommt KEINE Zuordnung —
        // sein Betrag darf weder als Nachlass noch als Zuschlag erscheinen.
        let unknownIndicatorAmount = doc.fields.first { $0.value == "7.00" }
        #expect(unknownIndicatorAmount?.term == nil)
        // Steuersumme: EUR = BT-110, Fremdwährung = BT-111
        #expect(field(doc, term: "BT-110")?.value == "18.62")
        #expect(field(doc, term: "BT-111")?.value == "17.90")

        let summary = doc.summary
        #expect(summary.invoiceNumber == "R-1")
        #expect(summary.issueDate == "2026-08-14")
        #expect(summary.sellerName == "Verkäufer GmbH")
        #expect(summary.payableAmount == "115.62")
        #expect(summary.currency == "EUR")
    }

    @Test("CII-Datumshilfe erzeugt nur für wirkliche Kalendertage ISO-Daten")
    func ciiDateNoteRejectsImpossibleCalendarDate() throws {
        let invalidDateXML = Self.ciiXML.replacingOccurrences(
            of: "20260814", with: "20260231")
        let doc = try EInvoiceReader.document(
            fromXML: Data(invalidDateXML.utf8), source: .xmlFile)

        #expect(field(doc, term: "BT-2")?.value == "20260231")
        #expect(field(doc, term: "BT-2")?.valueNote == nil)
        #expect(doc.summary.issueDate == "20260231")
    }

    // MARK: - UBL

    @Test("UBL-Rechnung: XRechnung-Profil und Feldzuordnung")
    func ublInvoice() throws {
        let doc = try EInvoiceReader.document(fromXML: Data(Self.ublXML.utf8), source: .xmlFile)
        #expect(doc.syntax == .ublInvoice)
        #expect(doc.profile.standard == "XRechnung")
        #expect(doc.profile.profile == "XRechnung 3.0")
        #expect(doc.profile.businessProcessID == "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0")

        #expect(field(doc, term: "BT-1")?.value == "UBL-7")
        #expect(field(doc, term: "BT-2")?.value == "2026-08-14")
        #expect(field(doc, term: "BT-10")?.value == "04011000-1234-56")
        #expect(field(doc, term: "BT-27")?.value == "Anbieterin e.K.")
        #expect(field(doc, term: "BT-31")?.value == "DE111111111")
        #expect(field(doc, term: "BT-44")?.value == "Kundin GmbH")
        #expect(field(doc, term: "BT-110")?.value == "19.00")
        #expect(field(doc, term: "BT-115")?.value == "119.00")
        #expect(field(doc, term: "BT-126")?.value == "1")
        #expect(field(doc, term: "BT-129")?.valueNote == "Stück (Einheit)")
        #expect(field(doc, term: "BT-153")?.value == "Dienstleistung")
        #expect(field(doc, term: "BT-146")?.value == "100.00")
        // Attribute mit eigener BT-Nummer: Einheiten und der Text zur
        // Zahlungsart (name-Attribut am Zahlungsart-Code).
        #expect(field(doc, term: "BT-129")?.attributeTerms
            == [EInvoiceAttributeTerm(attribute: "unitCode", term: "BT-130",
                                      termName: EN16931.name(for: "BT-130"))])
        #expect(field(doc, term: "BT-149")?.attributeTerms
            == [EInvoiceAttributeTerm(attribute: "unitCode", term: "BT-150",
                                      termName: EN16931.name(for: "BT-150"))])
        #expect(field(doc, term: "BT-81")?.attributeTerms
            == [EInvoiceAttributeTerm(attribute: "name", term: "BT-82",
                                      termName: EN16931.name(for: "BT-82"))])
        // Nachlass/Zuschlag mit den XML-Schema-Booleans 1/0.
        #expect(field(doc, term: "BG-21")?.element == "cac:AllowanceCharge")
        #expect(field(doc, term: "BT-104")?.value == "Versand")
        #expect(field(doc, term: "BG-20")?.element == "cac:AllowanceCharge")
        #expect(field(doc, term: "BT-97")?.value == "Treuerabatt")
        // Zusatz-Unterlagen: Typcode 130 = Rechnungsgegenstand (BT-18, kein
        // BG-24); ohne Typcode = rechnungsbegründende Unterlage (BG-24/BT-122).
        #expect(field(doc, term: "BT-18")?.value == "OBJ-1")
        #expect(field(doc, term: "BT-122")?.value == "BELEG-1")
        #expect(field(doc, term: "BT-123")?.value == "Stundenzettel")
        let bg24Containers = doc.fields.filter { $0.term == "BG-24" }
        #expect(bg24Containers.count == 1)
        let objectContainer = doc.fields.first {
            $0.element == "cac:AdditionalDocumentReference" && $0.term == nil
        }
        #expect(objectContainer != nil)
    }

    @Test("UBL-Gutschrift: CreditNote-Pfade werden auf Invoice-Terme normalisiert")
    func ublCreditNoteNormalizesPaths() throws {
        let doc = try EInvoiceReader.document(
            fromXML: Data(Self.ublCreditNoteXML.utf8), source: .xmlFile)
        #expect(doc.syntax == .ublCreditNote)
        #expect(doc.profile.standard == "Peppol BIS")
        #expect(field(doc, term: "BT-1")?.value == "G-9")
        #expect(field(doc, term: "BT-3")?.value == "381")
        #expect(field(doc, term: "BT-3")?.valueNote == "Gutschrift (Storno)")
        #expect(field(doc, term: "BG-25")?.element == "cac:CreditNoteLine")
        #expect(field(doc, term: "BT-129")?.value == "1")
        #expect(field(doc, term: "BT-153")?.value == "Rückvergütung")
    }

    // MARK: - Dokumentart und Bestellungen

    @Test("Dokumentart: Rechnung, Gutschrift (CII 381 und UBL CreditNote), Bestellung, Bestellantwort")
    func documentKinds() throws {
        func kind(_ xml: String) throws -> EInvoiceDocumentKind {
            try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile).documentKind
        }
        #expect(try kind(Self.ciiXML) == .invoice)
        #expect(try kind(Self.ublXML) == .invoice)
        #expect(try kind(Self.ciiCreditNoteXML) == .creditNote)
        #expect(try kind(Self.ublCreditNoteXML) == .creditNote)
        #expect(try kind(Self.orderXXML) == .order)
        #expect(try kind(Self.ublOrderXML) == .order)
        #expect(try kind(Self.ublOrderResponseXML) == .orderResponse)
        // Order-X-Bestellantwort: Typcode 231 in derselben Syntax.
        let response = Self.orderXXML.replacingOccurrences(
            of: "<r:TypeCode>220</r:TypeCode>", with: "<r:TypeCode>231</r:TypeCode>")
        #expect(try kind(response) == .orderResponse)
    }

    @Test("Order-X: Profil, Order-X-Bezeichnungen ohne BT-Nummer, Eckdaten, keine Warnungen")
    func orderXDocument() throws {
        let doc = try EInvoiceReader.document(fromXML: Data(Self.orderXXML.utf8), source: .xmlFile)
        #expect(doc.syntax == .ciiOrder)
        #expect(doc.profile.standard == "Order-X")
        #expect(doc.profile.profile == "COMFORT")
        #expect(doc.documentKind == .order)
        // Bestellungen haben keine EN-16931-Nummern: kein Feld trägt einen Term.
        #expect(doc.fields.allSatisfy { $0.term == nil })
        #expect(labeled(doc, "Bestellnummer")?.value == "B-2026-7")
        #expect(labeled(doc, "Bestelldatum")?.valueNote == "2026-09-01")
        #expect(labeled(doc, "Code für die Dokumentart")?.valueNote == "Bestellung")
        #expect(labeled(doc, "Käuferreferenz")?.value == "EINKAUF-1")
        #expect(labeled(doc, "Verkäufer: Name")?.value == "Lieferant KG")
        #expect(labeled(doc, "Käufer: Ort")?.value == "Berlin")
        #expect(labeled(doc, "Gewünschte Lieferung – Termin")?.valueNote == "2026-09-15")
        #expect(labeled(doc, "Bestellmenge")?.value == "500")
        #expect(labeled(doc, "Bestellmenge")?.valueNote == "Stück")
        #expect(labeled(doc, "Artikelname")?.value == "Schrauben M4")
        #expect(labeled(doc, "Zuschlag (Kopf) – Betrag")?.value == "4.90")
        #expect(labeled(doc, "Zuschlag (Kopf) – Grund")?.value == "Versand")
        #expect(labeled(doc, "Gesamtbetrag mit Umsatzsteuer")?.value == "65.33")

        #expect(doc.summary.invoiceNumber == "B-2026-7")
        #expect(doc.summary.issueDate == "2026-09-01")
        #expect(doc.summary.sellerName == "Lieferant KG")
        #expect(doc.summary.buyerName == "Besteller GmbH")
        #expect(doc.summary.currency == "EUR")
        #expect(doc.summary.payableAmount == "65.33")
        // Rechnungsregeln gelten nicht für Bestellungen.
        #expect(doc.warnings.isEmpty)
    }

    @Test("UBL Order und OrderResponse: Peppol-Profil und Bezeichnungen")
    func ublOrderDocuments() throws {
        let order = try EInvoiceReader.document(fromXML: Data(Self.ublOrderXML.utf8), source: .xmlFile)
        #expect(order.syntax == .ublOrder)
        #expect(order.profile.standard == "Peppol BIS")
        #expect(order.profile.profile == "Peppol BIS Order")
        #expect(order.profile.businessProcessID == "urn:fdc:peppol.eu:poacc:bis:ordering:3")
        #expect(order.fields.allSatisfy { $0.term == nil })
        #expect(labeled(order, "Bestellnummer")?.value == "PO-11")
        #expect(labeled(order, "Code für die Dokumentart")?.valueNote == "Bestellung")
        #expect(labeled(order, "Käufer: Name")?.value == "Besteller GmbH")
        #expect(labeled(order, "Verkäufer: Name")?.value == "Lieferant KG")
        #expect(labeled(order, "Bestellmenge")?.valueNote == "Stück")
        #expect(labeled(order, "Artikelname")?.value == "Schrauben M4")
        #expect(order.summary.payableAmount == "50.00")
        #expect(order.summary.sellerName == "Lieferant KG")
        #expect(order.warnings.isEmpty)

        let response = try EInvoiceReader.document(
            fromXML: Data(Self.ublOrderResponseXML.utf8), source: .xmlFile)
        #expect(response.syntax == .ublOrderResponse)
        #expect(response.documentKind == .orderResponse)
        #expect(response.profile.profile == "Peppol BIS Order Response")
        #expect(labeled(response, "Antwort-Code (Bestellantwort)")?.value == "AP")
        #expect(labeled(response, "Bestellnummer (Referenz)")?.value == "PO-11")
        #expect(response.summary.invoiceNumber == "AB-11")
    }

    // MARK: - Grundvalidierung

    @Test("CII-Gutschrift mit stimmiger Summenkette hat keine Hinweise")
    func creditNoteWithoutWarnings() throws {
        let doc = try EInvoiceReader.document(
            fromXML: Data(Self.ciiCreditNoteXML.utf8), source: .xmlFile)
        #expect(doc.documentKind == .creditNote)
        #expect(field(doc, term: "BT-3")?.valueNote == "Gutschrift (Storno)")
        #expect(doc.profile.profile == "BASIC")
        #expect(doc.warnings == [])
    }

    @Test("Summenprüfung: falscher Bruttobetrag meldet BR-CO-15 und BR-CO-16")
    func wrongSumWarnings() throws {
        let doc = try EInvoiceReader.document(
            fromXML: Data(Self.ciiWrongSumXML.utf8), source: .xmlFile)
        #expect(doc.warnings.map(\.code) == ["BR-CO-15", "BR-CO-16"])
        #expect(doc.warnings.map(\.term) == ["BT-112", "BT-115"])
        #expect(doc.warnings[0].message.contains("120.00"))
        #expect(doc.warnings[0].message.contains("116.62"))
        #expect(doc.warnings[0].message.contains("BT-109 + BT-110"))
    }

    @Test("Summenprüfung: Rundungsdifferenz bis 0,01 gilt nicht als Fehler")
    func sumToleranceOfOneCent() throws {
        let oneCentOff = Self.ciiCreditNoteXML.replacingOccurrences(
            of: "<ram:GrandTotalAmount>116.62</ram:GrandTotalAmount>",
            with: "<ram:GrandTotalAmount>116.63</ram:GrandTotalAmount>")
        let doc = try EInvoiceReader.document(fromXML: Data(oneCentOff.utf8), source: .xmlFile)
        // 116.63 gegen 116.62 (BT-112) und gegen 116.62 (BT-115): je 0.01 — toleriert.
        #expect(doc.warnings.isEmpty)

        let twoCentsOff = Self.ciiCreditNoteXML.replacingOccurrences(
            of: "<ram:GrandTotalAmount>116.62</ram:GrandTotalAmount>",
            with: "<ram:GrandTotalAmount>116.64</ram:GrandTotalAmount>")
        let doc2 = try EInvoiceReader.document(fromXML: Data(twoCentsOff.utf8), source: .xmlFile)
        #expect(doc2.warnings.map(\.code) == ["BR-CO-15", "BR-CO-16"])
    }

    @Test("Summenprüfung: Positionssumme und Steuersumme")
    func lineAndTaxSumWarnings() throws {
        // Position 100.00, aber BT-106 = 90.00 → BR-CO-10; die Folge-Regel
        // BR-CO-13 (BT-109 = BT-106 − BT-107 + BT-108) schlägt ebenfalls an.
        // Das LETZTE Vorkommen ist die Kopfsumme (die Position steht davor).
        let marker = "<ram:LineTotalAmount>100.00</ram:LineTotalAmount>"
        var wrongLines = Self.ciiCreditNoteXML
        let headerRange = try #require(wrongLines.range(of: marker, options: .backwards))
        wrongLines.replaceSubrange(headerRange, with: "<ram:LineTotalAmount>90.00</ram:LineTotalAmount>")
        let doc = try EInvoiceReader.document(fromXML: Data(wrongLines.utf8), source: .xmlFile)
        #expect(doc.warnings.map(\.code) == ["BR-CO-10", "BR-CO-13"])

        // Steuerbetrag der Kategorie (BT-117) passt nicht zur Steuersumme (BT-110).
        let wrongTax = Self.ciiCreditNoteXML.replacingOccurrences(
            of: "<ram:CalculatedAmount>18.62</ram:CalculatedAmount>",
            with: "<ram:CalculatedAmount>17.00</ram:CalculatedAmount>")
        let doc2 = try EInvoiceReader.document(fromXML: Data(wrongTax.utf8), source: .xmlFile)
        #expect(doc2.warnings.map(\.code) == ["BR-CO-14"])
        #expect(doc2.warnings.first?.term == "BT-110")
    }

    @Test("Pflichtfelder: fehlende Kopfangaben und Summen, bei XRechnung auch die Leitweg-ID")
    func missingRequiredFields() throws {
        let doc = try EInvoiceReader.document(
            fromXML: Data(Self.ciiMissingFieldsXML.utf8), source: .xmlFile)
        #expect(doc.profile.standard == "XRechnung")
        #expect(doc.warnings.map(\.code) == [
            "BR-02", "BR-03", "BR-04", "BR-05", "BR-06", "BR-07",
            "BR-12", "BR-13", "BR-14", "BR-15", "BR-DE-15",
        ])
        #expect(doc.warnings.map(\.term) == [
            "BT-1", "BT-2", "BT-3", "BT-5", "BT-27", "BT-44",
            "BT-106", "BT-109", "BT-112", "BT-115", "BT-10",
        ])
        #expect(doc.warnings.first?.message == "Pflichtfeld fehlt: BT-1 Rechnungsnummer")
        // Ohne XRechnung-Profil entfällt die Leitweg-ID-Regel.
        let plain = Self.ciiMissingFieldsXML.replacingOccurrences(
            of: "#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0", with: "")
        let doc2 = try EInvoiceReader.document(fromXML: Data(plain.utf8), source: .xmlFile)
        #expect(!doc2.warnings.contains { $0.code == "BR-DE-15" })
        #expect(doc2.warnings.count == 10)
    }

    @Test("Pflichtfeld BT-106 entfällt bei MINIMUM und BASIC WL (keine Positionen)")
    func minimumProfileSkipsLineTotal() throws {
        let minimum = Self.ciiMissingFieldsXML.replacingOccurrences(
            of: "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0",
            with: "urn:factur-x.eu:1p0:minimum")
        let doc = try EInvoiceReader.document(fromXML: Data(minimum.utf8), source: .xmlFile)
        #expect(!doc.warnings.contains { $0.term == "BT-106" })
        #expect(doc.warnings.contains { $0.term == "BT-115" })
    }

    @Test("Bestellungen und ZUGFeRD 1.0 bekommen keine Rechnungs-Hinweise")
    func ordersAndZUGFeRD1HaveNoWarnings() throws {
        let zugferd1 = """
        <?xml version="1.0"?>
        <rsm:CrossIndustryDocument xmlns:rsm="urn:ferd:CrossIndustryDocument:invoice:1p0"/>
        """
        for xml in [Self.orderXXML, Self.ublOrderXML, Self.ublOrderResponseXML, zugferd1] {
            let doc = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
            #expect(doc.warnings.isEmpty)
        }
    }

    @Test("Beträge: nur Dezimalpunkt-Zahlen sind lesbar")
    func amountParsing() {
        #expect(EInvoiceValidation.parseAmount("116.62") == Decimal(string: "116.62"))
        #expect(EInvoiceValidation.parseAmount(" -5.00 ") == Decimal(string: "-5.00"))
        #expect(EInvoiceValidation.parseAmount("1,5") == nil)
        #expect(EInvoiceValidation.parseAmount("1 000.00") == nil)
        #expect(EInvoiceValidation.parseAmount("EUR 5") == nil)
        for invalid in ["1.2.3", "1-2", "1+2", "--1", ".", "+", "-"] {
            #expect(EInvoiceValidation.parseAmount(invalid) == nil)
        }
        for valid in ["+5", ".50", "5.", "0", "-0.50"] {
            #expect(EInvoiceValidation.parseAmount(valid) == Decimal(string: valid))
        }
    }

    @Test("Unlesbare optionale Beträge werden nicht als null in Summen eingesetzt",
          arguments: ["BT-107", "BT-108", "BT-110", "BT-117"])
    func unreadableAmountsSkipDependentSums(_ term: String) throws {
        var document = try EInvoiceReader.document(
            fromXML: Data(Self.ciiCreditNoteXML.utf8), source: .xmlFile)
        let index = try #require(document.fields.firstIndex { $0.term == term })
        document.fields[index].value = "unlesbar"
        #expect(EInvoiceValidation.warnings(for: document).isEmpty)
    }

    // MARK: - Vollständigkeit

    @Test("Jedes XML-Element wird zu genau einem Anzeigefeld — nichts geht verloren")
    func everyElementBecomesAField() throws {
        for xml in [Self.ciiXML, Self.ublXML, Self.ublCreditNoteXML, Self.orderXXML,
                    Self.ublOrderXML, Self.ublOrderResponseXML, Self.ciiCreditNoteXML] {
            let doc = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
            // Elementzahl der Roh-Struktur: schließende Tags + selbstschließende.
            let elementCount = xml.components(separatedBy: "</").count - 1
                + xml.components(separatedBy: "/>").count - 1
            #expect(doc.fields.count == elementCount)
        }
    }
}
