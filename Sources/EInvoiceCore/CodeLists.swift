// Entschlüsselung häufiger Codewerte, damit die Anzeige nicht bei "380"
// oder "Z" stehen bleibt. Bewusst nur die im Rechnungsalltag üblichen
// Einträge — unbekannte Codes bleiben unkommentiert sichtbar, werden also
// nie falsch übersetzt.
import Foundation

enum CodeLists {

    /// UNTDID 1001 — Dokumententyp (BT-3).
    static let documentType: [String: String] = [
        "71": "Zahlungsaufforderung",
        "80": "Belastungsanzeige zu Warenlieferung",
        "81": "Gutschriftsanzeige zu Warenlieferung",
        "82": "Getaktete Dienstleistungsrechnung",
        "84": "Belastungsanzeige zu Finanzanpassungen",
        "102": "Steuerbescheid/-mitteilung",
        "218": "Endabrechnung",
        "219": "Abschlagsrechnung (Bauleistung)",
        "326": "Teilrechnung",
        "331": "Buchungshilfe",
        "380": "Rechnung",
        "381": "Gutschrift (Storno)",
        "382": "Provisionsmitteilung",
        "383": "Belastungsanzeige (Zuschlag)",
        "384": "Rechnungskorrektur",
        "385": "Konsolidierte Rechnung",
        "386": "Vorauszahlungsrechnung",
        "387": "Mietrechnung",
        "388": "Steuerrechnung",
        "389": "Selbstfakturierte Rechnung (Gutschriftsverfahren)",
        "390": "Delkredere-Rechnung",
        "393": "Inkasso-Rechnung",
        "394": "Leasing-Rechnung",
        "395": "Konsignationsrechnung",
        "575": "Rechnung des Versicherers",
        "623": "Speditionsrechnung",
        "780": "Frachtrechnung",
        "875": "Teilrechnung Bauleistung",
        "876": "Teilschlussrechnung Bauleistung",
        "877": "Schlussrechnung Bauleistung",
    ]

    /// UNTDID 5305 — Umsatzsteuerkategorie (BT-118, BT-151, BT-95, BT-102).
    static let vatCategory: [String: String] = [
        "S": "Normalsatz",
        "Z": "Nullsatz (0 %)",
        "E": "Steuerbefreit",
        "AE": "Umkehr der Steuerschuld (Reverse Charge)",
        "K": "Innergemeinschaftliche Lieferung (steuerfrei)",
        "G": "Ausfuhr (steuerfrei)",
        "O": "Nicht im Anwendungsbereich der USt",
        "L": "Kanarische Inseln (IGIC)",
        "M": "Ceuta/Melilla (IPSI)",
    ]

    /// UNTDID 4461 — Zahlungsart (BT-81).
    static let paymentMeans: [String: String] = [
        "1": "Nicht festgelegt",
        "10": "Bar",
        "20": "Scheck",
        "30": "Überweisung",
        "42": "Zahlung auf Bankkonto",
        "48": "Kartenzahlung",
        "49": "Lastschrift",
        "54": "Kreditkarte",
        "55": "Debitkarte",
        "57": "Dauerauftrag",
        "58": "SEPA-Überweisung",
        "59": "SEPA-Lastschrift",
        "68": "Online-Zahlungsdienst",
        "97": "Verrechnung (Clearing)",
        "ZZZ": "Bilateral vereinbart",
    ]

    /// UN/ECE Rec. 20/21 — häufige Maßeinheiten (unitCode, BT-130/BT-150).
    static let unitCode: [String: String] = [
        "C62": "Stück (Einheit)",
        "H87": "Stück",
        "XPP": "Stück (unverpackt)",
        "PCE": "Stück",
        "EA": "je Einheit",
        "NAR": "Anzahl Artikel",
        "PR": "Paar",
        "SET": "Satz/Set",
        "DAY": "Tag(e)",
        "HUR": "Stunde(n)",
        "MIN": "Minute(n)",
        "SEC": "Sekunde(n)",
        "WEE": "Woche(n)",
        "MON": "Monat(e)",
        "ANN": "Jahr(e)",
        "KGM": "Kilogramm",
        "GRM": "Gramm",
        "TNE": "Tonne(n)",
        "LTR": "Liter",
        "MLT": "Milliliter",
        "MTR": "Meter",
        "CMT": "Zentimeter",
        "MMT": "Millimeter",
        "KMT": "Kilometer",
        "MTK": "Quadratmeter",
        "MTQ": "Kubikmeter",
        "KWH": "Kilowattstunde(n)",
        "LS": "pauschal",
        "P1": "Prozent",
    ]

    /// Erläuterung eines Wertes je Business Term; nil, wenn nichts Sicheres
    /// bekannt ist.
    static func note(term: String?, value: String) -> String? {
        guard let term, !value.isEmpty else { return nil }
        switch term {
        case "BT-3":
            return documentType[value]
        case "BT-118", "BT-151", "BT-95", "BT-102":
            return vatCategory[value]
        case "BT-81":
            return paymentMeans[value]
        case "BT-130", "BT-150":
            return unitCode[value]
        default:
            return nil
        }
    }

    /// CII-Datumsformat 102 (JJJJMMTT) als ISO-8601-Lesehilfe.
    static func isoDateNote(value: String, formatAttribute: String?) -> String? {
        guard formatAttribute == "102", value.count == 8,
              value.allSatisfy(\.isNumber) else { return nil }
        let y = value.prefix(4)
        let m = value.dropFirst(4).prefix(2)
        let d = value.suffix(2)
        guard let year = Int(y), let month = Int(m), let day = Int(d),
              (1...12).contains(month) else { return nil }
        let isLeapYear = year.isMultiple(of: 400)
            || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let daysPerMonth = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30,
                            31, 31, 30, 31, 30, 31]
        guard (1...daysPerMonth[month - 1]).contains(day) else { return nil }
        return "\(y)-\(m)-\(d)"
    }
}
