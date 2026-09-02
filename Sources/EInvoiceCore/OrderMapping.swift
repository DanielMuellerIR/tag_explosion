// Feldbezeichnungen für Bestellungen: Order-X (UN/CEFACT Cross Industry
// Order, Wurzel rsm:SCRDMCCBDACIOMessageStructure) und Peppol BIS Ordering
// (UBL Order / OrderResponse).
//
// Bestellungen folgen nicht der EN 16931, es gibt für sie keine BT-Nummern.
// Damit die Anzeige trotzdem lesbar ist, bekommt jedes bekannte Element eine
// deutsche Order-X-Bezeichnung als Feldname (`termName`), aber KEINE
// Nummer (`term` bleibt nil). Unbekannte Elemente bleiben wie bei Rechnungen
// als Rohpfad sichtbar — nie Felder verschlucken, nie falsch benennen.
import Foundation

/// Bezeichnungen, die der Leser wiedererkennen muss (Zusammenfassung,
/// Code-Erläuterungen). Alle übrigen Bezeichnungen stehen nur in den Tabellen.
enum OrderTerms {
    static let number = "Bestellnummer"
    static let date = "Bestelldatum"
    static let typeCode = "Code für die Dokumentart"
    static let currency = "Code für die Bestellwährung"
    static let seller = "Verkäufer"
    static let buyer = "Käufer"
    static let vatCategory = "Code der Umsatzsteuerkategorie"
    static let grandTotal = "Gesamtbetrag mit Umsatzsteuer"
    static let payableAmount = "Fälliger Betrag"
}

/// Gemeinsame Bausteine beider Syntaxen.
private enum OrderLabels {
    /// Gesamtsummen — Order-X und UBL benennen die Elemente verschieden,
    /// meinen aber dieselben Summen.
    static let lineTotal = "Summe der Positionsbeträge (netto)"
    static let chargeTotal = "Summe der Zuschläge"
    static let allowanceTotal = "Summe der Nachlässe"
    static let taxBasisTotal = "Gesamtbetrag ohne Umsatzsteuer"
    static let taxTotal = "Gesamtbetrag der Umsatzsteuer"
    static let prepaid = "Vorausgezahlter Betrag"
    static let rounding = "Rundungsbetrag"

    /// Nachlass oder Zuschlag: Kopf- und Positionsebene, je Richtung.
    static func allowanceCharge(isCharge: Bool, isLine: Bool) -> String {
        (isCharge ? "Zuschlag" : "Nachlass") + (isLine ? " (Position)" : " (Kopf)")
    }
}

// MARK: - Order-X (CIO)

enum OrderXMapping {

    static let root = "rsm:SCRDMCCBDACIOMessageStructure"
    private static let ctx = "\(root)/rsm:ExchangedDocumentContext"
    private static let doc = "\(root)/rsm:ExchangedDocument"
    private static let tx = "\(root)/rsm:SupplyChainTradeTransaction"
    private static let agr = "\(tx)/ram:ApplicableHeaderTradeAgreement"
    private static let del = "\(tx)/ram:ApplicableHeaderTradeDelivery"
    private static let set = "\(tx)/ram:ApplicableHeaderTradeSettlement"
    private static let line = "\(tx)/ram:IncludedSupplyChainTradeLineItem"

    /// Beteiligte (Trade Parties) mit ihrer Rolle. Ihre Unterelemente werden
    /// generisch als "Rolle: Feld" beschriftet (siehe `partyFields`).
    static let parties: [String: String] = [
        "ram:SellerTradeParty": OrderTerms.seller,
        "ram:BuyerTradeParty": OrderTerms.buyer,
        "ram:BuyerRequisitionerTradeParty": "Bedarfsträger",
        "ram:ShipToTradeParty": "Warenempfänger",
        "ram:ShipFromTradeParty": "Versender",
        "ram:InvoiceeTradeParty": "Rechnungsempfänger",
        "ram:ProductEndUserTradeParty": "Endkunde",
        "ram:ManufacturerTradeParty": "Hersteller",
    ]

    /// Relativer Pfad innerhalb eines Beteiligten → Feldname.
    static let partyFields: [String: String] = [
        "ram:ID": "Kennung",
        "ram:GlobalID": "Globale Kennung",
        "ram:Name": "Name",
        "ram:Description": "Beschreibung",
        "ram:SpecifiedLegalOrganization": "Rechtliche Organisation",
        "ram:SpecifiedLegalOrganization/ram:ID": "Registernummer",
        "ram:SpecifiedLegalOrganization/ram:TradingBusinessName": "Handelsname",
        "ram:DefinedTradeContact": "Kontakt",
        "ram:DefinedTradeContact/ram:PersonName": "Ansprechpartner",
        "ram:DefinedTradeContact/ram:DepartmentName": "Abteilung",
        "ram:DefinedTradeContact/ram:TelephoneUniversalCommunication/ram:CompleteNumber": "Telefon",
        "ram:DefinedTradeContact/ram:FaxUniversalCommunication/ram:CompleteNumber": "Fax",
        "ram:DefinedTradeContact/ram:EmailURIUniversalCommunication/ram:URIID": "E-Mail",
        "ram:PostalTradeAddress": "Postanschrift",
        "ram:PostalTradeAddress/ram:PostcodeCode": "Postleitzahl",
        "ram:PostalTradeAddress/ram:LineOne": "Adresszeile 1",
        "ram:PostalTradeAddress/ram:LineTwo": "Adresszeile 2",
        "ram:PostalTradeAddress/ram:LineThree": "Adresszeile 3",
        "ram:PostalTradeAddress/ram:CityName": "Ort",
        "ram:PostalTradeAddress/ram:CountryID": "Ländercode",
        "ram:PostalTradeAddress/ram:CountrySubDivisionName": "Region",
        "ram:URIUniversalCommunication/ram:URIID": "Elektronische Adresse",
        "ram:SpecifiedTaxRegistration/ram:ID": "Steuerregistrierung (USt-IdNr./Steuernummer)",
    ]

    /// Feste Pfade → Bezeichnung.
    static let fixed: [String: String] = {
        var map: [String: String] = [:]

        // --- Prozesssteuerung
        map[ctx] = "Prozesssteuerung"
        map["\(ctx)/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID"] = "Geschäftsprozess"
        map["\(ctx)/ram:GuidelineSpecifiedDocumentContextParameter/ram:ID"] = "Spezifikationskennung (Order-X-Profil)"
        map["\(ctx)/ram:TestIndicator/udt:Indicator"] = "Testkennzeichen"

        // --- Dokumentkopf
        map[doc] = "Dokumentkopf"
        map["\(doc)/ram:ID"] = OrderTerms.number
        map["\(doc)/ram:Name"] = "Dokumentname"
        map["\(doc)/ram:TypeCode"] = OrderTerms.typeCode
        map["\(doc)/ram:StatusCode"] = "Dokumentstatus"
        map["\(doc)/ram:IssueDateTime/udt:DateTimeString"] = OrderTerms.date
        map["\(doc)/ram:CopyIndicator/udt:Indicator"] = "Kopie-Kennzeichen"
        map["\(doc)/ram:PurposeCode"] = "Verwendungszweck-Code"
        map["\(doc)/ram:RequestedResponseTypeCode"] = "Gewünschte Antwortart"
        map["\(doc)/ram:IncludedNote"] = "Anmerkung"
        map["\(doc)/ram:IncludedNote/ram:Content"] = "Anmerkungstext"
        map["\(doc)/ram:IncludedNote/ram:SubjectCode"] = "Betreff-Code"
        map["\(doc)/ram:EffectiveSpecifiedPeriod"] = "Gültigkeitszeitraum"
        map["\(doc)/ram:EffectiveSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString"] = "Gültig ab"
        map["\(doc)/ram:EffectiveSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString"] = "Gültig bis"

        // --- Vereinbarung (Kopf)
        map[tx] = "Transaktion"
        map[agr] = "Vereinbarung (Kopf)"
        map["\(agr)/ram:BuyerReference"] = "Käuferreferenz"
        map["\(agr)/ram:ApplicableTradeDeliveryTerms"] = "Lieferbedingungen"
        map["\(agr)/ram:ApplicableTradeDeliveryTerms/ram:DeliveryTypeCode"] = "Lieferbedingungs-Code (Incoterm)"
        map["\(agr)/ram:ApplicableTradeDeliveryTerms/ram:Description"] = "Lieferbedingungen (Text)"
        map["\(agr)/ram:ApplicableTradeDeliveryTerms/ram:FunctionCode"] = "Lieferbedingungs-Funktion"
        map["\(agr)/ram:ApplicableTradeDeliveryTerms/ram:RelevantTradeLocation/ram:ID"] = "Lieferbedingungs-Ort (Kennung)"
        map["\(agr)/ram:ApplicableTradeDeliveryTerms/ram:RelevantTradeLocation/ram:Name"] = "Lieferbedingungs-Ort"
        addReference(&map, "\(agr)/ram:SellerOrderReferencedDocument", "Auftragsnummer des Verkäufers")
        addReference(&map, "\(agr)/ram:BuyerOrderReferencedDocument", "Bestellnummer des Käufers")
        addReference(&map, "\(agr)/ram:QuotationReferencedDocument", "Angebotsnummer")
        addReference(&map, "\(agr)/ram:ContractReferencedDocument", "Vertragsnummer")
        addReference(&map, "\(agr)/ram:RequisitionReferencedDocument", "Bedarfsanforderungsnummer")
        addReference(&map, "\(agr)/ram:CatalogueReferencedDocument", "Katalognummer")
        addReference(&map, "\(agr)/ram:BlanketOrderReferencedDocument", "Rahmenbestellnummer")
        addReference(&map, "\(agr)/ram:PreviousOrderReferencedDocument", "Vorherige Bestellung")
        addReference(&map, "\(agr)/ram:PreviousOrderChangeReferencedDocument", "Vorherige Bestelländerung")
        addReference(&map, "\(agr)/ram:PreviousOrderResponseReferencedDocument", "Vorherige Bestellantwort")
        addReference(&map, "\(agr)/ram:AdditionalReferencedDocument", "Zusätzliche Unterlage")
        map["\(agr)/ram:SpecifiedProcuringProject/ram:ID"] = "Projektnummer"
        map["\(agr)/ram:SpecifiedProcuringProject/ram:Name"] = "Projektname"

        // --- Lieferung (Kopf)
        map[del] = "Lieferung (Kopf)"
        addEvent(&map, "\(del)/ram:RequestedDeliverySupplyChainEvent", "Gewünschte Lieferung")
        addEvent(&map, "\(del)/ram:RequestedDespatchSupplyChainEvent", "Gewünschter Versand")
        addEvent(&map, "\(del)/ram:PlannedDeliverySupplyChainEvent", "Geplante Lieferung")
        addEvent(&map, "\(del)/ram:PlannedDespatchSupplyChainEvent", "Geplanter Versand")

        // --- Abrechnung (Kopf)
        map[set] = "Abrechnung (Kopf)"
        map["\(set)/ram:OrderCurrencyCode"] = OrderTerms.currency
        map["\(set)/ram:SpecifiedTradeSettlementPaymentMeans"] = "Zahlungsart"
        map["\(set)/ram:SpecifiedTradeSettlementPaymentMeans/ram:TypeCode"] = "Zahlungsart-Code"
        map["\(set)/ram:SpecifiedTradeSettlementPaymentMeans/ram:Information"] = "Zahlungsart (Text)"
        map["\(set)/ram:SpecifiedTradePaymentTerms"] = "Zahlungsbedingungen"
        map["\(set)/ram:SpecifiedTradePaymentTerms/ram:Description"] = "Zahlungsbedingungen (Text)"
        map["\(set)/ram:SpecifiedTradePaymentTerms/ram:DueDateDateTime/udt:DateTimeString"] = "Fälligkeitsdatum"
        addTax(&map, "\(set)/ram:ApplicableTradeTax", "Umsatzsteueraufschlüsselung")
        let sums = "\(set)/ram:SpecifiedTradeSettlementHeaderMonetarySummation"
        map[sums] = "Gesamtsummen"
        map["\(sums)/ram:LineTotalAmount"] = OrderLabels.lineTotal
        map["\(sums)/ram:ChargeTotalAmount"] = OrderLabels.chargeTotal
        map["\(sums)/ram:AllowanceTotalAmount"] = OrderLabels.allowanceTotal
        map["\(sums)/ram:TaxBasisTotalAmount"] = OrderLabels.taxBasisTotal
        map["\(sums)/ram:TaxTotalAmount"] = OrderLabels.taxTotal
        map["\(sums)/ram:GrandTotalAmount"] = OrderTerms.grandTotal
        map["\(sums)/ram:TotalPrepaidAmount"] = OrderLabels.prepaid
        map["\(sums)/ram:DuePayableAmount"] = OrderTerms.payableAmount
        map["\(set)/ram:ReceivableSpecifiedTradeAccountingAccount/ram:ID"] = "Buchungskonto"

        // --- Bestellposition
        map[line] = "Bestellposition"
        let lineDoc = "\(line)/ram:AssociatedDocumentLineDocument"
        map["\(lineDoc)/ram:LineID"] = "Positionsnummer"
        map["\(lineDoc)/ram:LineStatusCode"] = "Positionsstatus"
        map["\(lineDoc)/ram:IncludedNote"] = "Positionsanmerkung"
        map["\(lineDoc)/ram:IncludedNote/ram:Content"] = "Anmerkungstext"
        map["\(lineDoc)/ram:IncludedNote/ram:SubjectCode"] = "Betreff-Code"
        addProduct(&map, "\(line)/ram:SpecifiedTradeProduct", "Artikel")
        addProduct(&map, "\(line)/ram:SubstitutedReferencedProduct", "Ersatzartikel")

        let lineAgr = "\(line)/ram:SpecifiedLineTradeAgreement"
        map[lineAgr] = "Vereinbarung (Position)"
        map["\(lineAgr)/ram:BuyerReference"] = "Käuferreferenz (Position)"
        addReference(&map, "\(lineAgr)/ram:BuyerOrderReferencedDocument", "Bestellposition des Käufers")
        addReference(&map, "\(lineAgr)/ram:QuotationReferencedDocument", "Angebot (Position)")
        addReference(&map, "\(lineAgr)/ram:ContractReferencedDocument", "Vertrag (Position)")
        addReference(&map, "\(lineAgr)/ram:RequisitionReferencedDocument", "Bedarfsanforderung (Position)")
        addReference(&map, "\(lineAgr)/ram:CatalogueReferencedDocument", "Katalog (Position)")
        addReference(&map, "\(lineAgr)/ram:BlanketOrderReferencedDocument", "Rahmenbestellung (Position)")
        addReference(&map, "\(lineAgr)/ram:AdditionalReferencedDocument", "Zusätzliche Unterlage (Position)")
        addPrice(&map, "\(lineAgr)/ram:GrossPriceProductTradePrice", "Bruttopreis")
        addPrice(&map, "\(lineAgr)/ram:NetPriceProductTradePrice", "Nettopreis")

        let lineDel = "\(line)/ram:SpecifiedLineTradeDelivery"
        map[lineDel] = "Lieferung (Position)"
        map["\(lineDel)/ram:PartialDeliveryAllowedIndicator/udt:Indicator"] = "Teillieferung erlaubt"
        map["\(lineDel)/ram:RequestedQuantity"] = "Bestellmenge"
        map["\(lineDel)/ram:AgreedQuantity"] = "Bestätigte Menge"
        map["\(lineDel)/ram:PackageQuantity"] = "Anzahl Packstücke"
        map["\(lineDel)/ram:PerPackageUnitQuantity"] = "Menge je Packstück"
        addEvent(&map, "\(lineDel)/ram:RequestedDeliverySupplyChainEvent", "Gewünschte Lieferung")
        addEvent(&map, "\(lineDel)/ram:RequestedDespatchSupplyChainEvent", "Gewünschter Versand")

        let lineSet = "\(line)/ram:SpecifiedLineTradeSettlement"
        map[lineSet] = "Abrechnung (Position)"
        addTax(&map, "\(lineSet)/ram:ApplicableTradeTax", "Umsatzsteuer (Position)")
        map["\(lineSet)/ram:SpecifiedTradeSettlementLineMonetarySummation"] = "Positionssummen"
        map["\(lineSet)/ram:SpecifiedTradeSettlementLineMonetarySummation/ram:LineTotalAmount"] = "Positionsbetrag (netto)"
        map["\(lineSet)/ram:ReceivableSpecifiedTradeAccountingAccount/ram:ID"] = "Buchungskonto"

        return map
    }()

    /// Referenzierte Unterlage: Nummer, Position, Art, Name, Adresse, Anhang.
    private static func addReference(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/ram:IssuerAssignedID"] = label
        map["\(base)/ram:LineID"] = "\(label) – Position"
        map["\(base)/ram:TypeCode"] = "\(label) – Art"
        map["\(base)/ram:ReferenceTypeCode"] = "\(label) – Referenzart"
        map["\(base)/ram:Name"] = "\(label) – Name"
        map["\(base)/ram:URIID"] = "\(label) – Adresse"
        map["\(base)/ram:AttachmentBinaryObject"] = "\(label) – Anhang (Base64)"
        map["\(base)/ram:FormattedIssueDateTime/qdt:DateTimeString"] = "\(label) – Datum"
    }

    /// Liefer-/Versandereignis: Termin oder Zeitraum.
    private static func addEvent(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/ram:OccurrenceDateTime/udt:DateTimeString"] = "\(label) – Termin"
        map["\(base)/ram:OccurrenceSpecifiedPeriod"] = "\(label) – Zeitraum"
        map["\(base)/ram:OccurrenceSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString"] = "\(label) – Beginn"
        map["\(base)/ram:OccurrenceSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString"] = "\(label) – Ende"
    }

    /// Umsatzsteuer-Angaben (Kopf- oder Positionsebene).
    private static func addTax(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/ram:CalculatedAmount"] = "Steuerbetrag"
        map["\(base)/ram:TypeCode"] = "Steuerart"
        map["\(base)/ram:ExemptionReason"] = "Befreiungsgrund"
        map["\(base)/ram:BasisAmount"] = "Steuerbasisbetrag"
        map["\(base)/ram:CategoryCode"] = OrderTerms.vatCategory
        map["\(base)/ram:ExemptionReasonCode"] = "Befreiungsgrund-Code"
        map["\(base)/ram:DueDateTypeCode"] = "Code für das Datum der Steuerfälligkeit"
        map["\(base)/ram:RateApplicablePercent"] = "Steuersatz (%)"
    }

    /// Preis (brutto oder netto) mit Basismenge und Preisnachlass.
    private static func addPrice(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/ram:ChargeAmount"] = "\(label) (Betrag)"
        map["\(base)/ram:BasisQuantity"] = "\(label) – Basismenge"
        map["\(base)/ram:MinimumQuantity"] = "\(label) – Mindestmenge"
        map["\(base)/ram:MaximumQuantity"] = "\(label) – Höchstmenge"
        let ac = "\(base)/ram:AppliedTradeAllowanceCharge"
        map[ac] = "\(label) – Nachlass/Zuschlag"
        map["\(ac)/ram:ChargeIndicator/udt:Indicator"] = "Zuschlag-Kennzeichen"
        map["\(ac)/ram:CalculationPercent"] = "Prozentsatz"
        map["\(ac)/ram:BasisAmount"] = "Grundbetrag"
        map["\(ac)/ram:ActualAmount"] = "Betrag"
        map["\(ac)/ram:ReasonCode"] = "Grund-Code"
        map["\(ac)/ram:Reason"] = "Grund"
    }

    /// Artikelangaben (bestellter Artikel oder Ersatzartikel).
    private static func addProduct(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/ram:ID"] = "\(label) – Kennung"
        map["\(base)/ram:GlobalID"] = "\(label) – Globale Kennung (z.B. GTIN)"
        map["\(base)/ram:SellerAssignedID"] = "\(label)nummer des Verkäufers"
        map["\(base)/ram:BuyerAssignedID"] = "\(label)nummer des Käufers"
        map["\(base)/ram:ManufacturerAssignedID"] = "\(label)nummer des Herstellers"
        map["\(base)/ram:IndustryAssignedID"] = "\(label) – Branchenkennung"
        map["\(base)/ram:Name"] = "\(label)name"
        map["\(base)/ram:Description"] = "\(label)beschreibung"
        map["\(base)/ram:BatchID"] = "Chargennummer"
        map["\(base)/ram:BrandName"] = "Markenname"
        map["\(base)/ram:NetWeightMeasure"] = "Nettogewicht"
        map["\(base)/ram:GrossWeightMeasure"] = "Bruttogewicht"
        map["\(base)/ram:ApplicableProductCharacteristic"] = "\(label)attribut"
        map["\(base)/ram:ApplicableProductCharacteristic/ram:TypeCode"] = "Attributart"
        map["\(base)/ram:ApplicableProductCharacteristic/ram:Description"] = "Attributname"
        map["\(base)/ram:ApplicableProductCharacteristic/ram:Value"] = "Attributwert"
        map["\(base)/ram:ApplicableProductCharacteristic/ram:ValueMeasure"] = "Attributwert (Maß)"
        map["\(base)/ram:DesignatedProductClassification"] = "\(label)klassifikation"
        map["\(base)/ram:DesignatedProductClassification/ram:ClassCode"] = "Klassifikationscode"
        map["\(base)/ram:DesignatedProductClassification/ram:ClassName"] = "Klassifikationsname"
        map["\(base)/ram:IndividualTradeProductInstance/ram:BatchID"] = "Chargennummer"
        map["\(base)/ram:IndividualTradeProductInstance/ram:SerialID"] = "Seriennummer"
        map["\(base)/ram:OriginTradeCountry/ram:ID"] = "Ursprungsland"
        addReference(&map, "\(base)/ram:AdditionalReferenceReferencedDocument", "\(label) – Unterlage")
    }

    // MARK: Auflösung

    static func label(path: String, node: XMLTreeNode, ancestors: [XMLTreeNode]) -> String? {
        if let dynamic = dynamicLabel(path: path, node: node, ancestors: ancestors) {
            return dynamic
        }
        if let fixed = fixed[path] { return fixed }
        // Beteiligte: "Rolle: Feld" aus dem relativen Pfad hinter dem
        // Party-Element — gleiche Struktur bei allen acht Rollen.
        if let party = parties[node.name] { return party }
        if let partyIndex = ancestors.lastIndex(where: { parties[$0.name] != nil }) {
            let role = parties[ancestors[partyIndex].name]!
            let relative = (ancestors[(partyIndex + 1)...].map(\.name) + [node.name])
                .joined(separator: "/")
            if let field = partyFields[relative] { return "\(role): \(field)" }
        }
        return nil
    }

    /// Nachlass oder Zuschlag hängt am ChargeIndicator im selben Container;
    /// Preis-Nachlässe (AppliedTradeAllowanceCharge) sind fest gemappt.
    private static func dynamicLabel(path: String, node: XMLTreeNode,
                                     ancestors: [XMLTreeNode]) -> String? {
        let containerName = "ram:SpecifiedTradeAllowanceCharge"
        guard let containerIndex = ancestors.lastIndex(where: { $0.name == containerName })
            ?? (node.name == containerName ? ancestors.count : nil) else { return nil }
        let container = containerIndex == ancestors.count ? node : ancestors[containerIndex]
        guard let isCharge = XMLTree.booleanText(
            XMLTree.firstNode(in: container, path: ["ram:ChargeIndicator", "udt:Indicator"])?.text)
        else { return nil }
        let isLine = path.contains("ram:IncludedSupplyChainTradeLineItem/")
        let group = OrderLabels.allowanceCharge(isCharge: isCharge, isLine: isLine)
        if node.name == containerName { return group }
        switch node.name {
        case "ram:CalculationPercent": return "\(group) – Prozentsatz"
        case "ram:BasisAmount": return "\(group) – Grundbetrag"
        case "ram:ActualAmount": return "\(group) – Betrag"
        case "ram:Reason": return "\(group) – Grund"
        case "ram:ReasonCode": return "\(group) – Grund-Code"
        case "ram:CategoryCode": return OrderTerms.vatCategory
        case "ram:RateApplicablePercent": return "Steuersatz (%)"
        default: return nil
        }
    }
}

// MARK: - UBL Order / OrderResponse (Peppol BIS Ordering)

enum UBLOrderMapping {

    private static let root = "ubl:Order"

    /// Beteiligte mit Rolle; Unterelemente generisch als "Rolle: Feld".
    static let parties: [String: String] = [
        "cac:BuyerCustomerParty": OrderTerms.buyer,
        "cac:SellerSupplierParty": OrderTerms.seller,
        "cac:OriginatorCustomerParty": "Bedarfsträger",
        "cac:AccountingCustomerParty": "Rechnungsempfänger",
        "cac:DeliveryParty": "Warenempfänger",
        "cac:OriginatorParty": "Bedarfsträger (Position)",
    ]

    static let partyFields: [String: String] = {
        var map: [String: String] = [:]
        // Peppol verpackt die eigentliche Partei in cac:Party; die
        // DeliveryParty steht direkt. Beide Varianten eintragen.
        for prefix in ["cac:Party/", ""] {
            map["\(prefix)cbc:EndpointID"] = "Elektronische Adresse"
            map["\(prefix)cac:PartyIdentification/cbc:ID"] = "Kennung"
            map["\(prefix)cac:PartyName/cbc:Name"] = "Name"
            map["\(prefix)cac:PostalAddress"] = "Postanschrift"
            map["\(prefix)cac:PostalAddress/cbc:StreetName"] = "Adresszeile 1"
            map["\(prefix)cac:PostalAddress/cbc:AdditionalStreetName"] = "Adresszeile 2"
            map["\(prefix)cac:PostalAddress/cac:AddressLine/cbc:Line"] = "Adresszeile 3"
            map["\(prefix)cac:PostalAddress/cbc:CityName"] = "Ort"
            map["\(prefix)cac:PostalAddress/cbc:PostalZone"] = "Postleitzahl"
            map["\(prefix)cac:PostalAddress/cbc:CountrySubentity"] = "Region"
            map["\(prefix)cac:PostalAddress/cac:Country/cbc:IdentificationCode"] = "Ländercode"
            map["\(prefix)cac:PartyTaxScheme/cbc:CompanyID"] = "USt-IdNr."
            map["\(prefix)cac:PartyLegalEntity/cbc:RegistrationName"] = "Registrierter Name"
            map["\(prefix)cac:PartyLegalEntity/cbc:CompanyID"] = "Registernummer"
            map["\(prefix)cac:Contact"] = "Kontakt"
            map["\(prefix)cac:Contact/cbc:ID"] = "Kontakt-Kennung"
            map["\(prefix)cac:Contact/cbc:Name"] = "Ansprechpartner"
            map["\(prefix)cac:Contact/cbc:Telephone"] = "Telefon"
            map["\(prefix)cac:Contact/cbc:ElectronicMail"] = "E-Mail"
            map["\(prefix)cac:Person/cbc:FirstName"] = "Vorname"
            map["\(prefix)cac:Person/cbc:FamilyName"] = "Nachname"
        }
        map["cac:DeliveryContact/cbc:Name"] = "Lieferkontakt"
        map["cac:DeliveryContact/cbc:Telephone"] = "Lieferkontakt – Telefon"
        map["cac:DeliveryContact/cbc:ElectronicMail"] = "Lieferkontakt – E-Mail"
        return map
    }()

    static let fixed: [String: String] = {
        var map: [String: String] = [:]

        // --- Dokumentkopf (Order und OrderResponse)
        map["\(root)/cbc:CustomizationID"] = "Spezifikationskennung"
        map["\(root)/cbc:ProfileID"] = "Geschäftsprozess"
        map["\(root)/cbc:ID"] = OrderTerms.number
        map["\(root)/cbc:SalesOrderID"] = "Auftragsnummer des Verkäufers"
        map["\(root)/cbc:IssueDate"] = OrderTerms.date
        map["\(root)/cbc:IssueTime"] = "Uhrzeit der Ausstellung"
        map["\(root)/cbc:OrderTypeCode"] = OrderTerms.typeCode
        map["\(root)/cbc:OrderResponseCode"] = "Antwort-Code (Bestellantwort)"
        map["\(root)/cbc:Note"] = "Anmerkung"
        map["\(root)/cbc:DocumentCurrencyCode"] = OrderTerms.currency
        map["\(root)/cbc:CustomerReference"] = "Käuferreferenz"
        map["\(root)/cbc:AccountingCost"] = "Buchungskonto"
        map["\(root)/cac:ValidityPeriod"] = "Gültigkeitszeitraum"
        map["\(root)/cac:ValidityPeriod/cbc:StartDate"] = "Gültig ab"
        map["\(root)/cac:ValidityPeriod/cbc:EndDate"] = "Gültig bis"
        map["\(root)/cac:QuotationDocumentReference/cbc:ID"] = "Angebotsnummer"
        map["\(root)/cac:OrderDocumentReference/cbc:ID"] = "Vorherige Bestellung"
        map["\(root)/cac:OrderReference/cbc:ID"] = "Bestellnummer (Referenz)"
        map["\(root)/cac:OrderReference/cbc:SalesOrderID"] = "Auftragsnummer des Verkäufers"
        map["\(root)/cac:OrderReference/cbc:IssueDate"] = "Bestelldatum (Referenz)"
        map["\(root)/cac:OriginatorDocumentReference/cbc:ID"] = "Bedarfsanforderungsnummer"
        map["\(root)/cac:Contract/cbc:ID"] = "Vertragsnummer"
        let addDoc = "\(root)/cac:AdditionalDocumentReference"
        map[addDoc] = "Zusätzliche Unterlage"
        map["\(addDoc)/cbc:ID"] = "Kennung der Unterlage"
        map["\(addDoc)/cbc:DocumentType"] = "Art der Unterlage"
        map["\(addDoc)/cbc:DocumentTypeCode"] = "Art der Unterlage (Code)"
        map["\(addDoc)/cbc:DocumentDescription"] = "Beschreibung der Unterlage"
        map["\(addDoc)/cac:Attachment/cbc:EmbeddedDocumentBinaryObject"] = "Anhang (Base64)"
        map["\(addDoc)/cac:Attachment/cac:ExternalReference/cbc:URI"] = "Adresse der Unterlage"

        // --- Lieferung und Lieferbedingungen
        addDelivery(&map, "\(root)/cac:Delivery", "Lieferung")
        map["\(root)/cac:DeliveryTerms"] = "Lieferbedingungen"
        map["\(root)/cac:DeliveryTerms/cbc:ID"] = "Lieferbedingungs-Code (Incoterm)"
        map["\(root)/cac:DeliveryTerms/cbc:SpecialTerms"] = "Lieferbedingungen (Text)"
        map["\(root)/cac:DeliveryTerms/cac:DeliveryLocation/cbc:ID"] = "Lieferbedingungs-Ort"

        // --- Steuern und Gesamtsummen
        map["\(root)/cac:TaxTotal"] = "Umsatzsteuer"
        map["\(root)/cac:TaxTotal/cbc:TaxAmount"] = OrderLabels.taxTotal
        let totals = "\(root)/cac:AnticipatedMonetaryTotal"
        map[totals] = "Gesamtsummen"
        map["\(totals)/cbc:LineExtensionAmount"] = OrderLabels.lineTotal
        map["\(totals)/cbc:TaxExclusiveAmount"] = OrderLabels.taxBasisTotal
        map["\(totals)/cbc:TaxInclusiveAmount"] = OrderTerms.grandTotal
        map["\(totals)/cbc:AllowanceTotalAmount"] = OrderLabels.allowanceTotal
        map["\(totals)/cbc:ChargeTotalAmount"] = OrderLabels.chargeTotal
        map["\(totals)/cbc:PrepaidAmount"] = OrderLabels.prepaid
        map["\(totals)/cbc:PayableRoundingAmount"] = OrderLabels.rounding
        map["\(totals)/cbc:PayableAmount"] = OrderTerms.payableAmount

        // --- Bestellposition
        let orderLine = "\(root)/cac:OrderLine"
        map[orderLine] = "Bestellposition"
        map["\(orderLine)/cbc:Note"] = "Positionsanmerkung"
        addLineItem(&map, "\(orderLine)/cac:LineItem", "Positionsdaten")
        addLineItem(&map, "\(orderLine)/cac:SellerProposedSubstituteLineItem", "Vorgeschlagener Ersatzartikel")
        addLineItem(&map, "\(orderLine)/cac:SellerSubstitutedLineItem", "Ersetzter Artikel")
        map["\(orderLine)/cac:OrderLineReference/cbc:LineID"] = "Bestellpositionsnummer (Referenz)"

        return map
    }()

    private static func addDelivery(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/cbc:ID"] = "\(label) – Kennung"
        map["\(base)/cac:DeliveryLocation"] = "Lieferort"
        map["\(base)/cac:DeliveryLocation/cbc:ID"] = "Lieferort – Kennung"
        map["\(base)/cac:DeliveryLocation/cbc:Name"] = "Lieferort – Name"
        map["\(base)/cac:DeliveryLocation/cac:Address"] = "Lieferanschrift"
        map["\(base)/cac:DeliveryLocation/cac:Address/cbc:StreetName"] = "Lieferanschrift – Adresszeile 1"
        map["\(base)/cac:DeliveryLocation/cac:Address/cbc:AdditionalStreetName"] = "Lieferanschrift – Adresszeile 2"
        map["\(base)/cac:DeliveryLocation/cac:Address/cac:AddressLine/cbc:Line"] = "Lieferanschrift – Adresszeile 3"
        map["\(base)/cac:DeliveryLocation/cac:Address/cbc:CityName"] = "Lieferanschrift – Ort"
        map["\(base)/cac:DeliveryLocation/cac:Address/cbc:PostalZone"] = "Lieferanschrift – Postleitzahl"
        map["\(base)/cac:DeliveryLocation/cac:Address/cbc:CountrySubentity"] = "Lieferanschrift – Region"
        map["\(base)/cac:DeliveryLocation/cac:Address/cac:Country/cbc:IdentificationCode"] = "Lieferanschrift – Ländercode"
        map["\(base)/cac:RequestedDeliveryPeriod"] = "Gewünschter Lieferzeitraum"
        map["\(base)/cac:RequestedDeliveryPeriod/cbc:StartDate"] = "Gewünschte Lieferung – Beginn"
        map["\(base)/cac:RequestedDeliveryPeriod/cbc:EndDate"] = "Gewünschte Lieferung – Ende"
        map["\(base)/cac:PromisedDeliveryPeriod"] = "Zugesagter Lieferzeitraum"
        map["\(base)/cac:PromisedDeliveryPeriod/cbc:StartDate"] = "Zugesagte Lieferung – Beginn"
        map["\(base)/cac:PromisedDeliveryPeriod/cbc:EndDate"] = "Zugesagte Lieferung – Ende"
        map["\(base)/cac:Shipment/cbc:ID"] = "Sendungsnummer"
    }

    private static func addLineItem(_ map: inout [String: String], _ base: String, _ label: String) {
        map[base] = label
        map["\(base)/cbc:ID"] = "Positionsnummer"
        map["\(base)/cbc:Note"] = "Positionsanmerkung"
        map["\(base)/cbc:LineStatusCode"] = "Positionsstatus"
        map["\(base)/cbc:Quantity"] = "Bestellmenge"
        map["\(base)/cbc:LineExtensionAmount"] = "Positionsbetrag (netto)"
        map["\(base)/cbc:TotalTaxAmount"] = "Steuerbetrag (Position)"
        map["\(base)/cbc:PartialDeliveryIndicator"] = "Teillieferung erlaubt"
        map["\(base)/cbc:AccountingCost"] = "Buchungskonto"
        addDelivery(&map, "\(base)/cac:Delivery", "Lieferung (Position)")
        map["\(base)/cac:Price"] = "Nettopreis"
        map["\(base)/cac:Price/cbc:PriceAmount"] = "Nettopreis (Betrag)"
        map["\(base)/cac:Price/cbc:BaseQuantity"] = "Nettopreis – Basismenge"
        map["\(base)/cac:Price/cac:AllowanceCharge"] = "Preisnachlass"
        map["\(base)/cac:Price/cac:AllowanceCharge/cbc:Amount"] = "Preisnachlass – Betrag"
        map["\(base)/cac:Price/cac:AllowanceCharge/cbc:BaseAmount"] = "Bruttopreis (Betrag)"
        let item = "\(base)/cac:Item"
        map[item] = "Artikel"
        map["\(item)/cbc:Description"] = "Artikelbeschreibung"
        map["\(item)/cbc:Name"] = "Artikelname"
        map["\(item)/cac:BuyersItemIdentification/cbc:ID"] = "Artikelnummer des Käufers"
        map["\(item)/cac:SellersItemIdentification/cbc:ID"] = "Artikelnummer des Verkäufers"
        map["\(item)/cac:ManufacturersItemIdentification/cbc:ID"] = "Artikelnummer des Herstellers"
        map["\(item)/cac:StandardItemIdentification/cbc:ID"] = "Globale Artikelkennung (z.B. GTIN)"
        map["\(item)/cac:ItemSpecificationDocumentReference/cbc:ID"] = "Artikelspezifikation (Unterlage)"
        map["\(item)/cac:CommodityClassification/cbc:ItemClassificationCode"] = "Klassifikationscode"
        map["\(item)/cac:ClassifiedTaxCategory"] = "Umsatzsteuer (Position)"
        map["\(item)/cac:ClassifiedTaxCategory/cbc:ID"] = OrderTerms.vatCategory
        map["\(item)/cac:ClassifiedTaxCategory/cbc:Percent"] = "Steuersatz (%)"
        map["\(item)/cac:AdditionalItemProperty"] = "Artikelattribut"
        map["\(item)/cac:AdditionalItemProperty/cbc:Name"] = "Attributname"
        map["\(item)/cac:AdditionalItemProperty/cbc:Value"] = "Attributwert"
        map["\(item)/cac:ItemInstance/cbc:SerialID"] = "Seriennummer"
        map["\(item)/cac:ItemInstance/cac:LotIdentification/cbc:LotNumberID"] = "Chargennummer"
    }

    /// OrderResponse-Pfade auf die Order-Wurzel normalisieren — eine Tabelle
    /// für beide Dokumente; die Unterschiede (OrderResponseCode,
    /// OrderReference, …) stehen unter derselben Wurzel.
    static func normalizedPath(_ path: String) -> String {
        guard path.hasPrefix("ubl:OrderResponse") else { return path }
        return path.replacingOccurrences(of: "ubl:OrderResponse", with: "ubl:Order")
    }

    static func label(path rawPath: String, node: XMLTreeNode,
                      ancestors: [XMLTreeNode]) -> String? {
        let path = normalizedPath(rawPath)
        if let dynamic = dynamicLabel(path: path, node: node, ancestors: ancestors) {
            return dynamic
        }
        if let fixed = fixed[path] { return fixed }
        if let party = parties[node.name] { return party }
        if let partyIndex = ancestors.lastIndex(where: { parties[$0.name] != nil }) {
            let role = parties[ancestors[partyIndex].name]!
            let relative = (ancestors[(partyIndex + 1)...].map(\.name) + [node.name])
                .joined(separator: "/")
            if let field = partyFields[relative] { return "\(role): \(field)" }
        }
        return nil
    }

    private static func dynamicLabel(path: String, node: XMLTreeNode,
                                     ancestors: [XMLTreeNode]) -> String? {
        // Preis-Nachlässe sind fest gemappt.
        if path.contains("cac:Price/cac:AllowanceCharge") { return nil }
        guard let containerIndex = ancestors.lastIndex(where: { $0.name == "cac:AllowanceCharge" })
            ?? (node.name == "cac:AllowanceCharge" ? ancestors.count : nil) else { return nil }
        let container = containerIndex == ancestors.count ? node : ancestors[containerIndex]
        guard let isCharge = XMLTree.booleanText(
            XMLTree.firstNode(in: container, path: ["cbc:ChargeIndicator"])?.text)
        else { return nil }
        let isLine = path.contains("cac:OrderLine/")
        let group = OrderLabels.allowanceCharge(isCharge: isCharge, isLine: isLine)
        switch node.name {
        case "cac:AllowanceCharge": return group
        case "cbc:AllowanceChargeReasonCode": return "\(group) – Grund-Code"
        case "cbc:AllowanceChargeReason": return "\(group) – Grund"
        case "cbc:MultiplierFactorNumeric": return "\(group) – Prozentsatz"
        case "cbc:Amount": return "\(group) – Betrag"
        case "cbc:BaseAmount": return "\(group) – Grundbetrag"
        case "cbc:ID" where ancestors.last?.name == "cac:TaxCategory": return OrderTerms.vatCategory
        case "cbc:Percent" where ancestors.last?.name == "cac:TaxCategory": return "Steuersatz (%)"
        default: return nil
        }
    }
}
