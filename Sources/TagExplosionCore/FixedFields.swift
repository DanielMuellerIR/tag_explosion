// Feste Felder mit Prüfung: Lyrics, Lautheit (ReplayGain, R128) und
// Podcast-Felder. Sie liegen als normale `TagProperty`-Einträge im Modell
// (Schlüssel wie von TagLib), bekommen aber vor dem Schreiben eine
// Wertebereichsprüfung und — wo TagLibs PropertyMap keinen Speicherort kennt —
// einen eigenen Weg über den Shim (`TagFile`).
//
// Speicherorte (Lesen und Schreiben):
//  - Lyrics: ID3v2 USLT (mit Sprache), MP4 `©lyr`, Vorbis/APE `LYRICS`
//    (bestehende `UNSYNCEDLYRICS` werden weiter benutzt).
//  - ReplayGain: ID3v2 TXXX, MP4 `----:com.apple.iTunes:REPLAYGAIN_*`,
//    Vorbis/APE gleichnamig. R128: nur Opus (`R128_*_GAIN`, Q7.8-Ganzzahl).
//  - Podcast: ID3v2 PCST/WFED/TGID/TCAT/TKWD/TDES/TVSN/TVEP, MP4
//    pcst/purl/egid/catg/keyw/desc/ldes/tvsn/tves.
import Foundation

public enum FixedFields {

    // MARK: - Schlüssel

    public static let lyrics = "LYRICS"
    /// Zweiter gebräuchlicher Vorbis-/APE-Schlüssel für Lyrics (foobar2000).
    public static let lyricsAlternate = "UNSYNCEDLYRICS"

    public static let replayGainTrackGain = "REPLAYGAIN_TRACK_GAIN"
    public static let replayGainTrackPeak = "REPLAYGAIN_TRACK_PEAK"
    public static let replayGainAlbumGain = "REPLAYGAIN_ALBUM_GAIN"
    public static let replayGainAlbumPeak = "REPLAYGAIN_ALBUM_PEAK"
    public static let r128TrackGain = "R128_TRACK_GAIN"
    public static let r128AlbumGain = "R128_ALBUM_GAIN"

    /// Podcast-Flag ("1" = Podcast; ID3 PCST, MP4 pcst).
    public static let podcast = "PODCAST"
    public static let podcastURL = "PODCASTURL"
    /// Episoden-GUID (ID3 TGID, MP4 egid).
    public static let podcastID = "PODCASTID"
    public static let podcastCategory = "PODCASTCATEGORY"
    /// Stichwörter, kommagetrennt (ID3 TKWD, MP4 keyw).
    public static let keywords = "KEYWORDS"
    /// Staffel und Episode nach iTunes-Konvention (ID3 TVSN/TVEP, MP4 tvsn/tves).
    public static let season = "TVSEASON"
    public static let episode = "TVEPISODE"
    /// Kurzbeschreibung (ID3 TDES, MP4 desc) und lange Beschreibung (MP4 ldes;
    /// ID3 hat dafür keinen Frame, dort landet sie als TXXX).
    public static let podcastDescription = "PODCASTDESC"
    public static let longDescription = "LONGDESCRIPTION"

    public static let loudnessKeys = [replayGainTrackGain, replayGainTrackPeak,
                                      replayGainAlbumGain, replayGainAlbumPeak,
                                      r128TrackGain, r128AlbumGain]
    public static let podcastKeys = [podcast, podcastURL, podcastID, podcastCategory, keywords,
                                     season, episode, podcastDescription, longDescription]
    /// Alle Schlüssel, die der Editor in eigenen Abschnitten statt unter
    /// „Weitere Felder" zeigt.
    public static let allKeys: Set<String> = Set([lyrics, lyricsAlternate] + loudnessKeys + podcastKeys)

    // MARK: - Speicherorte außerhalb der PropertyMap

    /// Ein Feld, das TagLibs PropertyMap bei ID3v2 bzw. MP4 nicht kennt und
    /// deshalb direkt als Frame/Atom gelesen und geschrieben wird. nil =
    /// für diesen Container übernimmt die PropertyMap (oder es gibt keinen
    /// Speicherort).
    public struct NativeSlot: Sendable {
        public let key: String
        public let id3Frame: String?
        public let mp4Atom: String?
    }

    public static let nativeSlots: [NativeSlot] = [
        // PCST liefert TagLib beim Lesen ohne Wert und verliert es beim
        // Schreiben über die PropertyMap; MP4 pcst bleibt der Symmetrie wegen
        // auf demselben Weg.
        NativeSlot(key: podcast, id3Frame: "PCST", mp4Atom: "pcst"),
        NativeSlot(key: keywords, id3Frame: "TKWD", mp4Atom: "keyw"),
        NativeSlot(key: longDescription, id3Frame: nil, mp4Atom: "ldes"),
        // MP4 tvsn/tves bildet TagLib selbst als TVSEASON/TVEPISODE ab.
        NativeSlot(key: season, id3Frame: "TVSN", mp4Atom: nil),
        NativeSlot(key: episode, id3Frame: "TVEP", mp4Atom: nil),
    ]

    // MARK: - Welche Formate welche Felder tragen

    private static let mp4Extensions: Set<String> = ["m4a", "m4b", "m4r", "mp4", "m4v", "3gp", "3g2"]
    private static let id3Extensions: Set<String> = ["mp3", "mp2"]

    /// Lyrics und ReplayGain gehen überall, wo TagLib freie Schlüssel
    /// speichert — nicht bei Tracker-Modulen und reinen Anzeige-Formaten.
    /// `writableTagKeys == nil` heißt nur „keine Tracker-Einschränkung“ und
    /// gilt auch für Bilder, Dokumente und unbekannte Endungen; deshalb
    /// zusätzlich an die TagLib-Medienart (Audio/Video) binden.
    public static func supportsLyrics(_ url: URL) -> Bool {
        MediaFormats.kind(of: url) == .audio
            && MediaFormats.writableTagKeys(for: url) == nil
            && !MediaFormats.displayOnly.contains(url.pathExtension.lowercased())
    }

    public static func supportsLoudness(_ url: URL) -> Bool { supportsLyrics(url) }

    /// R128-Lautheit ist Teil der Opus-Spezifikation (RFC 7845) und nur dort üblich.
    public static func supportsR128(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "opus"
    }

    /// Podcast-Felder haben nur ID3v2 und MP4 feste Speicherorte.
    public static func supportsPodcast(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return id3Extensions.contains(ext) || mp4Extensions.contains(ext)
    }

    /// Die lange Beschreibung hat nur MP4 (`ldes`) als eigenes Atom.
    public static func supportsLongDescription(_ url: URL) -> Bool {
        mp4Extensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Lyrics-Text

    /// Unter welchem Schlüssel diese Datei ihre Lyrics führt: `LYRICS`,
    /// sonst ein vorhandenes `UNSYNCEDLYRICS`, sonst `LYRICS`.
    public static func lyricsKey(in properties: [TagProperty]) -> String {
        if properties.contains(where: { $0.key == lyrics }) { return lyrics }
        if properties.contains(where: { $0.key == lyricsAlternate }) { return lyricsAlternate }
        return lyrics
    }

    public static func lyricsText(in properties: [TagProperty]) -> String {
        let key = lyricsKey(in: properties)
        return properties.first { $0.key == key }?.value ?? ""
    }

    /// Ersetzt die Lyrics (leer = entfernen). Beide Schlüssel werden bereinigt,
    /// damit keine zwei abweichenden Fassungen in der Datei stehen.
    public static func settingLyrics(_ text: String, in properties: [TagProperty]) -> [TagProperty] {
        let key = lyricsKey(in: properties)
        var result = properties.filter { $0.key != lyrics && $0.key != lyricsAlternate }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(TagProperty(key: key, value: text)) }
        return result
    }

    // MARK: - Sprache

    /// ID3v2 verlangt drei Buchstaben (ISO 639-2); leer bedeutet unbekannt
    /// und wird als "XXX" gespeichert.
    public static func isValidLanguage(_ language: String) -> Bool {
        language.isEmpty
            || (language.count == 3 && language.allSatisfy { $0.isASCII && $0.isLetter })
    }

    /// Kleinbuchstaben wie in ISO 639-2; "XXX" (unbekannt) wird zu leer.
    public static func normalizedLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "xxx" ? "" : trimmed
    }

    // MARK: - Prüfung

    /// Prüft die festen Felder in `properties`. Mit `original` werden nur
    /// Einträge geprüft, die dort nicht schon genauso stehen — Altwerte
    /// fremder Programme blockieren so keine unabhängige Änderung.
    /// Wirft `TagError.invalidFieldValue` mit Feldname und Grund.
    public static func validate(_ properties: [TagProperty], changedFrom original: [TagProperty]? = nil) throws {
        let unchanged = Set(original ?? [])
        for property in properties where !unchanged.contains(property) {
            try validate(key: property.key, value: property.value)
        }
    }

    /// Prüft einen einzelnen Wert; Schlüssel ohne feste Regel sind immer gültig.
    public static func validate(key: String, value: String) throws {
        func reject(_ reason: String) -> TagError {
            TagError.invalidFieldValue(field: key, reason: reason)
        }
        switch key {
        case replayGainTrackGain, replayGainAlbumGain:
            guard let gain = Loudness.parseGain(value) else {
                throw reject("expected a gain like \"-6.50 dB\", got \"\(value)\"")
            }
            guard Loudness.gainRange.contains(gain) else {
                throw reject("gain must be between -60 and +60 dB, got \(Loudness.formatGain(gain))")
            }
        case replayGainTrackPeak, replayGainAlbumPeak:
            guard let peak = Loudness.parsePeak(value) else {
                throw reject("expected a peak like \"0.987654\", got \"\(value)\"")
            }
            guard Loudness.peakRange.contains(peak) else {
                throw reject("peak must be between 0 and 10, got \(value)")
            }
        case r128TrackGain, r128AlbumGain:
            guard let raw = Loudness.parseR128(value) else {
                throw reject("expected a Q7.8 integer like \"-1664\" (= -6.50 dB), got \"\(value)\"")
            }
            guard Loudness.r128Range.contains(raw) else {
                throw reject("R128 gain must be between -32768 and 32767, got \(raw)")
            }
        case season, episode:
            guard let number = Int(value.trimmingCharacters(in: .whitespaces)), number >= 0 else {
                throw reject("expected a non-negative whole number, got \"\(value)\"")
            }
        case podcast:
            guard parseFlag(value) != nil else {
                throw reject("expected 1 or 0, got \"\(value)\"")
            }
        case podcastURL:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty,
                  !trimmed.contains(where: \.isWhitespace) else {
                throw reject("expected a URL with scheme like \"https://…\", got \"\(value)\"")
            }
        default:
            break
        }
    }

    /// Bringt gültige Eingaben in die Speicherform: Gain als `-6.50 dB`,
    /// Peak mit sechs Nachkommastellen, R128 und Staffel/Episode als
    /// Ganzzahl, Flag als "1" (oder leer = entfernen). Ungültige Werte
    /// werfen wie `validate`.
    public static func normalized(key: String, value: String) throws -> String {
        try validate(key: key, value: value)
        switch key {
        case replayGainTrackGain, replayGainAlbumGain:
            return Loudness.formatGain(Loudness.parseGain(value) ?? 0)
        case replayGainTrackPeak, replayGainAlbumPeak:
            return Loudness.formatPeak(Loudness.parsePeak(value) ?? 0)
        case r128TrackGain, r128AlbumGain:
            return String(Loudness.parseR128(value) ?? 0)
        case season, episode:
            return String(Int(value.trimmingCharacters(in: .whitespaces)) ?? 0)
        case podcast:
            return (parseFlag(value) ?? false) ? "1" : ""
        case podcastURL:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return value
        }
    }

    /// "1"/"0", "true"/"false", "yes"/"no" — nil bei allem anderen.
    public static func parseFlag(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no", "": return false
        default: return nil
        }
    }
}

/// Umrechnung und Formatierung der Lautheitswerte.
public enum Loudness {
    public static let gainRange: ClosedRange<Double> = -60...60
    public static let peakRange: ClosedRange<Double> = 0...10
    public static let r128Range: ClosedRange<Int> = -32768...32767

    /// Liest "-6.50 dB", "-6.5", "+1,2 dB" (Komma erlaubt, Einheit optional).
    public static func parseGain(_ text: String) -> Double? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasSuffix("db") {
            body = String(body.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return parseDecimal(body)
    }

    /// Speicherform mit zwei Nachkommastellen und Einheit: "-6.50 dB".
    public static func formatGain(_ decibel: Double) -> String {
        String(format: "%.2f dB", locale: nil, decibel)
    }

    public static func parsePeak(_ text: String) -> Double? {
        parseDecimal(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func formatPeak(_ peak: Double) -> String {
        String(format: "%.6f", locale: nil, peak)
    }

    /// R128 ist eine Ganzzahl in Q7.8 (Wert / 256 = dB).
    public static func parseR128(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed)
    }

    public static func r128ToDecibel(_ raw: Int) -> Double { Double(raw) / 256 }

    public static func decibelToR128(_ decibel: Double) -> Int { Int((decibel * 256).rounded()) }

    /// Dezimalzahl mit Punkt oder Komma, optionalem Vorzeichen, ohne Einheit.
    private static func parseDecimal(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }),
              let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}
