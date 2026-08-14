// Pfad→Business-Term-Zuordnung für die UBL-Syntax (OASIS UBL 2.1):
// UBL-Variante der XRechnung und Peppol BIS Billing. Grundlage ist das
// Syntax-Binding EN 16931-3-2.
//
// Gutschriften (ubl:CreditNote) verwenden dieselbe Struktur mit wenigen
// umbenannten Elementen — die Suche normalisiert Gutschrift-Pfade auf die
// Invoice-Namen, statt jede Tabelle doppelt zu pflegen.
import Foundation

enum UBLMapping {

    private static let root = "ubl:Invoice"

    static let fixed: [String: String] = {
        var map: [String: String] = [:]

        // --- Dokumentkopf
        map["\(root)/cbc:CustomizationID"] = "BT-24"
        map["\(root)/cbc:ProfileID"] = "BT-23"
        map["\(root)/cbc:ID"] = "BT-1"
        map["\(root)/cbc:IssueDate"] = "BT-2"
        map["\(root)/cbc:DueDate"] = "BT-9"
        map["\(root)/cbc:InvoiceTypeCode"] = "BT-3"
        map["\(root)/cbc:Note"] = "BT-22"
        map["\(root)/cbc:TaxPointDate"] = "BT-7"
        map["\(root)/cbc:DocumentCurrencyCode"] = "BT-5"
        map["\(root)/cbc:TaxCurrencyCode"] = "BT-6"
        map["\(root)/cbc:AccountingCost"] = "BT-19"
        map["\(root)/cbc:BuyerReference"] = "BT-10"

        // --- Zeitraum und Referenzen
        map["\(root)/cac:InvoicePeriod"] = "BG-14"
        map["\(root)/cac:InvoicePeriod/cbc:StartDate"] = "BT-73"
        map["\(root)/cac:InvoicePeriod/cbc:EndDate"] = "BT-74"
        map["\(root)/cac:InvoicePeriod/cbc:DescriptionCode"] = "BT-8"
        map["\(root)/cac:OrderReference/cbc:ID"] = "BT-13"
        map["\(root)/cac:OrderReference/cbc:SalesOrderID"] = "BT-14"
        map["\(root)/cac:BillingReference"] = "BG-3"
        map["\(root)/cac:BillingReference/cac:InvoiceDocumentReference/cbc:ID"] = "BT-25"
        map["\(root)/cac:BillingReference/cac:InvoiceDocumentReference/cbc:IssueDate"] = "BT-26"
        map["\(root)/cac:DespatchDocumentReference/cbc:ID"] = "BT-16"
        map["\(root)/cac:ReceiptDocumentReference/cbc:ID"] = "BT-15"
        map["\(root)/cac:OriginatorDocumentReference/cbc:ID"] = "BT-17"
        map["\(root)/cac:ContractDocumentReference/cbc:ID"] = "BT-12"
        map["\(root)/cac:ProjectReference/cbc:ID"] = "BT-11"

        // Rechnungsbegründende Unterlagen (BG-24) — cbc:ID löst der dynamische
        // Teil auf (BT-18 bei DocumentTypeCode 130, sonst BT-122).
        let addDoc = "\(root)/cac:AdditionalDocumentReference"
        map[addDoc] = "BG-24"
        map["\(addDoc)/cbc:DocumentTypeCode"] = ""  // Platzhalter, dynamisch
        map["\(addDoc)/cbc:DocumentDescription"] = "BT-123"
        map["\(addDoc)/cac:Attachment/cbc:EmbeddedDocumentBinaryObject"] = "BT-125"
        map["\(addDoc)/cac:Attachment/cac:ExternalReference/cbc:URI"] = "BT-124"

        // --- Verkäufer (BG-4/5/6)
        let seller = "\(root)/cac:AccountingSupplierParty"
        map[seller] = "BG-4"
        map["\(seller)/cac:Party/cbc:EndpointID"] = "BT-34"
        map["\(seller)/cac:Party/cac:PartyIdentification/cbc:ID"] = "BT-29"
        map["\(seller)/cac:Party/cac:PartyName/cbc:Name"] = "BT-28"
        addAddress(&map, base: "\(seller)/cac:Party/cac:PostalAddress",
                   group: "BG-5", line1: "BT-35", line2: "BT-36", line3: "BT-162",
                   city: "BT-37", postcode: "BT-38", region: "BT-39", country: "BT-40")
        map["\(seller)/cac:Party/cac:PartyLegalEntity/cbc:RegistrationName"] = "BT-27"
        map["\(seller)/cac:Party/cac:PartyLegalEntity/cbc:CompanyID"] = "BT-30"
        map["\(seller)/cac:Party/cac:PartyLegalEntity/cbc:CompanyLegalForm"] = "BT-33"
        map["\(seller)/cac:Party/cac:Contact"] = "BG-6"
        map["\(seller)/cac:Party/cac:Contact/cbc:Name"] = "BT-41"
        map["\(seller)/cac:Party/cac:Contact/cbc:Telephone"] = "BT-42"
        map["\(seller)/cac:Party/cac:Contact/cbc:ElectronicMail"] = "BT-43"

        // --- Käufer (BG-7/8/9)
        let buyer = "\(root)/cac:AccountingCustomerParty"
        map[buyer] = "BG-7"
        map["\(buyer)/cac:Party/cbc:EndpointID"] = "BT-49"
        map["\(buyer)/cac:Party/cac:PartyIdentification/cbc:ID"] = "BT-46"
        map["\(buyer)/cac:Party/cac:PartyName/cbc:Name"] = "BT-45"
        addAddress(&map, base: "\(buyer)/cac:Party/cac:PostalAddress",
                   group: "BG-8", line1: "BT-50", line2: "BT-51", line3: "BT-163",
                   city: "BT-52", postcode: "BT-53", region: "BT-54", country: "BT-55")
        map["\(buyer)/cac:Party/cac:PartyLegalEntity/cbc:RegistrationName"] = "BT-44"
        map["\(buyer)/cac:Party/cac:PartyLegalEntity/cbc:CompanyID"] = "BT-47"
        map["\(buyer)/cac:Party/cac:Contact"] = "BG-9"
        map["\(buyer)/cac:Party/cac:Contact/cbc:Name"] = "BT-56"
        map["\(buyer)/cac:Party/cac:Contact/cbc:Telephone"] = "BT-57"
        map["\(buyer)/cac:Party/cac:Contact/cbc:ElectronicMail"] = "BT-58"

        // --- Zahlungsempfänger (BG-10)
        let payee = "\(root)/cac:PayeeParty"
        map[payee] = "BG-10"
        map["\(payee)/cac:PartyIdentification/cbc:ID"] = "BT-60"
        map["\(payee)/cac:PartyName/cbc:Name"] = "BT-59"
        map["\(payee)/cac:PartyLegalEntity/cbc:CompanyID"] = "BT-61"

        // --- Steuerbevollmächtigter (BG-11/12)
        let taxRep = "\(root)/cac:TaxRepresentativeParty"
        map[taxRep] = "BG-11"
        map["\(taxRep)/cac:PartyName/cbc:Name"] = "BT-62"
        addAddress(&map, base: "\(taxRep)/cac:PostalAddress",
                   group: "BG-12", line1: "BT-64", line2: "BT-65", line3: "BT-164",
                   city: "BT-66", postcode: "BT-67", region: "BT-68", country: "BT-69")

        // --- Lieferung (BG-13/15)
        let delivery = "\(root)/cac:Delivery"
        map[delivery] = "BG-13"
        map["\(delivery)/cbc:ActualDeliveryDate"] = "BT-72"
        map["\(delivery)/cac:DeliveryLocation/cbc:ID"] = "BT-71"
        addAddress(&map, base: "\(delivery)/cac:DeliveryLocation/cac:Address",
                   group: "BG-15", line1: "BT-75", line2: "BT-76", line3: "BT-165",
                   city: "BT-77", postcode: "BT-78", region: "BT-79", country: "BT-80")
        map["\(delivery)/cac:DeliveryParty/cac:PartyName/cbc:Name"] = "BT-70"

        // --- Zahlung (BG-16/17/18/19)
        let means = "\(root)/cac:PaymentMeans"
        map[means] = "BG-16"
        map["\(means)/cbc:PaymentMeansCode"] = "BT-81"
        map["\(means)/cbc:PaymentID"] = "BT-83"
        map["\(means)/cac:CardAccount"] = "BG-18"
        map["\(means)/cac:CardAccount/cbc:PrimaryAccountNumberID"] = "BT-87"
        map["\(means)/cac:CardAccount/cbc:HolderName"] = "BT-88"
        map["\(means)/cac:PayeeFinancialAccount"] = "BG-17"
        map["\(means)/cac:PayeeFinancialAccount/cbc:ID"] = "BT-84"
        map["\(means)/cac:PayeeFinancialAccount/cbc:Name"] = "BT-85"
        map["\(means)/cac:PayeeFinancialAccount/cac:FinancialInstitutionBranch/cbc:ID"] = "BT-86"
        map["\(means)/cac:PaymentMandate"] = "BG-19"
        map["\(means)/cac:PaymentMandate/cbc:ID"] = "BT-89"
        map["\(means)/cac:PaymentMandate/cac:PayerFinancialAccount/cbc:ID"] = "BT-91"
        map["\(root)/cac:PaymentTerms/cbc:Note"] = "BT-20"

        // --- Umsatzsteuer (BG-23) — cac:TaxTotal/cbc:TaxAmount ist dynamisch
        // (BT-110/BT-111 je Währung).
        let subtotal = "\(root)/cac:TaxTotal/cac:TaxSubtotal"
        map[subtotal] = "BG-23"
        map["\(subtotal)/cbc:TaxableAmount"] = "BT-116"
        map["\(subtotal)/cbc:TaxAmount"] = "BT-117"
        map["\(subtotal)/cac:TaxCategory/cbc:ID"] = "BT-118"
        map["\(subtotal)/cac:TaxCategory/cbc:Percent"] = "BT-119"
        map["\(subtotal)/cac:TaxCategory/cbc:TaxExemptionReasonCode"] = "BT-121"
        map["\(subtotal)/cac:TaxCategory/cbc:TaxExemptionReason"] = "BT-120"

        // --- Gesamtsummen (BG-22)
        let totals = "\(root)/cac:LegalMonetaryTotal"
        map[totals] = "BG-22"
        map["\(totals)/cbc:LineExtensionAmount"] = "BT-106"
        map["\(totals)/cbc:TaxExclusiveAmount"] = "BT-109"
        map["\(totals)/cbc:TaxInclusiveAmount"] = "BT-112"
        map["\(totals)/cbc:AllowanceTotalAmount"] = "BT-107"
        map["\(totals)/cbc:ChargeTotalAmount"] = "BT-108"
        map["\(totals)/cbc:PrepaidAmount"] = "BT-113"
        map["\(totals)/cbc:PayableRoundingAmount"] = "BT-114"
        map["\(totals)/cbc:PayableAmount"] = "BT-115"

        // --- Rechnungsposition (BG-25 …)
        let line = "\(root)/cac:InvoiceLine"
        map[line] = "BG-25"
        map["\(line)/cbc:ID"] = "BT-126"
        map["\(line)/cbc:Note"] = "BT-127"
        map["\(line)/cbc:InvoicedQuantity"] = "BT-129"
        map["\(line)/cbc:LineExtensionAmount"] = "BT-131"
        map["\(line)/cbc:AccountingCost"] = "BT-133"
        map["\(line)/cac:InvoicePeriod"] = "BG-26"
        map["\(line)/cac:InvoicePeriod/cbc:StartDate"] = "BT-134"
        map["\(line)/cac:InvoicePeriod/cbc:EndDate"] = "BT-135"
        map["\(line)/cac:OrderLineReference/cbc:LineID"] = "BT-132"
        map["\(line)/cac:DocumentReference/cbc:ID"] = "BT-128"

        let item = "\(line)/cac:Item"
        map[item] = "BG-31"
        map["\(item)/cbc:Description"] = "BT-154"
        map["\(item)/cbc:Name"] = "BT-153"
        map["\(item)/cac:BuyersItemIdentification/cbc:ID"] = "BT-156"
        map["\(item)/cac:SellersItemIdentification/cbc:ID"] = "BT-155"
        map["\(item)/cac:StandardItemIdentification/cbc:ID"] = "BT-157"
        map["\(item)/cac:OriginCountry/cbc:IdentificationCode"] = "BT-159"
        map["\(item)/cac:CommodityClassification/cbc:ItemClassificationCode"] = "BT-158"
        map["\(item)/cac:ClassifiedTaxCategory"] = "BG-30"
        map["\(item)/cac:ClassifiedTaxCategory/cbc:ID"] = "BT-151"
        map["\(item)/cac:ClassifiedTaxCategory/cbc:Percent"] = "BT-152"
        map["\(item)/cac:AdditionalItemProperty"] = "BG-32"
        map["\(item)/cac:AdditionalItemProperty/cbc:Name"] = "BT-160"
        map["\(item)/cac:AdditionalItemProperty/cbc:Value"] = "BT-161"

        let price = "\(line)/cac:Price"
        map[price] = "BG-29"
        map["\(price)/cbc:PriceAmount"] = "BT-146"
        map["\(price)/cbc:BaseQuantity"] = "BT-149"
        map["\(price)/cac:AllowanceCharge/cbc:Amount"] = "BT-147"
        map["\(price)/cac:AllowanceCharge/cbc:BaseAmount"] = "BT-148"

        return map
    }()

    private static func addAddress(
        _ map: inout [String: String], base: String, group: String,
        line1: String, line2: String, line3: String,
        city: String, postcode: String, region: String, country: String
    ) {
        map[base] = group
        map["\(base)/cbc:StreetName"] = line1
        map["\(base)/cbc:AdditionalStreetName"] = line2
        map["\(base)/cbc:CityName"] = city
        map["\(base)/cbc:PostalZone"] = postcode
        map["\(base)/cbc:CountrySubentity"] = region
        map["\(base)/cac:AddressLine/cbc:Line"] = line3
        map["\(base)/cac:Country/cbc:IdentificationCode"] = country
    }

    // MARK: - Dynamische Zuordnung

    /// Gutschrift-Pfade auf Invoice-Namen normalisieren, damit eine Tabelle
    /// für beide Wurzeln reicht.
    static func normalizedPath(_ path: String) -> String {
        guard path.hasPrefix("ubl:CreditNote") else { return path }
        return path
            .replacingOccurrences(of: "ubl:CreditNote", with: "ubl:Invoice")
            .replacingOccurrences(of: "cac:CreditNoteLine", with: "cac:InvoiceLine")
            .replacingOccurrences(of: "cbc:CreditNoteTypeCode", with: "cbc:InvoiceTypeCode")
            .replacingOccurrences(of: "cbc:CreditedQuantity", with: "cbc:InvoicedQuantity")
    }

    static func term(path rawPath: String, node: XMLTreeNode,
                     ancestors: [XMLTreeNode], invoiceCurrency: String?) -> String? {
        let path = normalizedPath(rawPath)
        if let dynamicTerm = dynamicTerm(path: path, node: node, ancestors: ancestors,
                                         invoiceCurrency: invoiceCurrency) {
            return dynamicTerm
        }
        let term = fixed[path]
        return term?.isEmpty == true ? nil : term
    }

    private static func dynamicTerm(path: String, node: XMLTreeNode,
                                    ancestors: [XMLTreeNode],
                                    invoiceCurrency: String?) -> String? {
        // BT-110 vs. BT-111 je Währung des Steuergesamtbetrags.
        if path == "\(root)/cac:TaxTotal/cbc:TaxAmount" {
            let currency = node.attributes.first { $0.name == "currencyID" }?.value
            if let currency, let invoiceCurrency, currency != invoiceCurrency {
                return "BT-111"
            }
            return "BT-110"
        }

        // USt-IdNr. vs. Steuernummer: entscheidet die cac:TaxScheme/cbc:ID
        // ("VAT" oder anderes) im selben PartyTaxScheme — plus die Partei.
        if node.name == "cbc:CompanyID",
           let parent = ancestors.last, parent.name == "cac:PartyTaxScheme" {
            let scheme = XMLTree.firstNode(in: parent, path: ["cac:TaxScheme", "cbc:ID"])?
                .text.uppercased()
            let isVAT = scheme == nil || scheme == "VAT"
            if path.contains("cac:AccountingSupplierParty/") {
                return isVAT ? "BT-31" : "BT-32"
            }
            if path.contains("cac:AccountingCustomerParty/") {
                return isVAT ? "BT-48" : nil
            }
            if path.contains("cac:TaxRepresentativeParty/") {
                return "BT-63"
            }
            return nil
        }

        // Kennung einer Zusatz-Unterlage: DocumentTypeCode 130 macht sie zur
        // Kennung des Rechnungsgegenstands (BT-18), sonst BT-122.
        if path == "\(root)/cac:AdditionalDocumentReference/cbc:ID" {
            let typeCode = ancestors.last.flatMap {
                XMLTree.firstNode(in: $0, path: ["cbc:DocumentTypeCode"])?.text
            }
            return typeCode == "130" ? "BT-18" : "BT-122"
        }

        // Nachlass/Zuschlag: cbc:ChargeIndicator entscheidet; Positionsebene
        // erkennt man am cac:InvoiceLine im Pfad. (cac:Price/cac:AllowanceCharge
        // ist fest gemappt und läuft hier nicht durch.)
        if path.contains("cac:Price/cac:AllowanceCharge") { return nil }
        if let containerIndex = ancestors.lastIndex(where: { $0.name == "cac:AllowanceCharge" })
            ?? (node.name == "cac:AllowanceCharge" ? ancestors.count : nil) {
            let container = containerIndex == ancestors.count ? node : ancestors[containerIndex]
            let isCharge = XMLTree.firstNode(in: container, path: ["cbc:ChargeIndicator"])?
                .text.lowercased() == "true"
            let isLine = path.contains("cac:InvoiceLine/")
            switch node.name {
            case "cac:AllowanceCharge":
                return isLine ? (isCharge ? "BG-28" : "BG-27")
                              : (isCharge ? "BG-21" : "BG-20")
            case "cbc:AllowanceChargeReasonCode":
                return isLine ? (isCharge ? "BT-145" : "BT-140")
                              : (isCharge ? "BT-105" : "BT-98")
            case "cbc:AllowanceChargeReason":
                return isLine ? (isCharge ? "BT-144" : "BT-139")
                              : (isCharge ? "BT-104" : "BT-97")
            case "cbc:MultiplierFactorNumeric":
                return isLine ? (isCharge ? "BT-143" : "BT-138")
                              : (isCharge ? "BT-101" : "BT-94")
            case "cbc:Amount":
                return isLine ? (isCharge ? "BT-141" : "BT-136")
                              : (isCharge ? "BT-99" : "BT-92")
            case "cbc:BaseAmount":
                return isLine ? (isCharge ? "BT-142" : "BT-137")
                              : (isCharge ? "BT-100" : "BT-93")
            case "cbc:ID" where !isLine && ancestors.last?.name == "cac:TaxCategory":
                return isCharge ? "BT-102" : "BT-95"
            case "cbc:Percent" where !isLine && ancestors.last?.name == "cac:TaxCategory":
                return isCharge ? "BT-103" : "BT-96"
            default:
                return nil
            }
        }

        return nil
    }
}
