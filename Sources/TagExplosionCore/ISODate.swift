// Kalenderprüfung für ISO-8601-Datumsangaben (`YYYY-MM-DD`).
//
// Ein Muster-Test allein lässt `2026-02-31` oder `2026-99-99` durch —
// Werte, die wie ein Datum aussehen, aber keines sind. Kodi und andere
// Importer lehnen sie ab oder deuten sie um. Hier zählt nur, was der
// proleptische gregorianische Kalender (ISO 8601) wirklich kennt.
import Foundation

public enum ISODate {

    /// Prüft, ob `text` ein existierender Kalendertag im Format
    /// `YYYY-MM-DD` ist (Schaltjahre nach gregorianischer Regel).
    public static func isCalendarDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        guard (1...12).contains(month) else { return false }
        return (1...daysInMonth(month, year: year)).contains(day)
    }

    /// Tage des Monats; Februar nach Schaltjahresregel (durch 4, außer
    /// durch 100, außer durch 400).
    static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }
}
