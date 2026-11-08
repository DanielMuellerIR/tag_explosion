import Foundation
import TagExplosionCore

/// Die eigentlichen Aktionen, getrennt von der View, damit sie ohne Fenster
/// testbar sind. Alle Funktionen wirken auf das Frontcover jedes Eintrags.
@MainActor
public enum CoverToolActions {
    /// Verkleinerungsstufen im Menü.
    public static let shrinkSizes = [500, 1000, 1500]

    /// Ergebnis einer Aktion über mehrere Einträge.
    public struct Outcome: Equatable, Codable {
        public init(changed: Int = 0, unchanged: Int = 0, skipped: Int = 0, errors: [String] = []) {
            self.changed = changed; self.unchanged = unchanged; self.skipped = skipped; self.errors = errors
        }
        public var changed = 0
        public var unchanged = 0
        /// Einträge ohne Cover bzw. ohne Ordner-Cover.
        public var skipped = 0
        public var errors: [String] = []
    }

    /// Wendet eine Umwandlung auf das Cover jedes Eintrags an. Einträge ohne
    /// Cover werden übersprungen; ein Fehler bei einer Datei stoppt die
    /// anderen nicht.
    public static func convert(_ entries: [FileEntry], _ conversion: CoverTools.Conversion) -> Outcome {
        var outcome = Outcome()
        for entry in entries {
            guard let cover = entry.frontCover else { outcome.skipped += 1; continue }
            do {
                let converted = try CoverTools.convert(cover, conversion)
                if converted.data == cover.data {
                    outcome.unchanged += 1
                } else {
                    entry.setFrontCover(converted)
                    outcome.changed += 1
                }
            } catch {
                outcome.errors.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Ordner-Cover (folder/cover/front .jpg/.png neben der Datei) als Cover
    /// übernehmen. Jeder Eintrag sucht in seinem eigenen Verzeichnis.
    public static func applyFolderCover(_ entries: [FileEntry]) -> Outcome {
        var outcome = Outcome()
        // Je Verzeichnis nur einmal lesen.
        var cache: [URL: Artwork?] = [:]
        for entry in entries {
            let directory = entry.url.deletingLastPathComponent()
            let artwork: Artwork?
            if let cached = cache[directory] {
                artwork = cached
            } else {
                do {
                    artwork = try FolderCover.load(in: directory)
                } catch {
                    outcome.errors.append("\(directory.lastPathComponent): \(error.localizedDescription)")
                    cache[directory] = .some(nil)
                    continue
                }
                cache[directory] = artwork
            }
            guard let artwork else { outcome.skipped += 1; continue }
            if entry.frontCover?.data == artwork.data {
                outcome.unchanged += 1
            } else {
                entry.setFrontCover(artwork)
                outcome.changed += 1
            }
        }
        return outcome
    }

    /// Gemeinsames Frontcover der Einträge (bei allen byteidentisch);
    /// nil bei Unterschieden oder ohne Cover.
    public static func sharedCover(of entries: [FileEntry]) -> Artwork? {
        guard let first = entries.first?.frontCover else { return nil }
        return entries.allSatisfy { $0.frontCover?.data == first.data } ? first : nil
    }

    /// Lesbare Zusammenfassung für die Hinweisbox; nil, wenn nichts zu melden ist.
    public static func report(_ outcome: Outcome, action: String) -> String? {
        var lines: [String] = []
        if outcome.skipped > 0 {
            lines.append(String(localized: "\(outcome.skipped) Datei(en) übersprungen (kein Cover bzw. kein Ordner-Cover gefunden)."))
        }
        lines.append(contentsOf: outcome.errors)
        guard !lines.isEmpty else { return nil }
        return action + "\n" + lines.joined(separator: "\n")
    }

    /// Lokalisierter Text zu einem Prüfcode (die Core-Texte sind englisch).
    public static func issueText(_ code: CoverIssueCode) -> String {
        switch code {
        case .tooSmall: return String(localized: "zu klein (unter \(CoverTools.minimumEdge) px)")
        case .tooLarge: return String(localized: "zu groß (über \(CoverTools.maximumEdge) px)")
        case .tooManyBytes: return String(localized: "zu groß (über 2 MiB)")
        case .notSquare: return String(localized: "nicht quadratisch")
        case .progressiveJPEG: return String(localized: "progressives JPEG (manche Player zeigen es nicht)")
        case .cmyk: return String(localized: "CMYK (viele Player können das nicht)")
        case .unknownFormat: return String(localized: "Bildformat nicht lesbar")
        }
    }
}
