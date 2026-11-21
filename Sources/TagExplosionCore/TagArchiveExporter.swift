import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension TagArchiveIO {
    /// Liest die Dateien und baut das Archiv (Pfade relativ zu `baseDirectory`,
    /// dem späteren Speicherort der JSON-Datei).
    public static func build(files: [URL], baseDirectory: URL,
                             includeCovers: Bool) throws -> TagArchive {
        var entries: [TagArchive.Entry] = []
        for url in files {
            guard let kind = MediaFormats.kind(of: url) else { continue }
            var entry = TagArchive.Entry(
                path: relativePath(of: url, to: baseDirectory), kind: kind)
            switch kind {
            case .audio:
                let data = try FileSnapshot.capture(at: url) {
                    let file = try TagFile(url: url)
                    defer { file.close() }
                    return try file.readAll(includeArtworks: includeCovers)
                }.value
                entry.properties = TagProperty.valuesByKey(data.properties)
                if includeCovers { entry.artworks = data.artworks }
                if data.supportsChapters { entry.chapters = data.chapters }
                if data.supportsSyncedLyrics {
                    entry.syncedLyrics = data.syncedLyrics
                    entry.lyricsLanguage = data.lyricsLanguage
                    entry.syncedLyricsLanguage = data.syncedLyricsLanguage
                }
            case .image:
                // Gesichert wird der zusammengeführte Stand (Sidecar überlagert
                // eingebettete Werte) — genau das, was die Oberfläche zeigt.
                entry.image = try ExifTool.readCoreFieldsSnapshot(url: url).value.fields
            case .ebook:
                let readsCover = includeCovers && EbookTool.supportsCover(url: url)
                let snapshot = try EbookTool.readSnapshot(
                    url: url, includeCover: readsCover)
                entry.ebook = snapshot.value.fields
                if readsCover {
                    // Lesefehler nicht als "kein Cover" umdeuten: Sonst könnte
                    // ein späterer Import ein vorhandenes Cover löschen.
                    entry.artworks = snapshot.value.cover.map { [$0] } ?? []
                }
            case .document:
                // Ohne Cover: Das CBZ-Cover ist die erste Seite und hat keinen
                // Schreibweg — ein Archiv könnte es nie wiederherstellen.
                entry.document = try DocumentTool.readSnapshot(
                    url: url, includeCover: false).value.fields
            case .sidecar:
                // Nur NFO-Felder; Untertitel und Nur-URL-NFOs tragen nichts,
                // was ein Archiv wiederherstellen könnte (Regel: isArchivable(url:)).
                guard SidecarTool.isNFO(url) else { continue }
                let contents = try KodiNFOFile.readSnapshot(url: url).value
                guard !contents.isURLOnly else { continue }
                entry.nfo = contents.fields
            case .invoice, .playlist:
                // E-Rechnungen sind reine Anzeige — es gibt keine editierbaren
                // Tags, die ein Archiv sichern oder wiederherstellen könnte.
                // Playlists beschriften fremde Dateien (siehe isArchivable).
                continue
            }
            entries.append(entry)
        }
        let created = ISO8601DateFormatter().string(from: Date())
        return TagArchive(created: created, files: entries)
    }

    /// Baut das Archiv und schreibt es atomar als JSON.
    public static func export(files: [URL], to jsonURL: URL, includeCovers: Bool) throws {
        let data = try encodedArchive(files: files, relativeTo: jsonURL,
                                      includeCovers: includeCovers)
        // Über den gemeinsamen Exportweg: Eine vorhandene Datei am Zielpfad
        // wird vorher in den Papierkorb gesichert und dann atomar ersetzt. Ein
        // direkter Data.write ist kein Schreibweg dieses Projekts
        // (Review-Fund 2026-09-10).
        try FileExport.write(data, to: jsonURL)
    }

    /// Kodiert erst vollständig, bevor irgendein Zielname angelegt wird.
    private static func encodedArchive(files: [URL], relativeTo jsonURL: URL,
                                       includeCovers: Bool) throws -> Data {
        try validateExportDestination(files: files, destination: jsonURL)
        let archive = try build(files: files,
                                baseDirectory: jsonURL.deletingLastPathComponent(),
                                includeCovers: includeCovers)
        // Ein Archiv, das der eigene Import nicht mehr annimmt, wäre als
        // Sicherung wertlos. Deshalb hier dieselbe strukturelle Prüfung wie
        // beim Laden: lieber laut scheitern als eine nicht wiederherstellbare
        // Sicherung anlegen. Bewusst nur STRUKTURELL: Fachfremde Bestandswerte
        // (etwa eine exiftool-lesbare GPS-Koordinate 91/181) gehören mit ins
        // Backup; ob sie in ein ZIEL geschrieben werden dürfen, entscheidet
        // erst der Import gegen dessen tatsächlichen Zustand.
        try validate(archive)
        // Auch ein strukturell gültiges Archiv muss eindeutige Schreibziele
        // besitzen. Bestandswerte bleiben dabei ohne Schreibbarkeitsprüfung.
        _ = try validateResolvedEntries(archive, relativeTo: jsonURL.deletingLastPathComponent(),
            allowExternalTargets: true, validateCapabilities: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    /// Schreibt je betroffenem Ordner ein `tags-backup-<Zeitstempel>.json` mit
    /// dem aktuellen Platten-Zustand der Dateien (bewusst frisch gelesen, nicht
    /// aus Puffern — das Backup soll den echten Dateizustand sichern).
    /// Wiederherstellen = derselbe Import-Weg, auch per `tagx import`.
    @discardableResult
    public static func writeBackups(files: [URL]) throws -> [URL] {
        // Zeitstempel ohne Doppelpunkte (Dateiname), ISO-8601-sortierbar.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: Date())

        return try writeBackups(files: files, stamp: stamp, linkFile: { link($0, $1) })
    }

    static func writeBackups(files: [URL], stamp: String,
                             linkFile: (String, String) -> Int32) throws -> [URL] {
        var written: [URL] = []
        for (folder, urls) in Dictionary(grouping: files, by: { $0.deletingLastPathComponent() }) {
            let target = try writeBackup(files: urls, in: folder, stamp: stamp,
                                         linkFile: linkFile)
            written.append(target)
        }
        return written
    }

    /// Belegte Namen vor der Zielprüfung überspringen; die Veröffentlichung
    /// bleibt exklusiv und erkennt auch nachträgliche Kollisionen.
    private static func writeBackup(files: [URL], in folder: URL,
                                    stamp: String,
                                    linkFile: (String, String) -> Int32) throws -> URL {
        for counter in 1...1000 {
            let candidate = backupURL(in: folder, stamp: stamp, counter: counter)
            if FileStamp.current(of: candidate) != nil
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                continue
            }
            do {
                let data = try encodedArchive(files: files, relativeTo: candidate, includeCovers: true)
                try FileExport.createArchiveBackup(data, at: candidate, linkFile: linkFile)
                return candidate
            } catch TagError.fileChangedOnDisk {
                continue
            }
        }
        throw TagError.saveFailed(path: folder.path)
    }

    private static func backupURL(in folder: URL, stamp: String,
                                  counter: Int) -> URL {
        let name = counter == 1
            ? "tags-backup-\(stamp).json"
            : "tags-backup-\(stamp)-\(counter).json"
        return folder.appendingPathComponent(name)
    }
}
