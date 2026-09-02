// Grundvalidierung mit Warnhinweisen — bewusst KEINE vollständige
// Schematron-Prüfung. Geprüft werden nur zwei Dinge, die sich aus dem
// gelesenen Modell sicher ableiten lassen:
//
// 1. Pflichtfelder nach EN 16931 (Kopfangaben und Summen), bei XRechnung
//    zusätzlich die Leitweg-ID (BT-10).
// 2. Die Summenrechnung der Gesamtsummen (BG-22) mit einer Toleranz von
//    0,01 je Rechnung: BT-106 = Σ BT-131, BT-109 = BT-106 − BT-107 + BT-108,
//    BT-112 = BT-109 + BT-110, BT-115 = BT-112 − BT-113 + BT-114 und
//    BT-110 = Σ BT-117.
//
// Die Regelkennungen sind die der EN 16931 (BR-…, BR-CO-…) bzw. der
// XRechnung (BR-DE-…), damit ein Hinweis in Validatoren wiederzufinden ist.
// Warnungen verhindern nie die Anzeige; sie sind ein Zusatz.
import Foundation

enum EInvoiceValidation {

    /// Erlaubte Abweichung je Summenregel (Rundungsdifferenzen).
    static let tolerance = Decimal(string: "0.01")!

    /// Alle Hinweise zu einem gelesenen Dokument. Bestellungen und ZUGFeRD 1.0
    /// liefern eine leere Liste — für sie gelten die EN-16931-Regeln nicht.
    static func warnings(for document: EInvoiceDocument) -> [EInvoiceWarning] {
        guard !document.syntax.isOrder, document.syntax != .ciiZUGFeRD1 else { return [] }
        var warnings: [EInvoiceWarning] = []
        checkRequiredFields(document, into: &warnings)
        checkSums(document, into: &warnings)
        return warnings
    }

    // MARK: - Pflichtfelder

    /// Regelkennung, Business Term — Reihenfolge wie in der Norm.
    private static let requiredTerms: [(code: String, term: String)] = [
        ("BR-02", "BT-1"), ("BR-03", "BT-2"), ("BR-04", "BT-3"), ("BR-05", "BT-5"),
        ("BR-06", "BT-27"), ("BR-07", "BT-44"),
        ("BR-12", "BT-106"), ("BR-13", "BT-109"), ("BR-14", "BT-112"), ("BR-15", "BT-115"),
    ]

    private static func checkRequiredFields(_ document: EInvoiceDocument,
                                            into warnings: inout [EInvoiceWarning]) {
        // Die Profile MINIMUM und BASIC WL von Factur-X/ZUGFeRD führen keine
        // Positionen — dort ist die Positionssumme (BT-106) nicht verlangt.
        let profile = document.profile.profile.uppercased()
        let hasNoLines = profile == "MINIMUM" || profile == "BASIC WL"
        for rule in requiredTerms {
            if rule.term == "BT-106" && hasNoLines { continue }
            if document.firstValue(term: rule.term) == nil {
                warnings.append(missing(code: rule.code, term: rule.term))
            }
        }
        // XRechnung verlangt die Leitweg-ID in der Käuferreferenz (BT-10).
        if document.profile.standard == "XRechnung", document.firstValue(term: "BT-10") == nil {
            warnings.append(missing(code: "BR-DE-15", term: "BT-10"))
        }
    }

    private static func missing(code: String, term: String) -> EInvoiceWarning {
        EInvoiceWarning(code: code, term: term,
                        message: "Pflichtfeld fehlt: \(describe(term))")
    }

    // MARK: - Summen

    private static func checkSums(_ document: EInvoiceDocument,
                                  into warnings: inout [EInvoiceWarning]) {
        let currency = document.summary.currency
        /// Erster Betrag zu einem Term; nil, wenn er fehlt oder nicht lesbar ist.
        func amount(_ term: String) -> Decimal? {
            document.firstValue(term: term).flatMap(parseAmount)
        }
        /// Summe ALLER Beträge eines Terms in Rechnungswährung. Beträge in
        /// einer abweichenden Währung (currencyID ≠ BT-5) bleiben draußen —
        /// UBL wiederholt die Steueraufschlüsselung in der Steuerwährung.
        func sum(_ term: String) -> (total: Decimal, count: Int)? {
            var total = Decimal(0)
            var count = 0
            for field in document.fields where field.term == term && !field.value.isEmpty {
                if let fieldCurrency = field.attributes.first(where: { $0.name == "currencyID" })?.value,
                   let currency, fieldCurrency != currency {
                    continue
                }
                guard let value = parseAmount(field.value) else { return nil }
                total += value
                count += 1
            }
            return count == 0 ? nil : (total, count)
        }

        // BR-CO-10: BT-106 = Σ BT-131 (nur, wenn Positionen vorhanden sind).
        if let lineTotal = amount("BT-106"), let lines = sum("BT-131") {
            compare("BR-CO-10", term: "BT-106", actual: lineTotal, expected: lines.total,
                    formula: "Summe der \(lines.count) Positionsbeträge (BT-131)",
                    into: &warnings)
        }

        // BR-CO-13: BT-109 = BT-106 − BT-107 + BT-108.
        if let base = amount("BT-109"), let lineTotal = amount("BT-106") {
            let expected = lineTotal - (amount("BT-107") ?? 0) + (amount("BT-108") ?? 0)
            compare("BR-CO-13", term: "BT-109", actual: base, expected: expected,
                    formula: "BT-106 − BT-107 + BT-108", into: &warnings)
        }

        // BR-CO-14: BT-110 = Σ BT-117 — nur, wenn es überhaupt eine
        // Umsatzsteuerangabe gibt (Steuersumme oder Aufschlüsselung).
        let taxTotal = amount("BT-110")
        let taxParts = sum("BT-117")
        if taxTotal != nil || taxParts != nil {
            compare("BR-CO-14", term: "BT-110", actual: taxTotal ?? 0, expected: taxParts?.total ?? 0,
                    formula: "Summe der Steuerbeträge (BT-117)", into: &warnings)
        }

        // BR-CO-15: BT-112 = BT-109 + BT-110.
        if let grand = amount("BT-112"), let base = amount("BT-109") {
            compare("BR-CO-15", term: "BT-112", actual: grand, expected: base + (taxTotal ?? 0),
                    formula: "BT-109 + BT-110", into: &warnings)
        }

        // BR-CO-16: BT-115 = BT-112 − BT-113 + BT-114.
        if let payable = amount("BT-115"), let grand = amount("BT-112") {
            let expected = grand - (amount("BT-113") ?? 0) + (amount("BT-114") ?? 0)
            compare("BR-CO-16", term: "BT-115", actual: payable, expected: expected,
                    formula: "BT-112 − BT-113 + BT-114", into: &warnings)
        }
    }

    private static func compare(_ code: String, term: String, actual: Decimal, expected: Decimal,
                                formula: String, into warnings: inout [EInvoiceWarning]) {
        guard abs(actual - expected) > tolerance else { return }
        warnings.append(EInvoiceWarning(
            code: code, term: term,
            message: "Summenprüfung: \(describe(term)) ist \(format(actual)), "
                + "erwartet \(format(expected)) (\(formula))."))
    }

    // MARK: - Helfer

    /// Betrag nach EN 16931: Dezimalpunkt, kein Tausendertrenner. Alles
    /// andere gilt als nicht lesbar und lässt die Regel aus.
    static func parseAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }),
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return value
    }

    /// Immer zwei Nachkommastellen, Dezimalpunkt — wie die Beträge im XML.
    private static func format(_ value: Decimal) -> String {
        var rounded = value
        var source = value
        NSDecimalRound(&rounded, &source, 2, .plain)
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                      NSDecimalNumber(decimal: rounded).doubleValue)
    }

    private static func describe(_ term: String) -> String {
        if let name = EN16931.name(for: term) { return "\(term) \(name)" }
        return term
    }
}
