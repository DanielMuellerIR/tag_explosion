// Änderungsplan aus Kandidat + zugeordnetem Titel — reine Funktion.
//
// Der Plan listet je Feld alt → neu und enthält nur echte Änderungen. Das
// Schreiben selbst passiert nirgends hier: CLI und App führen den Plan über
// den bestehenden Weg (`TagFile.write` mit `AtomicFileRewrite` und
// `TrashBackup`) aus.
import Foundation

/// Eine geplante Feldänderung.
public struct LookupFieldChange: Sendable, Codable, Equatable, Hashable {
    public var key: String
    /// Bisheriger erster Wert; nil = Feld fehlte.
    public var oldValue: String?
    public var newValue: String

    public init(key: String, oldValue: String?, newValue: String) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// Der Plan für eine Datei.
public struct LookupPlan: Sendable, Codable, Equatable {
    public var fileURL: URL
    public var changes: [LookupFieldChange]
    /// Cover, das übernommen werden soll (nur wenn gewünscht und vorhanden).
    public var coverURL: URL?

    public init(fileURL: URL, changes: [LookupFieldChange], coverURL: URL? = nil) {
        self.fileURL = fileURL
        self.changes = changes
        self.coverURL = coverURL
    }

    public var isEmpty: Bool { changes.isEmpty && coverURL == nil }

    /// Wendet die Änderungen auf eine Feldliste an: je Schlüssel bleibt genau
    /// ein Wert (mehrwertige Felder werden auf den neuen Wert reduziert),
    /// alle übrigen Felder bleiben unangetastet.
    public func apply(to properties: [TagProperty]) -> [TagProperty] {
        var result = properties
        for change in changes {
            if let index = result.firstIndex(where: { $0.key == change.key }) {
                result[index].value = change.newValue
                var seen = false
                result.removeAll { property in
                    guard property.key == change.key else { return false }
                    if seen { return true }
                    seen = true
                    return false
                }
            } else {
                result.append(TagProperty(key: change.key, value: change.newValue))
            }
        }
        return result
    }
}

/// Wahlmöglichkeiten des Nutzers beim Planen.
public struct LookupPlanOptions: Sendable, Equatable {
    /// MusicBrainz-/Discogs-/AcoustID-Kennungen mitschreiben.
    public var includeIdentifiers: Bool
    /// Vorhandene Werte ersetzen; sonst nur leere Felder füllen.
    public var overwriteExisting: Bool
    /// Cover-URL in den Plan aufnehmen.
    public var includeCover: Bool

    public init(includeIdentifiers: Bool = true, overwriteExisting: Bool = true, includeCover: Bool = false) {
        self.includeIdentifiers = includeIdentifiers
        self.overwriteExisting = overwriteExisting
        self.includeCover = includeCover
    }
}

public enum LookupPlanner {
    /// Feldnamen, wie TagLibs PropertyMap sie kennt (MusicBrainz-Kennungen
    /// landen in ID3 als TXXX/UFID, in Vorbis/MP4 als gleichnamige Felder).
    public static let musicBrainzAlbumIDKey = "MUSICBRAINZ_ALBUMID"
    public static let musicBrainzTrackIDKey = "MUSICBRAINZ_TRACKID"
    public static let musicBrainzArtistIDKey = "MUSICBRAINZ_ARTISTID"
    public static let musicBrainzReleaseGroupIDKey = "MUSICBRAINZ_RELEASEGROUPID"
    public static let acoustIDKey = "ACOUSTID_ID"
    public static let discogsReleaseIDKey = "DISCOGS_RELEASE_ID"

    /// Plan für eine Datei. `track` nil = nur Album-Felder (Titel, Nummer und
    /// Recording-ID bleiben unangetastet).
    public static func plan(for fileURL: URL, existing: [TagProperty],
                            candidate: LookupCandidate, track: LookupTrack?,
                            options: LookupPlanOptions = LookupPlanOptions()) -> LookupPlan {
        var desired: [(String, String)] = []
        desired.append(("ALBUM", candidate.album))
        desired.append(("ALBUMARTIST", candidate.artist))
        if let track {
            desired.append(("TITLE", track.title))
            desired.append(("ARTIST", track.artist ?? candidate.artist))
            let total = candidate.tracks.filter { $0.discNumber == track.discNumber }.count
            desired.append(("TRACKNUMBER", total > 0 ? "\(track.number)/\(total)" : "\(track.number)"))
            let discs = Set(candidate.tracks.map(\.discNumber)).count
            if discs > 1 {
                desired.append(("DISCNUMBER", "\(track.discNumber)/\(discs)"))
            }
        } else {
            desired.append(("ARTIST", candidate.artist))
        }
        desired.append(("DATE", candidate.year))
        desired.append(("LABEL", candidate.label))
        desired.append(("CATALOGNUMBER", candidate.catalogNumber))
        desired.append(("RELEASECOUNTRY", candidate.country))
        if options.includeIdentifiers {
            desired.append((musicBrainzAlbumIDKey, candidate.identifiers.musicBrainzReleaseID ?? ""))
            desired.append((musicBrainzReleaseGroupIDKey, candidate.identifiers.musicBrainzReleaseGroupID ?? ""))
            desired.append((musicBrainzArtistIDKey, candidate.identifiers.musicBrainzArtistID ?? ""))
            desired.append((musicBrainzTrackIDKey, track?.recordingID ?? ""))
            desired.append((acoustIDKey, track?.acoustID ?? ""))
            desired.append((discogsReleaseIDKey, candidate.identifiers.discogsReleaseID ?? ""))
        }

        var changes: [LookupFieldChange] = []
        for (key, rawValue) in desired {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Leere Sollwerte löschen nichts — der Dienst weiß es nur nicht.
            guard !value.isEmpty else { continue }
            let old = existing.first { $0.key == key }?.value
            if let old, !old.isEmpty {
                guard options.overwriteExisting, old != value else { continue }
            }
            changes.append(LookupFieldChange(key: key, oldValue: old, newValue: value))
        }
        return LookupPlan(fileURL: fileURL, changes: changes,
                          coverURL: options.includeCover ? candidate.coverURL : nil)
    }
}
