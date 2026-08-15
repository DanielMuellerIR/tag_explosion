// Pfad→Business-Term-Zuordnung für die CII-Syntax (UN/CEFACT Cross Industry
// Invoice, Schema D16B): ZUGFeRD 2.x, Factur-X und die CII-Variante der
// XRechnung. Grundlage ist das Syntax-Binding EN 16931-3-3.
//
// Die Pfade sind kanonische Namen ohne Positionsindizes (siehe XMLTree).
// EXTENDED-Felder außerhalb der EN 16931 haben bewusst keinen Eintrag —
// sie bleiben als Rohpfad sichtbar statt falsch benannt zu werden.
import Foundation

enum CIIMapping {

    private static let root = "rsm:CrossIndustryInvoice"
    private static let ctx = "rsm:CrossIndustryInvoice/rsm:ExchangedDocumentContext"
    private static let doc = "rsm:CrossIndustryInvoice/rsm:ExchangedDocument"
    private static let tx = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction"
    private static let line = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem"
    private static let agr = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement"
    private static let del = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery"
    private static let set = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement"

    /// Feste Pfade → Term. Aufgebaut aus Bausteinen, damit die Party-Bäume
    /// (Verkäufer/Käufer/…) nicht viermal ausgeschrieben werden müssen.
    static let fixed: [String: String] = {
        var map: [String: String] = [:]

        // --- Prozesssteuerung (BG-2)
        map[ctx] = "BG-2"
        map["\(ctx)/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID"] = "BT-23"
        map["\(ctx)/ram:GuidelineSpecifiedDocumentContextParameter/ram:ID"] = "BT-24"

        // --- Dokumentkopf
        map["\(doc)/ram:ID"] = "BT-1"
        map["\(doc)/ram:TypeCode"] = "BT-3"
        map["\(doc)/ram:IssueDateTime/udt:DateTimeString"] = "BT-2"
        map["\(doc)/ram:IncludedNote"] = "BG-1"
        map["\(doc)/ram:IncludedNote/ram:Content"] = "BT-22"
        map["\(doc)/ram:IncludedNote/ram:SubjectCode"] = "BT-21"

        // --- Handelsvereinbarung (Kopfebene)
        map["\(agr)/ram:BuyerReference"] = "BT-10"
        map["\(agr)/ram:SellerOrderReferencedDocument/ram:IssuerAssignedID"] = "BT-14"
        map["\(agr)/ram:BuyerOrderReferencedDocument/ram:IssuerAssignedID"] = "BT-13"
        map["\(agr)/ram:ContractReferencedDocument/ram:IssuerAssignedID"] = "BT-12"
        map["\(agr)/ram:SpecifiedProcuringProject/ram:ID"] = "BT-11"

        // Verkäufer (BG-4/5/6)
        addParty(&map, base: "\(agr)/ram:SellerTradeParty",
                 party: "BG-4", id: "BT-29", name: "BT-27", tradingName: "BT-28",
                 legalID: "BT-30", legalInfo: "BT-33", electronicAddress: "BT-34",
                 contact: "BG-6", contactName: "BT-41", contactPhone: "BT-42",
                 contactMail: "BT-43",
                 address: "BG-5", line1: "BT-35", line2: "BT-36", line3: "BT-162",
                 city: "BT-37", postcode: "BT-38", region: "BT-39", country: "BT-40")

        // Käufer (BG-7/8/9)
        addParty(&map, base: "\(agr)/ram:BuyerTradeParty",
                 party: "BG-7", id: "BT-46", name: "BT-44", tradingName: "BT-45",
                 legalID: "BT-47", legalInfo: nil, electronicAddress: "BT-49",
                 contact: "BG-9", contactName: "BT-56", contactPhone: "BT-57",
                 contactMail: "BT-58",
                 address: "BG-8", line1: "BT-50", line2: "BT-51", line3: "BT-163",
                 city: "BT-52", postcode: "BT-53", region: "BT-54", country: "BT-55")

        // Steuerbevollmächtigter (BG-11/12)
        addParty(&map, base: "\(agr)/ram:SellerTaxRepresentativeTradeParty",
                 party: "BG-11", id: nil, name: "BT-62", tradingName: nil,
                 legalID: nil, legalInfo: nil, electronicAddress: nil,
                 contact: nil, contactName: nil, contactPhone: nil, contactMail: nil,
                 address: "BG-12", line1: "BT-64", line2: "BT-65", line3: "BT-164",
                 city: "BT-66", postcode: "BT-67", region: "BT-68", country: "BT-69")

        // --- Lieferung (BG-13/15)
        map[del] = "BG-13"
        map["\(del)/ram:ShipToTradeParty/ram:ID"] = "BT-71"
        map["\(del)/ram:ShipToTradeParty/ram:GlobalID"] = "BT-71"
        map["\(del)/ram:ShipToTradeParty/ram:Name"] = "BT-70"
        addAddress(&map, base: "\(del)/ram:ShipToTradeParty/ram:PostalTradeAddress",
                   group: "BG-15", line1: "BT-75", line2: "BT-76", line3: "BT-165",
                   city: "BT-77", postcode: "BT-78", region: "BT-79", country: "BT-80")
        map["\(del)/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime/udt:DateTimeString"] = "BT-72"
        map["\(del)/ram:DespatchAdviceReferencedDocument/ram:IssuerAssignedID"] = "BT-16"
        map["\(del)/ram:ReceivingAdviceReferencedDocument/ram:IssuerAssignedID"] = "BT-15"

        // --- Abrechnung (Kopfebene)
        map["\(set)/ram:CreditorReferenceID"] = "BT-90"
        map["\(set)/ram:PaymentReference"] = "BT-83"
        map["\(set)/ram:TaxCurrencyCode"] = "BT-6"
        map["\(set)/ram:InvoiceCurrencyCode"] = "BT-5"

        // Zahlungsempfänger (BG-10)
        map["\(set)/ram:PayeeTradeParty"] = "BG-10"
        map["\(set)/ram:PayeeTradeParty/ram:ID"] = "BT-60"
        map["\(set)/ram:PayeeTradeParty/ram:GlobalID"] = "BT-60"
        map["\(set)/ram:PayeeTradeParty/ram:Name"] = "BT-59"
        map["\(set)/ram:PayeeTradeParty/ram:SpecifiedLegalOrganization/ram:ID"] = "BT-61"

        // Zahlungsanweisungen (BG-16/17/18)
        let means = "\(set)/ram:SpecifiedTradeSettlementPaymentMeans"
        map[means] = "BG-16"
        map["\(means)/ram:TypeCode"] = "BT-81"
        map["\(means)/ram:Information"] = "BT-82"
        map["\(means)/ram:ApplicableTradeSettlementFinancialCard"] = "BG-18"
        map["\(means)/ram:ApplicableTradeSettlementFinancialCard/ram:ID"] = "BT-87"
        map["\(means)/ram:ApplicableTradeSettlementFinancialCard/ram:CardholderName"] = "BT-88"
        map["\(means)/ram:PayerPartyDebtorFinancialAccount/ram:IBANID"] = "BT-91"
        map["\(means)/ram:PayeePartyCreditorFinancialAccount"] = "BG-17"
        map["\(means)/ram:PayeePartyCreditorFinancialAccount/ram:IBANID"] = "BT-84"
        map["\(means)/ram:PayeePartyCreditorFinancialAccount/ram:ProprietaryID"] = "BT-84"
        map["\(means)/ram:PayeePartyCreditorFinancialAccount/ram:AccountName"] = "BT-85"
        map["\(means)/ram:PayeeSpecifiedCreditorFinancialInstitution/ram:BICID"] = "BT-86"

        // Umsatzsteueraufschlüsselung (BG-23)
        let tax = "\(set)/ram:ApplicableTradeTax"
        map[tax] = "BG-23"
        map["\(tax)/ram:CalculatedAmount"] = "BT-117"
        map["\(tax)/ram:ExemptionReason"] = "BT-120"
        map["\(tax)/ram:BasisAmount"] = "BT-116"
        map["\(tax)/ram:CategoryCode"] = "BT-118"
        map["\(tax)/ram:ExemptionReasonCode"] = "BT-121"
        map["\(tax)/ram:TaxPointDate/udt:DateString"] = "BT-7"
        map["\(tax)/ram:DueDateTypeCode"] = "BT-8"
        map["\(tax)/ram:RateApplicablePercent"] = "BT-119"

        // Rechnungszeitraum (BG-14)
        map["\(set)/ram:BillingSpecifiedPeriod"] = "BG-14"
        map["\(set)/ram:BillingSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString"] = "BT-73"
        map["\(set)/ram:BillingSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString"] = "BT-74"

        // Zahlungsbedingungen
        map["\(set)/ram:SpecifiedTradePaymentTerms/ram:Description"] = "BT-20"
        map["\(set)/ram:SpecifiedTradePaymentTerms/ram:DueDateDateTime/udt:DateTimeString"] = "BT-9"
        map["\(set)/ram:SpecifiedTradePaymentTerms/ram:DirectDebitMandateID"] = "BT-89"

        // Gesamtsummen (BG-22) — ram:TaxTotalAmount löst der dynamische Teil
        // auf (BT-110 vs. BT-111 hängt an der Währung).
        let sums = "\(set)/ram:SpecifiedTradeSettlementHeaderMonetarySummation"
        map[sums] = "BG-22"
        map["\(sums)/ram:LineTotalAmount"] = "BT-106"
        map["\(sums)/ram:ChargeTotalAmount"] = "BT-108"
        map["\(sums)/ram:AllowanceTotalAmount"] = "BT-107"
        map["\(sums)/ram:TaxBasisTotalAmount"] = "BT-109"
        map["\(sums)/ram:RoundingAmount"] = "BT-114"
        map["\(sums)/ram:GrandTotalAmount"] = "BT-112"
        map["\(sums)/ram:TotalPrepaidAmount"] = "BT-113"
        map["\(sums)/ram:DuePayableAmount"] = "BT-115"

        // Vorausgegangene Rechnung (BG-3)
        map["\(set)/ram:InvoiceReferencedDocument"] = "BG-3"
        map["\(set)/ram:InvoiceReferencedDocument/ram:IssuerAssignedID"] = "BT-25"
        map["\(set)/ram:InvoiceReferencedDocument/ram:FormattedIssueDateTime/qdt:DateTimeString"] = "BT-26"
        map["\(set)/ram:ReceivableSpecifiedTradeAccountingAccount/ram:ID"] = "BT-19"

        // --- Rechnungsposition (BG-25 …)
        map[line] = "BG-25"
        map["\(line)/ram:AssociatedDocumentLineDocument/ram:LineID"] = "BT-126"
        map["\(line)/ram:AssociatedDocumentLineDocument/ram:IncludedNote/ram:Content"] = "BT-127"

        let product = "\(line)/ram:SpecifiedTradeProduct"
        map[product] = "BG-31"
        map["\(product)/ram:GlobalID"] = "BT-157"
        map["\(product)/ram:SellerAssignedID"] = "BT-155"
        map["\(product)/ram:BuyerAssignedID"] = "BT-156"
        map["\(product)/ram:Name"] = "BT-153"
        map["\(product)/ram:Description"] = "BT-154"
        map["\(product)/ram:ApplicableProductCharacteristic"] = "BG-32"
        map["\(product)/ram:ApplicableProductCharacteristic/ram:Description"] = "BT-160"
        map["\(product)/ram:ApplicableProductCharacteristic/ram:Value"] = "BT-161"
        map["\(product)/ram:DesignatedProductClassification/ram:ClassCode"] = "BT-158"
        map["\(product)/ram:OriginTradeCountry/ram:ID"] = "BT-159"

        let lineAgr = "\(line)/ram:SpecifiedLineTradeAgreement"
        map[lineAgr] = "BG-29"
        map["\(lineAgr)/ram:BuyerOrderReferencedDocument/ram:LineID"] = "BT-132"
        map["\(lineAgr)/ram:GrossPriceProductTradePrice/ram:ChargeAmount"] = "BT-148"
        map["\(lineAgr)/ram:GrossPriceProductTradePrice/ram:BasisQuantity"] = "BT-149"
        map["\(lineAgr)/ram:GrossPriceProductTradePrice/ram:AppliedTradeAllowanceCharge/ram:ActualAmount"] = "BT-147"
        map["\(lineAgr)/ram:NetPriceProductTradePrice/ram:ChargeAmount"] = "BT-146"
        map["\(lineAgr)/ram:NetPriceProductTradePrice/ram:BasisQuantity"] = "BT-149"

        map["\(line)/ram:SpecifiedLineTradeDelivery/ram:BilledQuantity"] = "BT-129"

        let lineSet = "\(line)/ram:SpecifiedLineTradeSettlement"
        map["\(lineSet)/ram:ApplicableTradeTax"] = "BG-30"
        map["\(lineSet)/ram:ApplicableTradeTax/ram:CategoryCode"] = "BT-151"
        map["\(lineSet)/ram:ApplicableTradeTax/ram:RateApplicablePercent"] = "BT-152"
        map["\(lineSet)/ram:BillingSpecifiedPeriod"] = "BG-26"
        map["\(lineSet)/ram:BillingSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString"] = "BT-134"
        map["\(lineSet)/ram:BillingSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString"] = "BT-135"
        map["\(lineSet)/ram:SpecifiedTradeSettlementLineMonetarySummation/ram:LineTotalAmount"] = "BT-131"
        map["\(lineSet)/ram:AdditionalReferencedDocument/ram:IssuerAssignedID"] = "BT-128"
        map["\(lineSet)/ram:ReceivableSpecifiedTradeAccountingAccount/ram:ID"] = "BT-133"

        return map
    }()

    /// Party-Baum: gleiche Struktur für Verkäufer, Käufer und
    /// Steuerbevollmächtigten, nur mit anderen BT-Nummern.
    private static func addParty(
        _ map: inout [String: String], base: String,
        party: String, id: String?, name: String?, tradingName: String?,
        legalID: String?, legalInfo: String?, electronicAddress: String?,
        contact: String?, contactName: String?, contactPhone: String?, contactMail: String?,
        address: String, line1: String, line2: String, line3: String,
        city: String, postcode: String, region: String, country: String
    ) {
        map[base] = party
        if let id {
            map["\(base)/ram:ID"] = id
            map["\(base)/ram:GlobalID"] = id
        }
        if let name { map["\(base)/ram:Name"] = name }
        if let legalInfo { map["\(base)/ram:Description"] = legalInfo }
        if let legalID { map["\(base)/ram:SpecifiedLegalOrganization/ram:ID"] = legalID }
        if let tradingName {
            map["\(base)/ram:SpecifiedLegalOrganization/ram:TradingBusinessName"] = tradingName
        }
        if let electronicAddress {
            map["\(base)/ram:URIUniversalCommunication/ram:URIID"] = electronicAddress
        }
        if let contact {
            let c = "\(base)/ram:DefinedTradeContact"
            map[c] = contact
            if let contactName {
                map["\(c)/ram:PersonName"] = contactName
                map["\(c)/ram:DepartmentName"] = contactName
            }
            if let contactPhone {
                map["\(c)/ram:TelephoneUniversalCommunication/ram:CompleteNumber"] = contactPhone
            }
            if let contactMail {
                map["\(c)/ram:EmailURIUniversalCommunication/ram:URIID"] = contactMail
            }
        }
        addAddress(&map, base: "\(base)/ram:PostalTradeAddress", group: address,
                   line1: line1, line2: line2, line3: line3,
                   city: city, postcode: postcode, region: region, country: country)
        // ram:SpecifiedTaxRegistration/ram:ID löst der dynamische Teil auf
        // (USt-IdNr. vs. Steuernummer hängt am schemeID-Attribut).
    }

    private static func addAddress(
        _ map: inout [String: String], base: String, group: String,
        line1: String, line2: String, line3: String,
        city: String, postcode: String, region: String, country: String
    ) {
        map[base] = group
        map["\(base)/ram:PostcodeCode"] = postcode
        map["\(base)/ram:LineOne"] = line1
        map["\(base)/ram:LineTwo"] = line2
        map["\(base)/ram:LineThree"] = line3
        map["\(base)/ram:CityName"] = city
        map["\(base)/ram:CountryID"] = country
        map["\(base)/ram:CountrySubDivisionName"] = region
    }

    // MARK: - Dynamische Zuordnung

    /// Liefert den Term für ein Element; `ancestors` sind die Elternelemente
    /// (Wurzel zuerst), `invoiceCurrency` der bereits gelesene BT-5-Wert.
    static func term(path: String, node: XMLTreeNode,
                     ancestors: [XMLTreeNode], invoiceCurrency: String?) -> String? {
        if let dynamicTerm = dynamicTerm(path: path, node: node, ancestors: ancestors,
                                         invoiceCurrency: invoiceCurrency) {
            return dynamicTerm
        }
        return fixed[path]
    }

    /// Attribute mit eigener BT-Nummer: Die Maßeinheit einer Menge liegt in
    /// CII nicht als Element vor, sondern als `unitCode`-Attribut am
    /// Mengen-Element (BT-129 → BT-130, BT-149 → BT-150).
    static func attributeTerms(for term: String?,
                               node: XMLTreeNode) -> [(attribute: String, term: String)] {
        let hasUnit = node.attributes.contains { $0.name == "unitCode" && !$0.value.isEmpty }
        switch term {
        case "BT-129" where hasUnit: return [("unitCode", "BT-130")]
        case "BT-149" where hasUnit: return [("unitCode", "BT-150")]
        default: return []
        }
    }

    private static func dynamicTerm(path: String, node: XMLTreeNode,
                                    ancestors: [XMLTreeNode],
                                    invoiceCurrency: String?) -> String? {
        // BT-110 vs. BT-111: Der Steuergesamtbetrag in Rechnungswährung ist
        // BT-110, der in abweichender Abrechnungswährung BT-111.
        if path == "\(set)/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TaxTotalAmount" {
            let currency = node.attributes.first { $0.name == "currencyID" }?.value
            if let currency, let invoiceCurrency, currency != invoiceCurrency {
                return "BT-111"
            }
            return "BT-110"
        }

        // USt-IdNr. vs. Steuernummer: schemeID "VA" = USt-IdNr., "FC" =
        // nationale Steuernummer; die BT-Nummer hängt zusätzlich an der Partei.
        if node.name == "ram:ID",
           let parent = ancestors.last, parent.name == "ram:SpecifiedTaxRegistration" {
            let scheme = node.attributes.first { $0.name == "schemeID" }?.value
            if path.contains("ram:SellerTradeParty/") {
                return scheme == "FC" ? "BT-32" : "BT-31"
            }
            if path.contains("ram:BuyerTradeParty/") {
                return scheme == "FC" ? nil : "BT-48"
            }
            if path.contains("ram:SellerTaxRepresentativeTradeParty/") {
                return "BT-63"
            }
            return nil
        }

        // Nachlass oder Zuschlag: entscheidet der ChargeIndicator im selben
        // Container; die BT-Nummern unterscheiden sich je Ebene UND Richtung.
        if let containerIndex = ancestors.lastIndex(where: { $0.name == "ram:SpecifiedTradeAllowanceCharge" })
            ?? (node.name == "ram:SpecifiedTradeAllowanceCharge" ? ancestors.count : nil) {
            // Preis-Nachlässe (AppliedTradeAllowanceCharge) sind fest gemappt.
            let container = containerIndex == ancestors.count ? node : ancestors[containerIndex]
            // XML Schema erlaubt für Boolean neben true/false auch 1/0. Ein
            // unbekannter oder fehlender Indikator bekommt bewusst KEINE
            // Zuordnung — sonst würde ein Zuschlag als Nachlass beschriftet.
            guard let isCharge = XMLTree.booleanText(
                XMLTree.firstNode(in: container,
                                  path: ["ram:ChargeIndicator", "udt:Indicator"])?.text)
            else { return nil }
            let isLine = path.contains("ram:IncludedSupplyChainTradeLineItem/")
            if node.name == "ram:SpecifiedTradeAllowanceCharge" {
                return isLine ? (isCharge ? "BG-28" : "BG-27")
                              : (isCharge ? "BG-21" : "BG-20")
            }
            switch node.name {
            case "ram:CalculationPercent":
                return isLine ? (isCharge ? "BT-143" : "BT-138")
                              : (isCharge ? "BT-101" : "BT-94")
            case "ram:BasisAmount":
                return isLine ? (isCharge ? "BT-142" : "BT-137")
                              : (isCharge ? "BT-100" : "BT-93")
            case "ram:ActualAmount":
                return isLine ? (isCharge ? "BT-141" : "BT-136")
                              : (isCharge ? "BT-99" : "BT-92")
            case "ram:Reason":
                return isLine ? (isCharge ? "BT-144" : "BT-139")
                              : (isCharge ? "BT-104" : "BT-97")
            case "ram:ReasonCode":
                return isLine ? (isCharge ? "BT-145" : "BT-140")
                              : (isCharge ? "BT-105" : "BT-98")
            case "ram:CategoryCode" where !isLine:
                return isCharge ? "BT-102" : "BT-95"
            case "ram:RateApplicablePercent" where !isLine:
                return isCharge ? "BT-103" : "BT-96"
            default:
                return nil
            }
        }

        // Rechnungsbegründende Unterlagen auf Kopfebene: Der TypeCode im
        // Container bestimmt, was die Kennung bedeutet (50 = Ausschreibung,
        // 130 = Rechnungsgegenstand, 916 = beigefügte Unterlage).
        if path.hasPrefix("\(agr)/ram:AdditionalReferencedDocument") {
            let container = node.name == "ram:AdditionalReferencedDocument"
                ? node : ancestors.last { $0.name == "ram:AdditionalReferencedDocument" }
            let typeCode = container.flatMap {
                XMLTree.firstNode(in: $0, path: ["ram:TypeCode"])?.text
            }
            switch node.name {
            case "ram:AdditionalReferencedDocument":
                return typeCode == "916" ? "BG-24" : nil
            case "ram:IssuerAssignedID":
                switch typeCode {
                case "50": return "BT-17"
                case "130": return "BT-18"
                default: return "BT-122"
                }
            case "ram:URIID": return "BT-124"
            case "ram:Name": return "BT-123"
            case "ram:AttachmentBinaryObject": return "BT-125"
            default: return nil
            }
        }

        return nil
    }
}
