// Tests des E-Rechnungs-Lesers: Erkennung, Profil-Auflösung, BT-Zuordnung
// für CII und UBL sowie die PDF-Extraktion. Die Fixtures sind bewusst
// selbstgeschriebene Minimal-Rechnungen — kein fremdes Material, keine
// echten Daten.
@testable import EInvoiceCore
import Foundation
import TagExplosionCore
import Testing

@Suite("EInvoice")
struct EInvoiceTests {

    // MARK: - Fixtures

    /// Minimale CII-Rechnung (EN-16931-Profil) mit den Sonderfällen, die die
    /// dynamische Zuordnung abdecken muss: Steuernummer UND USt-IdNr. beim
    /// Verkäufer, Nachlass + Zuschlag auf Dokumentenebene, Steuersumme in
    /// Fremdwährung. Absichtlich mit ungewöhnlichen Namensraum-Präfixen —
    /// die Zuordnung darf nur über die Namensraum-URIs laufen.
    private static let ciiXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <a:CrossIndustryInvoice
      xmlns:a="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      xmlns:b="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
      xmlns:c="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
      <a:ExchangedDocumentContext>
        <b:GuidelineSpecifiedDocumentContextParameter>
          <b:ID>urn:cen.eu:en16931:2017</b:ID>
        </b:GuidelineSpecifiedDocumentContextParameter>
      </a:ExchangedDocumentContext>
      <a:ExchangedDocument>
        <b:ID>R-1</b:ID>
        <b:TypeCode>380</b:TypeCode>
        <b:IssueDateTime><c:DateTimeString format="102">20260814</c:DateTimeString></b:IssueDateTime>
      </a:ExchangedDocument>
      <a:SupplyChainTradeTransaction>
        <b:IncludedSupplyChainTradeLineItem>
          <b:AssociatedDocumentLineDocument><b:LineID>1</b:LineID></b:AssociatedDocumentLineDocument>
          <b:SpecifiedTradeProduct><b:Name>Testartikel</b:Name></b:SpecifiedTradeProduct>
          <b:SpecifiedLineTradeAgreement>
            <b:NetPriceProductTradePrice>
              <b:ChargeAmount>49.50</b:ChargeAmount>
              <b:BasisQuantity unitCode="HUR">1</b:BasisQuantity>
            </b:NetPriceProductTradePrice>
          </b:SpecifiedLineTradeAgreement>
          <b:SpecifiedLineTradeDelivery>
            <b:BilledQuantity unitCode="HUR">2</b:BilledQuantity>
          </b:SpecifiedLineTradeDelivery>
          <b:SpecifiedLineTradeSettlement>
            <b:SpecifiedTradeAllowanceCharge>
              <b:ChargeIndicator><c:Indicator>false</c:Indicator></b:ChargeIndicator>
              <b:ActualAmount>1.00</b:ActualAmount>
            </b:SpecifiedTradeAllowanceCharge>
            <b:SpecifiedTradeSettlementLineMonetarySummation>
              <b:LineTotalAmount>99.00</b:LineTotalAmount>
            </b:SpecifiedTradeSettlementLineMonetarySummation>
          </b:SpecifiedLineTradeSettlement>
        </b:IncludedSupplyChainTradeLineItem>
        <b:ApplicableHeaderTradeAgreement>
          <b:SellerTradeParty>
            <b:Name>Verkäufer GmbH</b:Name>
            <b:SpecifiedTaxRegistration><b:ID schemeID="FC">1/23/456</b:ID></b:SpecifiedTaxRegistration>
            <b:SpecifiedTaxRegistration><b:ID schemeID="VA">DE999999999</b:ID></b:SpecifiedTaxRegistration>
          </b:SellerTradeParty>
          <b:BuyerTradeParty>
            <b:Name>Käufer AG</b:Name>
          </b:BuyerTradeParty>
        </b:ApplicableHeaderTradeAgreement>
        <b:ApplicableHeaderTradeDelivery/>
        <b:ApplicableHeaderTradeSettlement>
          <b:InvoiceCurrencyCode>EUR</b:InvoiceCurrencyCode>
          <b:SpecifiedTradeAllowanceCharge>
            <b:ChargeIndicator><c:Indicator>0</c:Indicator></b:ChargeIndicator>
            <b:ActualAmount>5.00</b:ActualAmount>
            <b:Reason>Treuerabatt</b:Reason>
          </b:SpecifiedTradeAllowanceCharge>
          <b:SpecifiedTradeAllowanceCharge>
            <b:ChargeIndicator><c:Indicator>1</c:Indicator></b:ChargeIndicator>
            <b:ActualAmount>3.00</b:ActualAmount>
            <b:Reason>Versand</b:Reason>
          </b:SpecifiedTradeAllowanceCharge>
          <b:SpecifiedTradeAllowanceCharge>
            <b:ChargeIndicator><c:Indicator>vielleicht</c:Indicator></b:ChargeIndicator>
            <b:ActualAmount>7.00</b:ActualAmount>
          </b:SpecifiedTradeAllowanceCharge>
          <b:SpecifiedTradeSettlementHeaderMonetarySummation>
            <b:TaxTotalAmount currencyID="EUR">18.62</b:TaxTotalAmount>
            <b:TaxTotalAmount currencyID="CHF">17.90</b:TaxTotalAmount>
            <b:GrandTotalAmount>115.62</b:GrandTotalAmount>
            <b:DuePayableAmount>115.62</b:DuePayableAmount>
          </b:SpecifiedTradeSettlementHeaderMonetarySummation>
        </b:ApplicableHeaderTradeSettlement>
      </a:SupplyChainTradeTransaction>
    </a:CrossIndustryInvoice>
    """

    /// Minimale UBL-Rechnung im XRechnung-3.0-Profil.
    private static let ublXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</cbc:CustomizationID>
      <cbc:ProfileID>urn:fdc:peppol.eu:2017:poacc:billing:01:1.0</cbc:ProfileID>
      <cbc:ID>UBL-7</cbc:ID>
      <cbc:IssueDate>2026-08-14</cbc:IssueDate>
      <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
      <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
      <cbc:BuyerReference>04011000-1234-56</cbc:BuyerReference>
      <cac:AccountingSupplierParty>
        <cac:Party>
          <cac:PartyTaxScheme>
            <cbc:CompanyID>DE111111111</cbc:CompanyID>
            <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
          </cac:PartyTaxScheme>
          <cac:PartyLegalEntity>
            <cbc:RegistrationName>Anbieterin e.K.</cbc:RegistrationName>
          </cac:PartyLegalEntity>
        </cac:Party>
      </cac:AccountingSupplierParty>
      <cac:AccountingCustomerParty>
        <cac:Party>
          <cac:PartyLegalEntity>
            <cbc:RegistrationName>Kundin GmbH</cbc:RegistrationName>
          </cac:PartyLegalEntity>
        </cac:Party>
      </cac:AccountingCustomerParty>
      <cac:AdditionalDocumentReference>
        <cbc:ID>OBJ-1</cbc:ID>
        <cbc:DocumentTypeCode>130</cbc:DocumentTypeCode>
      </cac:AdditionalDocumentReference>
      <cac:AdditionalDocumentReference>
        <cbc:ID>BELEG-1</cbc:ID>
        <cbc:DocumentDescription>Stundenzettel</cbc:DocumentDescription>
      </cac:AdditionalDocumentReference>
      <cac:PaymentMeans>
        <cbc:PaymentMeansCode name="Überweisung">30</cbc:PaymentMeansCode>
      </cac:PaymentMeans>
      <cac:AllowanceCharge>
        <cbc:ChargeIndicator>1</cbc:ChargeIndicator>
        <cbc:AllowanceChargeReason>Versand</cbc:AllowanceChargeReason>
        <cbc:Amount currencyID="EUR">3.00</cbc:Amount>
      </cac:AllowanceCharge>
      <cac:AllowanceCharge>
        <cbc:ChargeIndicator>0</cbc:ChargeIndicator>
        <cbc:AllowanceChargeReason>Treuerabatt</cbc:AllowanceChargeReason>
        <cbc:Amount currencyID="EUR">5.00</cbc:Amount>
      </cac:AllowanceCharge>
      <cac:TaxTotal>
        <cbc:TaxAmount currencyID="EUR">19.00</cbc:TaxAmount>
      </cac:TaxTotal>
      <cac:LegalMonetaryTotal>
        <cbc:PayableAmount currencyID="EUR">119.00</cbc:PayableAmount>
      </cac:LegalMonetaryTotal>
      <cac:InvoiceLine>
        <cbc:ID>1</cbc:ID>
        <cbc:InvoicedQuantity unitCode="C62">1</cbc:InvoicedQuantity>
        <cbc:LineExtensionAmount currencyID="EUR">100.00</cbc:LineExtensionAmount>
        <cac:Item><cbc:Name>Dienstleistung</cbc:Name></cac:Item>
        <cac:Price>
          <cbc:PriceAmount currencyID="EUR">100.00</cbc:PriceAmount>
          <cbc:BaseQuantity unitCode="C62">1</cbc:BaseQuantity>
        </cac:Price>
      </cac:InvoiceLine>
    </Invoice>
    """

    /// UBL-Gutschrift: prüft die Pfad-Normalisierung (CreditNote → Invoice).
    private static let ublCreditNoteXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CreditNote xmlns="urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
      <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0</cbc:CustomizationID>
      <cbc:ID>G-9</cbc:ID>
      <cbc:IssueDate>2026-08-01</cbc:IssueDate>
      <cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>
      <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
      <cac:CreditNoteLine>
        <cbc:ID>1</cbc:ID>
        <cbc:CreditedQuantity unitCode="C62">1</cbc:CreditedQuantity>
        <cac:Item><cbc:Name>Rückvergütung</cbc:Name></cac:Item>
      </cac:CreditNoteLine>
    </CreditNote>
    """

    // MARK: - Helfer

    private func field(_ doc: EInvoiceDocument, term: String) -> EInvoiceField? {
        doc.fields.first { $0.term == term }
    }

    /// Temporäres Verzeichnis für Dateien, die ein Test braucht.
    private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("einvoice-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    // MARK: - Erkennung

    @Test("Inhaltstest erkennt CII, UBL-Rechnung und UBL-Gutschrift")
    func sniffAcceptsInvoiceSyntaxes() {
        #expect(EInvoiceReader.sniffXML(Data(Self.ciiXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.ublXML.utf8)))
        #expect(EInvoiceReader.sniffXML(Data(Self.ublCreditNoteXML.utf8)))
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
        let xr30 = resolved("urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0")
        #expect(xr30.standard == "XRechnung")
        #expect(xr30.profile == "XRechnung 3.0")
        let xr23ext = resolved("urn:cen.eu:en16931:2017#conformant#urn:xoev-de:kosit:extension:xrechnung_2.3")
        #expect(xr23ext.profile == "XRechnung 2.3 (mit Extension)")
        #expect(resolved("urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0")
            .standard == "Peppol BIS")
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

    // MARK: - Vollständigkeit

    @Test("Jedes XML-Element wird zu genau einem Anzeigefeld — nichts geht verloren")
    func everyElementBecomesAField() throws {
        for xml in [Self.ciiXML, Self.ublXML, Self.ublCreditNoteXML] {
            let doc = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
            // Elementzahl der Roh-Struktur: schließende Tags + selbstschließende.
            let elementCount = xml.components(separatedBy: "</").count - 1
                + xml.components(separatedBy: "/>").count - 1
            #expect(doc.fields.count == elementCount)
        }
    }

    // MARK: - PDF

    @Test("PDF: eingebettete Rechnung samt XMP-Deklaration; PDF ohne Rechnung meldet Fehler")
    func pdfExtraction() throws {
        try withTempDirectory { dir in
            let pdfURL = dir.appendingPathComponent("rechnung.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8), fileName: "factur-x.xml")
                .write(to: pdfURL)

            let doc = try EInvoiceReader.read(url: pdfURL)
            #expect(doc.syntax == .cii)
            #expect(doc.source == .pdfEmbedded(fileName: "factur-x.xml"))
            #expect(doc.summary.invoiceNumber == "R-1")
            #expect(doc.pdfDeclaration?.conformanceLevel == "EN 16931")
            #expect(doc.pdfDeclaration?.documentFileName == "factur-x.xml")

            let plainURL = dir.appendingPathComponent("leer.pdf")
            try Self.makePDF(embedding: nil, fileName: nil).write(to: plainURL)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: plainURL)
            }
        }
    }

    @Test("XMP-Deklaration: Namensraum entscheidet, nicht das Präfix")
    func pdfDeclarationResolvesAttributeNamespaces() throws {
        try withTempDirectory { dir in
            // Kurzform (Werte als Attribute) mit frei gewähltem Präfix "inv":
            // muss erkannt werden, weil der Namensraum der Factur-X-URI ist.
            let customPrefix = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:inv="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
                  inv:DocumentFileName="factur-x.xml"
                  inv:ConformanceLevel="EN 16931"/>
              </rdf:RDF>
            </x:xmpmeta>
            """
            let customURL = dir.appendingPathComponent("custom-prefix.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8),
                             fileName: "factur-x.xml", xmp: customPrefix)
                .write(to: customURL)
            let doc = try EInvoiceReader.read(url: customURL)
            #expect(doc.pdfDeclaration?.documentFileName == "factur-x.xml")
            #expect(doc.pdfDeclaration?.conformanceLevel == "EN 16931")

            // Ein fremdes Schema darf auch dann KEINE Deklaration vortäuschen,
            // wenn seine URI den auffälligen Mittelteil des echten Namensraums
            // absichtlich übernimmt.
            let foreignNamespace = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:fx="urn:example:pdfa:CrossIndustryDocument:fake#"
                  fx:Version="99" fx:ConformanceLevel="FAKE"/>
              </rdf:RDF>
            </x:xmpmeta>
            """
            let foreignURL = dir.appendingPathComponent("foreign-prefix.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8),
                             fileName: "factur-x.xml", xmp: foreignNamespace)
                .write(to: foreignURL)
            let foreignDoc = try EInvoiceReader.read(url: foreignURL)
            #expect(foreignDoc.pdfDeclaration == nil)
        }
    }

    @Test("PDF: XMP-Dateiname gewinnt; ohne Deklaration bleibt die Anhangsreihenfolge")
    func pdfCandidateOrderFollowsDeclarationAndPDF() throws {
        try withTempDirectory { dir in
            let declaredXML = Self.ciiXML.replacingOccurrences(of: "R-1", with: "R-XMP")
            let declaredXMP = Self.invoiceXMP(fileName: "declared.xml")
            let declaredURL = dir.appendingPathComponent("declared.pdf")
            try Self.makePDF(embeddings: [
                (Data(Self.ciiXML.utf8), "factur-x.xml"),
                (Data(declaredXML.utf8), "declared.xml"),
            ], xmp: declaredXMP).write(to: declaredURL)

            let declared = try EInvoiceReader.read(url: declaredURL)
            #expect(declared.source == .pdfEmbedded(fileName: "declared.xml"))
            #expect(declared.summary.invoiceNumber == "R-XMP")

            let firstXML = Self.ciiXML.replacingOccurrences(of: "R-1", with: "R-FIRST")
            let secondXML = Self.ciiXML.replacingOccurrences(of: "R-1", with: "R-SECOND")
            let orderedURL = dir.appendingPathComponent("ordered.pdf")
            try Self.makePDF(embeddings: [
                (Data(firstXML.utf8), "zuerst.xml"),
                (Data(secondXML.utf8), "alphabetisch-frueher.xml"),
            ], xmp: Self.foreignXMP).write(to: orderedURL)

            let ordered = try EInvoiceReader.read(url: orderedURL)
            #expect(ordered.source == .pdfEmbedded(fileName: "zuerst.xml"))
            #expect(ordered.summary.invoiceNumber == "R-FIRST")
        }
    }

    @Test("PDF: Rechnung im AF-Array gewinnt gegen einen gefluteten Namensbaum")
    func pdfAFInvoiceSurvivesFloodedNameTree() throws {
        try withTempDirectory { dir in
            // 33 fremde XML-Anhänge im Namensbaum liegen ÜBER dem Dateibudget
            // (32); die echte Rechnung steht nur im AF-Array — genau dort, wo
            // ZUGFeRD/Factur-X sie verlangen. Sie muss trotzdem gefunden werden.
            let url = dir.appendingPathComponent("geflutet-af.pdf")
            try Self.makeFloodedPDF(junkCount: 33, invoiceViaAF: true, xmp: nil)
                .write(to: url)
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.source == .pdfEmbedded(fileName: "factur-x.xml"))
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Die XMP-deklarierte Datei bekommt einen reservierten Budget-Platz")
    func pdfDeclaredFileBypassesFileBudget() throws {
        try withTempDirectory { dir in
            // Kein AF-Array; die deklarierte Rechnung steht als LETZTER von 34
            // Namensbaum-Einträgen, hinter 33 fremden XMLs. Der reservierte
            // Platz für die deklarierte Datei muss sie trotzdem aufnehmen.
            let url = dir.appendingPathComponent("geflutet-deklariert.pdf")
            try Self.makeFloodedPDF(junkCount: 33, invoiceViaAF: false,
                                    xmp: Self.invoiceXMP(fileName: "factur-x.xml"))
                .write(to: url)
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.source == .pdfEmbedded(fileName: "factur-x.xml"))
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Ein sich selbst referenzierender Namensbaum blockiert nicht",
          .timeLimit(.minutes(1)))
    func pdfCyclicNameTreeTerminates() throws {
        try withTempDirectory { dir in
            // Objekt 4 verweist unter /Kids ZWEIMAL auf sich selbst: Mit einer
            // reinen Tiefengrenze (32) wären das 2^32 Besuche. Das
            // Knoten-Budget bricht die Wanderung ab; die Rechnung im AF-Array
            // muss trotzdem gefunden werden.
            let xml = Self.ciiXML
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 4 0 R >> /AF [ 6 0 R ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Kids [ 4 0 R 4 0 R ] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) /EF << /F 5 0 R /UF 5 0 R >> >>",
            ]
            let url = dir.appendingPathComponent("zyklus.pdf")
            try Self.assemblePDF(objects: objects).write(to: url)
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: überlange, kaskadierte oder Überlauf ankündigende Streams werden übersprungen")
    func pdfOversizedStreamsAreSkipped() throws {
        try withTempDirectory { dir in
            // CGPDFStreamCopyData dekomprimiert immer vollständig im Speicher.
            // Die Vorprüfung muss solche Streams deshalb VOR dem Entpacken
            // aussortieren; ohne verwertbaren Anhang ist das Ergebnis ehrlich
            // "keine E-Rechnung".
            let xml = Self.ciiXML
            func poisonedPDF(streamDict: String) -> Data {
                Self.assemblePDF(objects: [
                    "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles "
                        + "<< /Names [ (factur-x.xml) 5 0 R ] >> >> /AF [ 5 0 R ] >>",
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                    "\(streamDict)\nstream\n\(xml)\nendstream",
                    "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                        + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                ])
            }
            // Deklarierte Größe über dem Gesamtbudget (64 MiB) …
            let lengthLie = dir.appendingPathComponent("laenge.pdf")
            try poisonedPDF(streamDict: "<< /Type /EmbeddedFile /Length 104857600 >>")
                .write(to: lengthLie)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: lengthLie)
            }
            // … kaskadierte Filter (potenzierte Entpackungsrate) …
            let chain = dir.appendingPathComponent("filterkette.pdf")
            try poisonedPDF(streamDict: "<< /Type /EmbeddedFile /Length \(xml.utf8.count) "
                + "/Filter [ /FlateDecode /FlateDecode ] >>").write(to: chain)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: chain)
            }
            // … und ein angekündigtes Entpackungs-Volumen über dem Gesamtbudget.
            let sizeLie = dir.appendingPathComponent("params.pdf")
            try poisonedPDF(streamDict: "<< /Type /EmbeddedFile /Length \(xml.utf8.count) "
                + "/Params << /Size 104857600 >> >>").write(to: sizeLie)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: sizeLie)
            }
        }
    }

    // MARK: - Review-Fund 2026-08-18

#if canImport(CoreGraphics)
    @Test("PDF: Auch verworfene Anhaenge verbrauchen das Entpack-Budget")
    func pdfDroppedAttachmentsConsumeBudget() throws {
        try withTempDirectory { dir in
            // Ein Anhang, der das Budget sprengt, wird nicht uebernommen —
            // entpackt (und damit im Speicher materialisiert) war er trotzdem.
            // Zaehlte nur das Behaltene, durfte dieselbe Dekompressionsbombe
            // beliebig oft im Namensbaum stehen und die App lange beschaeftigen
            // (Review-Fund 2026-08-18). Das Budget ist hier klein gesetzt, damit
            // der Test ohne 64-MiB-Fixture auskommt.
            let filler = Data(String(repeating: "a", count: 600).utf8)
            let url = dir.appendingPathComponent("budget.pdf")
            try Self.makePDF(embeddings: [
                (filler, "fuell-1.xml"),
                (filler, "fuell-2.xml"),
                (Data(String(repeating: "b", count: 100).utf8), "spaet.xml"),
            ]).write(to: url)

            let extraction = try PDFEmbeddedInvoice.extract(url: url, byteBudget: 1000)

            // fuell-2 sprengt das Anzeigebudget und wird verworfen — die Suche
            // laeuft aber weiter, und „spaet" passt noch hinein.
            #expect(extraction.files.map(\.name) == ["fuell-1.xml", "spaet.xml"])
        }
    }
#endif

    // MARK: - Review-Fund 2026-08-20

#if canImport(CoreGraphics)
    @Test("PDF: Ein zu grosser Anhang beendet die Suche nach der Rechnung nicht")
    func pdfOversizedAttachmentDoesNotHideInvoice() throws {
        try withTempDirectory { dir in
            // Der Angriff: EIN Fuellanhang, der allein das Anzeigebudget
            // sprengt, VOR der deklarierten Rechnung. Zaehlte die Entpackarbeit
            // gegen dasselbe Budget, war danach jeder weitere Kandidat gesperrt
            // — die Datei galt als „keine E-Rechnung", waehrend andere Leser
            // dieselbe Rechnung anzeigten (Review-Fund 2026-08-20).
            let url = dir.appendingPathComponent("versteckt.pdf")
            try Self.makePDF(embeddings: [
                (Data(String(repeating: "a", count: 4000).utf8), "fuell-1.xml"),
                (Data(String(repeating: "b", count: 4500).utf8), "fuell-2.xml"),
                (Data(Self.ciiXML.utf8), "factur-x.xml"),
            ]).write(to: url)

            // fuell-2 wird entpackt und dann verworfen; danach liegt die
            // Entpackmenge (8500) ueber dem Anzeigebudget (8000) — genau der
            // Zustand, der frueher jede weitere Suche abwuergte.
            let extraction = try PDFEmbeddedInvoice.extract(url: url, byteBudget: 8000)
            #expect(extraction.files.map(\.name) == ["fuell-1.xml", "factur-x.xml"])

            let document = try EInvoiceReader.read(url: url)
            #expect(document.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Derselbe Stream unter vielen Namen erschoepft das Arbeitsbudget")
    func pdfRepeatedStreamHitsWorkBudget() throws {
        try withTempDirectory { dir in
            // Wiederholungsschutz: Ein Filespec-Array, das vielfach auf
            // denselben grossen Stream zeigt, jeweils unter einem anderen Namen.
            // `seenNames` greift hier nicht — nur das Arbeitsbudget begrenzt,
            // wie oft entpackt wird.
            let payload = String(repeating: "a", count: 600)
            var objects: [String] = [
                "KATALOG-PLATZHALTER",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(payload.utf8.count) >>\nstream\n"
                    + payload + "\nendstream",
            ]
            let streamID = 4
            var af: [String] = []
            for i in 1...20 {
                objects.append("<< /Type /Filespec /F (kopie-\(i).xml) /UF (kopie-\(i).xml) "
                    + "/EF << /F \(streamID) 0 R /UF \(streamID) 0 R >> >>")
                af.append("\(objects.count) 0 R")
            }
            // Ein kleiner Anhang GANZ am Ende: Er passte ins Anzeigebudget,
            // darf aber nicht mehr erreicht werden.
            let spaet = "<klein/>"
            objects.append("<< /Type /EmbeddedFile /Length \(spaet.utf8.count) >>\nstream\n"
                + spaet + "\nendstream")
            let spaetStreamID = objects.count
            objects.append("<< /Type /Filespec /F (spaet.xml) /UF (spaet.xml) "
                + "/EF << /F \(spaetStreamID) 0 R /UF \(spaetStreamID) 0 R >> >>")
            af.append("\(objects.count) 0 R")
            objects[0] = "<< /Type /Catalog /Pages 2 0 R /AF [ \(af.joined(separator: " ")) ] >>"
            let url = dir.appendingPathComponent("wiederholung.pdf")
            try Self.assemblePDF(objects: objects).write(to: url)

            let extraction = try PDFEmbeddedInvoice.extract(url: url, byteBudget: 1000)

            // Behalten wird nur, was ins Anzeigebudget passt — und nach dem
            // Vierfachen an Entpackarbeit (sieben der zwanzig Kopien) endet die
            // Suche, „spaet.xml" wird nicht mehr erreicht.
            #expect(extraction.files.map(\.name) == ["kopie-1.xml"])
        }
    }

    @Test("PDF: Eine unkomprimiert eingebettete Rechnung ueber 256 KiB bleibt lesbar")
    func pdfLargeUncompressedInvoiceIsRead() throws {
        try withTempDirectory { dir in
            // /Length ist bei einem Stream OHNE /Filter bereits die entpackte
            // Groesse; die Bomben-Schranke von 256 KiB gehoert dort nicht hin.
            // Factur-X schreibt keine Kompression vor, und eine Rechnung mit
            // vielen Positionen wird unkomprimiert schnell groesser
            // (Review-Fund 2026-08-20).
            let padding = String(repeating: " ", count: 300 * 1024)
            let big = Self.ciiXML + "\n<!--" + padding + "-->"
            #expect(big.utf8.count > PDFEmbeddedInvoice.maxCompressedBytes)
            let url = dir.appendingPathComponent("gross-unkomprimiert.pdf")
            try Self.makePDF(embedding: Data(big.utf8), fileName: "factur-x.xml").write(to: url)

            let document = try EInvoiceReader.read(url: url)
            #expect(document.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Ein angekuendigtes /Params/Size ueber dem uebergebenen Budget zaehlt")
    func pdfParamsSizeUsesPassedBudget() throws {
        try withTempDirectory { dir in
            // Frueher pruefte dieser Pfad gegen die Konstante statt gegen das
            // uebergebene Budget — ein Test mit kleinem Budget beruehrte ihn
            // deshalb nie (Review-Fund 2026-08-20).
            let xml = Self.ciiXML
            let url = dir.appendingPathComponent("params-klein.pdf")
            try Self.assemblePDF(objects: [
                "<< /Type /Catalog /Pages 2 0 R /AF [ 5 0 R ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) "
                    + "/Params << /Size 5000 >> >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                    + "/EF << /F 4 0 R /UF 4 0 R >> >>",
            ]).write(to: url)

            // Mit grossem Budget lesbar …
            #expect(try PDFEmbeddedInvoice.extract(url: url).files.count == 1)
            // … mit einem Budget unter der angekuendigten Groesse nicht.
            #expect(try PDFEmbeddedInvoice.extract(url: url, byteBudget: 1000).files.isEmpty)
        }
    }
#endif

    // MARK: - Review-Fund 2026-08-17

    @Test("PDF: Ein Anhangs-Stream ohne gueltige /Length wird uebersprungen")
    func pdfStreamWithoutLengthIsSkipped() throws {
        try withTempDirectory { dir in
            // Fehlte die Laengenangabe oder war sie keine Ganzzahl, liess die
            // Vorpruefung den Stream einfach durch — er umging damit jede
            // Groessenschranke, obwohl CGPDFStreamCopyData ihn vollstaendig im
            // Speicher materialisiert.
            let xml = Self.ciiXML
            func pdf(streamDict: String) -> Data {
                Self.assemblePDF(objects: [
                    "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles "
                        + "<< /Names [ (factur-x.xml) 5 0 R ] >> >> /AF [ 5 0 R ] >>",
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                    "\(streamDict)\nstream\n\(xml)\nendstream",
                    "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                        + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                ])
            }
            // Gar keine /Length …
            let ohneLaenge = dir.appendingPathComponent("ohne-laenge.pdf")
            try pdf(streamDict: "<< /Type /EmbeddedFile >>").write(to: ohneLaenge)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: ohneLaenge)
            }
            // … und eine /Length von 0 (unehrliche Angabe).
            let nullLaenge = dir.appendingPathComponent("null-laenge.pdf")
            try pdf(streamDict: "<< /Type /EmbeddedFile /Length 0 >>").write(to: nullLaenge)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: nullLaenge)
            }
        }
    }

    @Test("PDF: Ein uebergrosser XMP-Metadatenstrom wird gar nicht erst gelesen")
    func pdfOversizedMetadataIsSkipped() throws {
        try withTempDirectory { dir in
            // `readDeclaration` las den /Metadata-Strom vorher OHNE jede
            // Schranke und baute daraus einen vollstaendigen XML-Baum — schon
            // das blosse Oeffnen eines PDFs war damit angreifbar. Der Inhalt
            // hier ist eine gueltige Factur-X-Deklaration, die deklarierte
            // Laenge liegt aber ueber der XMP-Schranke: Wird der Strom
            // uebersprungen, fehlt die Deklaration — genau der beobachtbare
            // Unterschied. Der Anhang selbst bleibt lesbar.
            let xml = Self.ciiXML
            let xmp = Self.invoiceXMP(fileName: "factur-x.xml")
            let url = dir.appendingPathComponent("xmp-bombe.pdf")
            try Self.assemblePDF(objects: [
                "<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R /Names << /EmbeddedFiles "
                    + "<< /Names [ (factur-x.xml) 5 0 R ] >> >> /AF [ 5 0 R ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                    + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                "<< /Type /Metadata /Subtype /XML /Length 9437184 >>\nstream\n\(xmp)\nendstream",
            ]).write(to: url)

            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.pdfDeclaration == nil,
                    "Ein Metadatenstrom ueber der Schranke darf nicht gelesen werden.")
            // Die Rechnung wird trotzdem ueber den Anhang gefunden.
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Ein breites /AF-Array bleibt im Arbeitsbudget", .timeLimit(.minutes(1)))
    func pdfWideAFArrayTerminates() throws {
        try withTempDirectory { dir in
            // Waechter fuer das gemeinsame Arbeitsbudget (Review-Fund
            // 2026-08-17): Das Knotenbudget zaehlte nur rekursive Dictionaries,
            // ein breites /AF-Array lief trotzdem vollstaendig durch. Dieser
            // Test faellt nicht gegen den alten Stand — er haelt fest, dass die
            // Rechnung trotz Budgetgrenze weiterhin gefunden wird, damit die
            // Grenze nicht heimlich wieder verschwindet oder zu eng wird.
            let xml = Self.ciiXML
            let verweise = Array(repeating: "6 0 R", count: 40_000).joined(separator: " ")
            let url = dir.appendingPathComponent("breites-af.pdf")
            try Self.assemblePDF(objects: [
                "<< /Type /Catalog /Pages 2 0 R /AF [ 5 0 R \(verweise) ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                    + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                "<< /Type /Filespec /F (fuell.xml) /UF (fuell.xml) >>",
            ]).write(to: url)

            // Die echte Rechnung steht vorn und wird trotzdem gefunden.
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    /// Baut ein minimales, gültiges PDF — optional mit eingebetteten Dateien
    /// (Namensbaum + AF-Array wie bei ZUGFeRD) und Factur-X-XMP-Deklaration
    /// (überschreibbar, um Präfix-/Namensraum-Varianten zu testen).
    /// Handgeschrieben statt Bibliothek: Der Test soll genau die Strukturen
    /// erzeugen, die der Leser abläuft.
    private static func makePDF(embedding payload: Data?, fileName: String?,
                                xmp customXMP: String? = nil) -> Data {
        let embeddings: [(Data, String)]
        if let payload, let fileName {
            embeddings = [(payload, fileName)]
        } else {
            embeddings = []
        }
        return makePDF(embeddings: embeddings, xmp: customXMP)
    }

    private static func makePDF(embeddings: [(payload: Data, fileName: String)],
                                xmp customXMP: String? = nil) -> Data {
        var objects: [String] = []
        let xmp = customXMP ?? invoiceXMP(fileName: "factur-x.xml")

        if !embeddings.isEmpty {
            let filespecIDs = embeddings.indices.map { 5 + $0 * 2 }
            let names = zip(embeddings, filespecIDs).map {
                "(\($0.0.fileName)) \($0.1) 0 R"
            }.joined(separator: " ")
            let af = filespecIDs.map { "\($0) 0 R" }.joined(separator: " ")
            let metadataID = 4 + embeddings.count * 2
            objects.append("""
            << /Type /Catalog /Pages 2 0 R /Metadata \(metadataID) 0 R \
            /Names << /EmbeddedFiles << /Names [ \(names) ] >> >> \
            /AF [ \(af) ] >>
            """)
            objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")

            for embedding in embeddings {
                let streamID = objects.count + 1
                objects.append("<< /Type /EmbeddedFile /Length \(embedding.payload.count) >>\nstream\n"
                    + String(decoding: embedding.payload, as: UTF8.self) + "\nendstream")
                objects.append("""
                << /Type /Filespec /F (\(embedding.fileName)) /UF (\(embedding.fileName)) \
                /AFRelationship /Alternative /EF << /F \(streamID) 0 R \
                /UF \(streamID) 0 R >> >>
                """)
            }
            objects.append("<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n"
                + xmp + "\nendstream")
        } else {
            objects.append("<< /Type /Catalog /Pages 2 0 R >>")
            objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
        }

        return assemblePDF(objects: objects)
    }

    /// PDF mit `junkCount` fremden XML-Anhängen im Namensbaum und einer
    /// echten Rechnung, die je nach Test NUR im AF-Array oder als LETZTER
    /// Namensbaum-Eintrag steht — die Flutungs-Szenarien gegen das Dateibudget.
    private static func makeFloodedPDF(junkCount: Int, invoiceViaAF: Bool,
                                       xmp customXMP: String?) -> Data {
        var objects: [String] = []
        func addObject(_ body: String) -> Int {
            objects.append(body)
            return objects.count // Objektnummern sind 1-basiert
        }
        // Katalog zuerst reservieren (Objekt 1); er braucht die erst später
        // bekannten Verweise und wird am Ende ersetzt.
        _ = addObject("KATALOG-PLATZHALTER")
        _ = addObject("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        _ = addObject("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")

        func addAttachment(payload: String, name: String) -> Int {
            let streamID = addObject(
                "<< /Type /EmbeddedFile /Length \(payload.utf8.count) >>\nstream\n"
                    + payload + "\nendstream")
            return addObject("<< /Type /Filespec /F (\(name)) /UF (\(name)) "
                + "/EF << /F \(streamID) 0 R /UF \(streamID) 0 R >> >>")
        }

        var nameEntries: [String] = []
        for i in 1...junkCount {
            let id = addAttachment(payload: "<fremd-\(i)/>", name: "fremd-\(i).xml")
            nameEntries.append("(fremd-\(i).xml) \(id) 0 R")
        }
        let invoiceID = addAttachment(payload: ciiXML, name: "factur-x.xml")
        var af = ""
        if invoiceViaAF {
            af = " /AF [ \(invoiceID) 0 R ]"
        } else {
            nameEntries.append("(factur-x.xml) \(invoiceID) 0 R")
        }
        var metadata = ""
        if let customXMP {
            let id = addObject("<< /Type /Metadata /Subtype /XML /Length "
                + "\(customXMP.utf8.count) >>\nstream\n" + customXMP + "\nendstream")
            metadata = " /Metadata \(id) 0 R"
        }
        objects[0] = "<< /Type /Catalog /Pages 2 0 R\(metadata) /Names "
            + "<< /EmbeddedFiles << /Names [ \(nameEntries.joined(separator: " ")) ] >> >>\(af) >>"
        return assemblePDF(objects: objects)
    }

    /// Setzt nummerierte Objekte (1 = Katalog) zu einem PDF mit korrekter
    /// xref-Tabelle zusammen. Getrennt von makePDF, damit Tests auch bewusst
    /// präparierte Strukturen (Zyklen, gelogene Stream-Größen) bauen können.
    private static func assemblePDF(objects: [String]) -> Data {
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private static func invoiceXMP(fileName: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#">
              <fx:DocumentType>INVOICE</fx:DocumentType>
              <fx:DocumentFileName>\(fileName)</fx:DocumentFileName>
              <fx:Version>1.0</fx:Version>
              <fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private static let foreignXMP = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:other="urn:example:metadata"
          other:DocumentFileName="zuerst.xml"/>
      </rdf:RDF>
    </x:xmpmeta>
    """
}
