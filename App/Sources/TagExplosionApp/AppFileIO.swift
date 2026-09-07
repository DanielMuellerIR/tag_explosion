// Medien-IO aus unveränderlichen Daten. Auswahl und Konfliktentscheidungen
// bleiben beim AppModel; Formatregeln bleiben in den Core-Backends.
import Foundation
import EInvoiceCore
import TagExplosionCore

enum AppFileIO {
    /// Liest den Datei-Zustand passend zur Medienart (Hintergrund-tauglich);
    /// gemeinsamer Lesepfad für Öffnen, Neuladen und Speichern-Read-back.
    nonisolated static func readLoaded(url: URL, kind: MediaKind) throws -> LoadedData {
        switch kind {
        case .audio:
            do {
                var data = try TagFile.read(at: url)
                var sidecars = AudioSidecars()
                // Formate ohne ID3v2 haben kein SYLT; dort zählt die Sidecar
                // `<name>.lrc`. Eine unlesbare Sidecar blockiert das Öffnen
                // nicht — sie gilt dann als leer. Ihr Stempel wandert mit,
                // damit das Speichern eine fremde Änderung erkennt.
                if !data.supportsSyncedLyrics, FixedFields.supportsLyrics(url) {
                    sidecars.lrcState = SidecarState.current(of: LRC.sidecarURL(for: url))
                    if let sidecar = try? LRC.loadSidecar(for: url) {
                        data.syncedLyrics = sidecar
                    }
                }
                sidecars.nfo = readVideoNFO(for: url)
                return .audio(data, sidecars: sidecars)
            } catch {
                // Container, für die TagLib keinen Tag-Leser hat (AVI, manche
                // MOV-Varianten, Sun-AU, Ogg-Video), sollen trotzdem geöffnet
                // werden können: Der Technik-Tab über mediainfo funktioniert
                // für sie, bearbeitbar sind sie nicht. Ohne diesen Weg endet
                // das Öffnen mit einem Fehler statt mit einer Ansicht. Eine
                // NFO daneben bleibt trotzdem editierbar.
                guard MediaFormats.toleratesMissingTagReader(url) else {
                    throw error
                }
                return .audio(TagData(properties: [], artworks: [], audio: nil, isReadOnly: true),
                              sidecars: AudioSidecars(nfo: readVideoNFO(for: url)))
            }
        case .image: return .image(try ExifTool.readCoreReading(url: url))
        case .ebook:
            // Felder und Cover in einem Schnappschuss: Der Editor zeigt damit
            // garantiert das Cover derselben Dateifassung, und ein erneut
            // ausgewähltes gleiches Cover ist als Nichts-Tun erkennbar.
            do {
                let contents = try EbookTool.readSnapshot(
                    url: url, includeCover: EbookTool.supportsCover(url: url)).value
                return .ebook(contents.fields, cover: contents.cover?.data)
            } catch let error as TagError {
                // PDF-Metadaten brauchen exiftool — die E-Rechnungs-Anzeige
                // nicht (CoreGraphics + eigener Leser). Fehlt das Werkzeug,
                // soll ein Rechnungs-PDF trotzdem aufgehen: als reiner
                // Anzeige-Eintrag mit der eingebetteten Rechnung.
                if case .toolNotFound = error,
                   url.pathExtension.lowercased() == "pdf",
                   let document = try? EInvoiceReader.read(url: url) {
                    return .invoice(document)
                }
                throw error
            }
        case .invoice:
            // E-Rechnung (XML): vollständig parsen — reine Anzeige.
            return .invoice(try EInvoiceReader.read(url: url))
        case .document:
            let contents = try DocumentTool.readSnapshot(
                url: url, includeCover: DocumentTool.supportsCover(url: url)).value
            return .document(contents.fields, cover: contents.cover?.data, info: contents.info)
        case .sidecar:
            return .sidecar(try SidecarTool.readSnapshot(url: url).value)
        case .playlist:
            return .playlist(try PlaylistTool.readSnapshot(url: url).value)
        }
    }

    /// Kodi-NFO neben einem Video: Inhalt und Stempel in einem Schnappschuss.
    /// Eine unlesbare NFO blockiert das Öffnen nicht — der Abschnitt zeigt
    /// dann den Grund statt Felder. nil, wenn keine NFO daneben liegt.
    nonisolated static func readVideoNFO(for url: URL) -> NFOSidecarReading? {
        guard let nfoURL = MediaFormats.nfoURL(forVideo: url) else { return nil }
        do {
            let snapshot = try KodiNFOFile.readSnapshot(url: nfoURL)
            return NFOSidecarReading(url: nfoURL, contents: snapshot.value, stamp: snapshot.stamp)
        } catch {
            return NFOSidecarReading(url: nfoURL, contents: nil, stamp: nil,
                                     error: error.localizedDescription)
        }
    }

    /// Schreibweg der NFO neben einem Video (wie im CLI): Prüfen, Stempel,
    /// Papierkorb-Sicherung, atomarer Austausch. `backUp: false`, wenn die
    /// Sicherung schon in der Vorbereitungsphase erfolgt ist.
    nonisolated private static func writeVideoNFO(_ nfo: FileEntry.NFOSnapshot, backUp: Bool = true) throws {
        try KodiNFOFile.validate(nfo.fields, original: nfo.original)
        try FileStamp.requireUnchanged(nfo.stamp, at: nfo.url)
        if backUp { try TrashBackup.shared.backUp(nfo.url, reason: BackupReason.sidecar) }
        try KodiNFOFile.write(url: nfo.url, fields: nfo.fields, original: nfo.original,
                              expecting: nfo.stamp)
    }

    /// Liest Datei-Zustand UND Stempel als konsistenten Schnappschuss: Der
    /// Stempel wird vor und nach dem Lesen erhoben; nur wenn beide gleich
    /// sind, gehören Inhalt und Stempel sicher zusammen. Schreibt ein anderes
    /// Programm genau währenddessen, wird erneut gelesen; bleibt die Datei
    /// dauerhaft in Bewegung, bricht das Lesen ab. Ohne diese Kopplung könnte
    /// das Modell alte Daten mit dem Stempel einer neueren, fremden Version
    /// kombinieren — das nächste Speichern hielte die fremde Version dann für
    /// den eigenen Stand und überschriebe sie ungefragt.
    nonisolated static func readStamped(
        url: URL, kind: MediaKind,
        read: (URL, MediaKind) throws -> LoadedData = AppFileIO.readLoaded
    ) throws -> (LoadedData, FileStamp?) {
        var remainingAttempts = 3
        while true {
            let before = FileStamp.current(of: url)
            let loaded = try read(url, kind)
            let after = FileStamp.current(of: url)
            if before == after {
                // Ohne Stempel ist die Datei nicht (mehr) erreichbar. Für
                // Video-Container fängt `readLoaded` einen Lesefehler bewusst
                // als read-only-Platzhalter ab — ohne diese Prüfung landete
                // eine inzwischen verschwundene .avi/.mov als scheinbar
                // erfolgreich geöffneter Eintrag in der Liste.
                guard let after else { throw TagError.cannotOpen(path: url.path) }
                return (loaded, after)
            }
            remainingAttempts -= 1
            guard remainingAttempts > 0 else {
                throw TagError.fileChangedOnDisk(path: url.path)
            }
        }
    }

    /// Der eigentliche Hintergrundzugriff bekommt ausschließlich den Snapshot.
    /// Damit kann ein UI-Edit während await nicht in diesen Schreibvorgang rutschen.
    nonisolated static func write(snapshot: FileEntry.SaveSnapshot,
                                          to url: URL, kind: MediaKind,
                                          expecting stamp: FileStamp?, preferImageSidecar: Bool, id3Version: ID3Version) throws -> (LoadedData, FileStamp?) {
        // Hat ein anderes Programm die Datei seit dem Öffnen geändert, wäre das
        // Speichern ein stilles Überschreiben fremder Arbeit. Diese frühe
        // Prüfung bricht vor Backup und Kopie ab; der Stempel wandert
        // zusätzlich bis in den atomaren Austausch (expecting:) und wird dort
        // unmittelbar vor dem rename ein letztes Mal geprüft.
        try FileStamp.requireUnchanged(stamp, at: url)
        // Unbrauchbare Eingaben schon vor der Sicherung ablehnen: Der
        // Schreibweg würde ein Nicht-Bild sonst als angebliches Cover in die
        // Datei legen, und ein Serienindex ohne Serie scheiterte erst NACH
        // der Papierkorb-Kopie — jeder solche Versuch legte eine unnötige
        // Sicherung der unveränderten Datei an.
        if case .image(let fields, let original, _) = snapshot {
            try ExifTool.requireValidCoreFields(fields, original: original)
        }
        if case .audio(let audio) = snapshot {
            // Feste Felder (ReplayGain, R128, Podcast, Sprache) mit Wertebereich:
            // ein ungültiger Wert endet hier, vor Sicherung und Kopie.
            try FixedFields.validate(audio.properties, changedFrom: audio.original.properties)
            if let lines = audio.syncedLyrics { try LRC.validate(lines) }
            if let language = audio.lyricsLanguage, !FixedFields.isValidLanguage(language) {
                throw TagError.invalidFieldValue(
                    field: "LYRICS language",
                    reason: "expected three letters (ISO 639-2), got \"\(language)\"")
            }
            // Nur Sidecars haben sich geändert: Medium und dessen Sicherung
            // bleiben unangetastet; jede Sidecar sichert sich selbst und
            // prüft ihren eigenen Lesestempel.
            if !audio.mediaChanged {
                if let lines = audio.syncedLyrics {
                    try LRC.writeSidecar(lines, for: url, expecting: audio.lrcState)
                }
                if let nfo = audio.nfo { try writeVideoNFO(nfo) }
                return try readStamped(url: url, kind: kind)
            }
        }
        if case .ebook(let fields, let original, let cover) = snapshot {
            try EbookTool.requireStorableSeries(fields, original: original, url: url)
            if let cover { try EbookTool.requireSupportedCover(cover, for: url) }
        }
        if case .document(let fields, let original) = snapshot {
            try DocumentTool.requireWritable(fields, original: original, url: url)
        }
        if case .sidecar(let fields, let original) = snapshot {
            try SidecarTool.requireWritable(fields, original: original, url: url)
        }
        if case .playlist(let fields, let original) = snapshot {
            try PlaylistTool.requireWritable(fields, original: original, url: url)
        }
        // Bilder: Kamera-RAW, Formate ohne exiftool-Schreibweg, eine schon
        // vorhandene Sidecar und die Einstellung lenken die Änderung in die
        // XMP-Sidecar `<name>.xmp`. Gesichert wird dann DIESE Datei; eine
        // noch fehlende Sidecar hat nichts zu sichern (backUp überspringt sie).
        let imageDestination: ImageWriteDestination? = kind == .image
            ? ExifTool.writeDestination(for: url, preferSidecar: preferImageSidecar)
            : nil
        // Abgesicherter Modus: erst die unveränderte Kopie in den Papierkorb,
        // dann schreiben. Scheitert die Sicherung, wird bewusst nicht geschrieben.
        try TrashBackup.shared.backUp(imageDestination?.url ?? url, reason: snapshot.backupReason)
        switch (kind, snapshot) {
        case (.audio, .audio(let audio)):
            let embedsSynced = audio.original.supportsSyncedLyrics
            // Formate ohne SYLT: geänderte Zeilen gehören in die Sidecar.
            let sidecarLines = embedsSynced ? nil : audio.syncedLyrics
            // Zweiphasig: Erst alles, was an den Sidecars scheitern kann
            // (Lesestempel, Feldprüfung, Papierkorb-Sicherung), DANN der
            // Container, zuletzt der Austausch der Sidecars. So übernimmt ein
            // Save nie Containerfelder dauerhaft, während Lyrics oder NFO
            // wegen eines Sicherungsfehlers liegen bleiben — der Fehler kommt
            // vor dem ersten Austausch.
            if sidecarLines != nil {
                let sidecarURL = LRC.sidecarURL(for: url)
                try audio.lrcState.requireUnchanged(at: sidecarURL)
                // Eine noch fehlende Sidecar hat nichts zu sichern (backUp
                // überspringt sie).
                try TrashBackup.shared.backUp(sidecarURL, reason: BackupReason.sidecar)
            }
            if let nfo = audio.nfo {
                try KodiNFOFile.validate(nfo.fields, original: nfo.original)
                try FileStamp.requireUnchanged(nfo.stamp, at: nfo.url)
                try TrashBackup.shared.backUp(nfo.url, reason: BackupReason.sidecar)
            }
            try TagFile.write(properties: audio.properties, artworks: audio.artworks,
                              chapters: audio.chapters,
                              syncedLyrics: embedsSynced ? audio.syncedLyrics : nil,
                              lyricsLanguage: embedsSynced ? audio.lyricsLanguage : nil,
                              to: url, expecting: stamp, id3Version: id3Version)
            var completed = [url.lastPathComponent]
            do {
                if let lines = sidecarLines {
                    try LRC.writeSidecar(lines, for: url, expecting: audio.lrcState, backUp: false)
                    completed.append(LRC.sidecarURL(for: url).lastPathComponent)
                }
                if let nfo = audio.nfo { try writeVideoNFO(nfo, backUp: false) }
            } catch {
                throw PartialSaveError(completed: completed, underlying: error)
            }
        case (.image, .image(let fields, let original, let sidecar)):
            try ExifTool.writeCoreFields(url: url, fields: fields, original: original,
                                         expecting: stamp, to: imageDestination,
                                         sidecar: sidecar)
        case (.ebook, .ebook(let fields, let original, let cover)):
            try EbookTool.write(
                url: url, fields: fields, original: original,
                coverUpdate: cover.map(EbookCoverUpdate.set) ?? .unchanged,
                expecting: stamp)
        case (.document, .document(let fields, let original)):
            try DocumentTool.write(url: url, fields: fields, original: original,
                                   expecting: stamp)
        case (.sidecar, .sidecar(let fields, let original)):
            try SidecarTool.write(url: url, fields: fields, original: original, expecting: stamp)
        case (.playlist, .playlist(let fields, let original)):
            try PlaylistTool.write(url: url, fields: fields, original: original,
                                   expecting: stamp)
        default:
            throw TagError.saveFailed(path: url.path)
        }
        return try readStamped(url: url, kind: kind)
    }

}
