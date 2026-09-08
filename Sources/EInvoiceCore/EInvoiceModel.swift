// Datenmodell des E-Rechnungs-Lesers. Nur Anzeige: Das Modell beschreibt,
// WAS in einer Rechnung steht (Profil, Syntax, Dokumentart, alle befüllten
// Felder mit EN-16931-Feldbezeichnung). Dazu kommt eine Grundvalidierung mit
// Warnhinweisen (Pflichtfelder, Summen) — keine vollständige
// Schematron-Prüfung, und nie ein Grund, die Anzeige zu verweigern.
import Foundation

/// Woher das Rechnungs-XML stammt.
public enum EInvoiceSource: Sendable, Codable, Equatable {
    /// Eigenständige XML-Datei.
    case xmlFile
    /// Aus einem PDF extrahiert (Dateiname des eingebetteten XML).
    case pdfEmbedded(fileName: String)
}

/// Die XML-Syntax der Rechnung.
public enum EInvoiceSyntax: String, Sendable, Codable {
    case cii = "UN/CEFACT CII"
    case ciiZUGFeRD1 = "UN/CEFACT CII (ZUGFeRD 1.0)"
    /// UN/CEFACT Cross Industry Order — die Syntax von Order-X. Der
    /// Wurzelname `SCRDMCCBDACIOMessageStructure` ist der offizielle
    /// Schemaname, kein Tippfehler.
    case ciiOrder = "UN/CEFACT CIO (Order-X)"
    case ublInvoice = "UBL Invoice"
    case ublCreditNote = "UBL CreditNote"
    case ublOrder = "UBL Order"
    case ublOrderResponse = "UBL OrderResponse"

    /// Bestellungen (Order-X, Peppol Order/OrderResponse) folgen nicht der
    /// EN 16931; ihre Felder tragen deshalb Order-X-Bezeichnungen statt
    /// BT-Nummern, und die Rechnungs-Prüfregeln gelten für sie nicht.
    public var isOrder: Bool {
        switch self {
        case .ciiOrder, .ublOrder, .ublOrderResponse: return true
        case .cii, .ciiZUGFeRD1, .ublInvoice, .ublCreditNote: return false
        }
    }
}

/// Dokumentart, unabhängig von der Syntax: Rechnung oder Gutschrift (beide
/// nach EN 16931) bzw. Bestellung oder Bestellantwort (Order-X, Peppol).
public enum EInvoiceDocumentKind: String, Sendable, Codable {
    case invoice
    case creditNote
    case order
    case orderResponse

    /// Deutsche Bezeichnung für Text-Ausgaben.
    public var germanName: String {
        switch self {
        case .invoice: return "Rechnung"
        case .creditNote: return "Gutschrift"
        case .order: return "Bestellung"
        case .orderResponse: return "Bestellantwort"
        }
    }
}

/// Ein Warnhinweis der Grundvalidierung. `code` ist die Regelkennung aus
/// EN 16931 (BR-…, BR-CO-…) bzw. XRechnung (BR-DE-…), `term` der betroffene
/// Business Term, `message` der deutsche Text für Anzeige und CLI.
public struct EInvoiceWarning: Sendable, Codable, Equatable {
    public var code: String
    public var term: String?
    public var message: String

    public init(code: String, term: String?, message: String) {
        self.code = code
        self.term = term
        self.message = message
    }
}

/// Aufgelöstes Profil aus dem Spezifikationskennzeichen (BT-24).
public struct EInvoiceProfile: Sendable, Codable, Equatable {
    /// Roh-URN aus BT-24 bzw. cbc:CustomizationID.
    public var guidelineID: String
    /// Standard-Familie, z.B. "Factur-X / ZUGFeRD", "XRechnung", "Peppol BIS".
    public var standard: String
    /// Profilname innerhalb des Standards, z.B. "EN 16931 (COMFORT)".
    public var profile: String
    /// Geschäftsprozess (BT-23), sofern angegeben.
    public var businessProcessID: String?
}

/// Deklaration der Rechnung in den XMP-Metadaten des Träger-PDFs
/// (Factur-X-/ZUGFeRD-Erweiterungsschema).
public struct EInvoicePDFDeclaration: Sendable, Codable, Equatable {
    public var documentType: String?      // z.B. "INVOICE"
    public var documentFileName: String?  // z.B. "factur-x.xml"
    public var version: String?           // z.B. "1.0"
    public var conformanceLevel: String?  // z.B. "EN 16931"

    public var isEmpty: Bool {
        documentType == nil && documentFileName == nil
            && version == nil && conformanceLevel == nil
    }
}

/// EN-16931-Zuordnung eines XML-Attributs. Einige Business Terms liegen in
/// beiden Syntaxen nicht als eigenes Element vor, sondern als Attribut am
/// Trägerelement — z.B. `unitCode` an der Menge (BT-130/BT-150) oder
/// `@name` am UBL-Zahlungsart-Code (BT-82).
public struct EInvoiceAttributeTerm: Sendable, Codable, Equatable {
    /// Attributname am Element, z.B. "unitCode".
    public var attribute: String
    /// EN-16931-Feldbezeichnung, z.B. "BT-130".
    public var term: String
    /// Deutscher Name des Business Terms, falls bekannt.
    public var termName: String?

    public init(attribute: String, term: String, termName: String?) {
        self.attribute = attribute
        self.term = term
        self.termName = termName
    }
}

/// Ein angezeigtes Feld: ein XML-Element in Dokumentreihenfolge mit optionaler
/// EN-16931-Zuordnung. Gruppen-Elemente (ohne eigenen Text) erscheinen mit
/// leerem `value` — sie tragen die BG-Zuordnung und die Baumstruktur.
public struct EInvoiceField: Sendable, Codable, Equatable {
    /// Einrücktiefe im Baum (Wurzel = 0).
    public var level: Int
    /// Kanonischer Elementname, z.B. "ram:ID".
    public var element: String
    /// Voller Pfad ohne Positionsindizes, z.B. "rsm:CrossIndustryInvoice/…".
    public var path: String
    /// Roher Textwert (unverändert aus dem XML; leer bei Gruppen).
    public var value: String
    /// Attribute wie unitCode, currencyID, schemeID, format.
    public var attributes: [XMLTreeAttribute]
    /// EN-16931-Feldbezeichnung ("BT-1", "BG-4"), falls zugeordnet. Bei
    /// Bestellungen (Order-X, Peppol Order) immer nil — sie haben keine
    /// BT-Nummern.
    public var term: String?
    /// Deutscher Name des Business Terms, falls zugeordnet; bei Bestellungen
    /// die Order-X-Bezeichnung des Feldes (ohne `term`).
    public var termName: String?
    /// Entschlüsselung bekannter Codewerte (z.B. TypeCode 380 → "Rechnung").
    public var valueNote: String?
    /// Attribute dieses Elements mit eigener EN-16931-Zuordnung
    /// (z.B. unitCode → BT-130); leer, wenn keines zugeordnet ist.
    public var attributeTerms: [EInvoiceAttributeTerm] = []
}

/// Kurzfassung für Listen-/Titelanzeigen. Bei Bestellungen stehen hier die
/// entsprechenden Bestellwerte (Bestellnummer, Bestelldatum, …).
public struct EInvoiceSummary: Sendable, Codable, Equatable {
    public var invoiceNumber: String?   // BT-1
    public var issueDate: String?       // BT-2 (roh, meist JJJJMMTT oder ISO)
    public var sellerName: String?      // BT-27
    public var buyerName: String?       // BT-44
    public var currency: String?        // BT-5
    public var payableAmount: String?   // BT-115
}

/// Vollständig gelesene E-Rechnung.
public struct EInvoiceDocument: Sendable, Codable {
    public var source: EInvoiceSource
    public var syntax: EInvoiceSyntax
    public var profile: EInvoiceProfile
    /// Rechnung, Gutschrift, Bestellung oder Bestellantwort.
    public var documentKind: EInvoiceDocumentKind
    /// Deklaration im Träger-PDF (nur bei source == .pdfEmbedded, falls vorhanden).
    public var pdfDeclaration: EInvoicePDFDeclaration?
    /// Alle Felder in Dokumentreihenfolge.
    public var fields: [EInvoiceField]
    public var summary: EInvoiceSummary
    /// Warnhinweise der Grundvalidierung (leer = nichts gefunden). Bei
    /// Bestellungen und ZUGFeRD 1.0 immer leer, weil dort keine
    /// EN-16931-Regeln gelten.
    public var warnings: [EInvoiceWarning] = []

    /// Wert des ersten Feldes mit dem gegebenen Business Term.
    public func firstValue(term: String) -> String? {
        fields.first { $0.term == term && !$0.value.isEmpty }?.value
    }
}

public enum EInvoiceError: Error, LocalizedError, Equatable {
    /// Datei enthält keine erkennbare E-Rechnung.
    case notAnInvoice
    /// PDF ließ sich nicht öffnen/lesen.
    case pdfUnreadable(String)
    /// XML syntaktisch kaputt.
    case xmlUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notAnInvoice:
            return "Keine E-Rechnung erkannt (ZUGFeRD/Factur-X/XRechnung/UBL/Order-X)."
        case .pdfUnreadable(let path):
            return "PDF nicht lesbar: \(path)"
        case .xmlUnreadable(let detail):
            return "Rechnungs-XML nicht lesbar: \(detail)"
        }
    }
}

// MARK: - Profil-Auflösung

extension EInvoiceProfile {

    /// Löst das Spezifikationskennzeichen (BT-24) in Standard + Profil auf.
    /// Unbekannte URNs bleiben sichtbar: Standard "EN 16931-basiert?" und die
    /// Roh-URN — lieber ehrlich unbekannt als falsch benannt.
    public static func resolve(guidelineID: String, businessProcessID: String? = nil,
                               syntax: EInvoiceSyntax) -> EInvoiceProfile {
        let urn = guidelineID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = urn.lowercased()
        // Eine CustomizationID reiht URNs mit "#" aneinander
        // ("urn:cen.eu:en16931:2017#compliant#urn:…:xrechnung_3.0"). Ein
        // bekannter Stamm zählt nur, wenn eine KOMPONENTE mit ihm beginnt —
        // eine bloße Teilzeichenfolge ("urn:example:urn:factur-x.eu:…") würde
        // fremde Kennungen als bekannten Standard ausgeben.
        let components = lower.components(separatedBy: "#")
        /// Die GEMATCHTE Komponente — nicht nur ein Ja/Nein.
        ///
        /// Version, Extension-Kennzeichen und Profil wurden vorher aus der
        /// GESAMTEN Rohkennung gezogen: `xrechnung_` case-sensitiv im
        /// Original-`urn`, `kosit:extension` global, und Factur-X bekam den
        /// ganzen String. Eine grossgeschriebene Komponente `XRECHNUNG_3.0`
        /// ergab damit „XRechnung URN", und eine nachgestellte fremde
        /// Komponente konnte Extension-Kennzeichen oder Profil liefern
        /// (Review-Fund 2026-08-17). Ausgewertet wird jetzt ausschliesslich
        /// die normalisierte Komponente, die wirklich gepasst hat.
        func matchedComponent(withPrefix marker: String) -> String? {
            components.first { $0.hasPrefix(marker) }
        }
        func hasComponent(withPrefix marker: String) -> Bool {
            matchedComponent(withPrefix: marker) != nil
        }

        func make(_ standard: String, _ profile: String) -> EInvoiceProfile {
            EInvoiceProfile(guidelineID: urn, standard: standard, profile: profile,
                            businessProcessID: businessProcessID)
        }

        // --- XRechnung (deutsche CIUS; KoSIT). URN-Stämme:
        // urn:xoev-de:kosit:standard:xrechnung_2.x (bis 2.3)
        // urn:xeinkauf.de:kosit:xrechnung_3.x (ab 3.0)
        let xrechnungMarkers = [
            "urn:xeinkauf.de:kosit:xrechnung_",
            "urn:xoev-de:kosit:standard:xrechnung_",
            "urn:xoev-de:kosit:extension:xrechnung_",
        ]
        if let matched = xrechnungMarkers.lazy
            .compactMap({ matchedComponent(withPrefix: $0) }).first {
            // Version, Extension und Name kommen NUR aus dieser Komponente.
            let version = matched.components(separatedBy: "xrechnung_").last
                .map { $0.components(separatedBy: CharacterSet(charactersIn: "#:")).first ?? $0 }
                .flatMap { $0.isEmpty ? nil : $0 }
            let extended = matched.contains("kosit:extension")
            let name = "XRechnung" + (version.map { " \($0)" } ?? "")
                + (extended ? " (mit Extension)" : "")
            return make("XRechnung", name)
        }

        // --- Peppol BIS Billing
        if hasComponent(withPrefix: "urn:fdc:peppol.eu:2017:poacc:billing:") {
            return make("Peppol BIS", "Peppol BIS Billing 3.0")
        }

        // --- Peppol BIS Ordering (UBL Order / OrderResponse). Die
        // CustomizationID nennt die Transaktion: …:trns:order:3 bzw.
        // …:trns:order_response:3.
        if hasComponent(withPrefix: "urn:fdc:peppol.eu:poacc:trns:order_response:") {
            return make("Peppol BIS", "Peppol BIS Order Response")
        }
        if hasComponent(withPrefix: "urn:fdc:peppol.eu:poacc:trns:order:") {
            return make("Peppol BIS", "Peppol BIS Order")
        }

        // --- Order-X (Bestellungen im ZUGFeRD-Stil, CIO-Syntax). URN-Stamm
        // urn:order-x.eu:1p0:basic|comfort|extended.
        if let matched = matchedComponent(withPrefix: "urn:order-x.eu:") {
            return make("Order-X", orderXProfileName(from: matched))
        }

        // --- Factur-X / ZUGFeRD 2.1+ (gemeinsamer Standard, URN-Stamm factur-x.eu)
        if let matched = matchedComponent(withPrefix: "urn:factur-x.eu:") {
            return make("Factur-X / ZUGFeRD", facturXProfileName(from: matched))
        }

        // --- ZUGFeRD 2.0 (eigener URN-Stamm zugferd.de:2p0)
        if let matched = matchedComponent(withPrefix: "urn:zugferd.de:2p0:") {
            return make("ZUGFeRD 2.0", facturXProfileName(from: matched))
        }

        // --- ZUGFeRD 1.0 (vor EN 16931)
        if lower.hasPrefix("urn:ferd:crossindustrydocument") {
            let profile = urn.components(separatedBy: ":").last?.uppercased() ?? "?"
            return make("ZUGFeRD 1.0", profile)
        }

        // --- Reine EN 16931 (Kernrechnung ohne CIUS-Einschränkung).
        // Das ist zugleich das Profil "EN 16931 (COMFORT)" von Factur-X/ZUGFeRD —
        // ob ein PDF-Kontext dazugehört, sieht man an der PDF-Deklaration.
        if lower == "urn:cen.eu:en16931:2017" {
            return make("EN 16931", "EN 16931 (COMFORT)")
        }

        if urn.isEmpty {
            return make("Unbekannt", "kein Spezifikationskennzeichen (BT-24)")
        }
        return make("EN 16931-basiert?", urn)
    }

    /// Profilstufe aus einer Order-X-URN: BASIC, COMFORT oder EXTENDED.
    /// Unbekannte Stufen bleiben als letztes Segment sichtbar.
    private static func orderXProfileName(from lowerURN: String) -> String {
        if lowerURN.hasSuffix(":basic") { return "BASIC" }
        if lowerURN.hasSuffix(":comfort") { return "COMFORT" }
        if lowerURN.hasSuffix(":extended") { return "EXTENDED" }
        return lowerURN.components(separatedBy: ":").last?.uppercased() ?? "?"
    }

    /// Profilstufe aus einer Factur-X-/ZUGFeRD-URN (letztes Pfadsegment).
    private static func facturXProfileName(from lowerURN: String) -> String {
        if lowerURN.hasSuffix(":minimum") { return "MINIMUM" }
        if lowerURN.hasSuffix(":basicwl") { return "BASIC WL" }
        if lowerURN.hasSuffix(":basic") { return "BASIC" }
        if lowerURN.hasSuffix(":en16931") || lowerURN.hasSuffix("#en16931") {
            return "EN 16931 (COMFORT)"
        }
        if lowerURN.hasSuffix(":extended") { return "EXTENDED" }
        // z.B. XRechnung-Referenzprofil älterer ZUGFeRD-Fassungen
        return lowerURN.components(separatedBy: ":").last?.uppercased() ?? "?"
    }
}
