import Foundation

extension TagArchiveIO {
    /// Wendet ein Archiv auf die Platte an (bzw. zeigt mit `dryRun` nur, was
    /// passieren würde). Gematcht wird ausschließlich über den relativen Pfad
    /// zur JSON-Datei; fehlende und zusätzliche Dateien werden gemeldet statt
    /// zu raten.
    ///
    /// `approvedTargets` muss unverändert die Ausgabe von `validatedTargets`
    /// sein — die Liste, mit der der Aufrufer gearbeitet hat (angezeigte
    /// Freigabe in CLI/App, Ermittlung betroffener offener Editoren). Sie wird
    /// hier wörtlich mit den frisch aufgelösten Zielen verglichen. Auch ein
    /// Import ganz ohne externe Ziele sollte sie mitgeben: Sonst kann ein
    /// zwischenzeitlich umgebogener Symlink auf eine andere, nie geprüfte
    /// Datei zeigen und der Import schriebe sie trotzdem.
    ///
    /// `allowExternalTargets` bleibt davon unabhängig: Ziele außerhalb des
    /// Archivordners brauchen weiterhin eine ausdrückliche Freigabe.
    public static func apply(_ archive: TagArchive, relativeTo baseDirectory: URL,
                             dryRun: Bool, approvedTargets: [URL]? = nil,
                             allowExternalTargets: Bool = false) throws
    -> TagArchiveReport {
        try apply(
            archive, relativeTo: baseDirectory, dryRun: dryRun,
            approvedTargets: approvedTargets,
            allowExternalTargets: allowExternalTargets, afterValidation: {},
            beforeNoopReturn: { _ in },
            backUp: { try TrashBackup.shared.backUp($0, reason: BackupReason.import) })
    }

    /// Testbarer Kern: Der Hook liegt exakt nach Ziel-/Identitätsprüfung und
    /// vor dem ersten Read. Produktive Aufrufer verwenden den öffentlichen
    /// Overload ohne Hook.
    static func apply(
        _ archive: TagArchive,
        relativeTo baseDirectory: URL,
        dryRun: Bool,
        approvedTargets: [URL]? = nil,
        allowExternalTargets: Bool = false,
        afterValidation: () throws -> Void,
        beforeNoopReturn: (URL) throws -> Void = { _ in },
        backUp: (URL) throws -> Void = { try TrashBackup.shared.backUp($0, reason: BackupReason.import) }
    ) throws -> TagArchiveReport {
        // Die gesamte Datei wird vor der Schleife geprüft. Damit kann kein
        // fehlerhafter Eintrag nach einer schon geschriebenen Datei auffallen.
        // Ein zuvor in CLI/App angezeigter externer Pfad wird hier unmittelbar
        // vor den Mutationen nochmals vollständig aufgelöst und geprüft.
        try validate(archive)
        // Auch hier umrechnen, nicht nur in `load`: App und Tests bauen Archive
        // direkt und umgehen `load` damit.
        let archive = normalizingLegacyValues(archive)
        let validated = try validateResolvedEntries(
            archive, relativeTo: baseDirectory,
            allowExternalTargets: allowExternalTargets
        )
        let targets = validated.flatMap(\.accessURLs)
        if let approvedTargets {
            // Bewusst KEINE erneute Kanonisierung der freigegebenen Pfade: Sie
            // sind der beim Bestätigen angezeigte, bereits vollständig
            // aufgelöste Stand (Ausgabe von `validatedTargets`). Würde man sie
            // hier nochmals auflösen, könnte ein zwischenzeitlich
            // untergeschobener Symlink beide Seiten auf DASSELBE neue Ziel
            // ziehen — die Gleichheitsprüfung wäre dann wirkungslos und ein
            // nie angezeigtes Ziel würde überschrieben.
            guard approvedTargets == targets else {
                throw TagArchiveError.approvedTargetListChanged
            }
        }
        try afterValidation()

        var report = TagArchiveReport()
        for (entry, target) in zip(archive.files, validated) {
            let url = target.url
            guard let validatedStamp = target.stamp else {
                report.missing.append(entry.path)
                continue
            }
            do {
                guard let current = FileStamp.current(of: url),
                      current.hasSameFileIdentity(as: validatedStamp) else {
                    // Bewusst nur dieser Eintrag: Die übrigen Ziele werden
                    // einzeln genauso geprüft, und der Bericht soll weiterhin
                    // zeigen, was tatsächlich geschrieben wurde.
                    throw TagArchiveError.targetChangedAfterValidation(path: entry.path)
                }
                try target.requireCurrentDestination()
                if try applyEntry(
                    entry, to: url, dryRun: dryRun, expecting: validatedStamp,
                    beforeNoopReturn: beforeNoopReturn, backUp: backUp, validated: target) {
                    report.applied.append(entry.path)
                } else {
                    report.unchanged.append(entry.path)
                }
            } catch {
                report.failed.append(.init(path: entry.path, message: String(describing: error)))
            }
        }

        // Zusätzliche Mediendateien unterhalb des JSON-Ordners melden.
        // `expandMediaFiles` liefert kanonische URLs. Auch die Archiv-Ziele
        // müssen daher vor dem Vergleich Symlinks auflösen, sonst würde eine
        // bereits bekannte Datei fälschlich als zusätzlicher Fund erscheinen.
        let known = Set(targets.map(\.path))
        for url in MediaFormats.expandMediaFiles([baseDirectory])
        where !known.contains(MediaFormats.canonicalFileURL(url).path) {
            report.extra.append(relativePath(of: url, to: baseDirectory))
        }
        return report
    }

    /// Wendet einen Eintrag an; true = Datei wurde (bzw. würde) geändert.
    private static func applyEntry(
        _ entry: TagArchive.Entry,
        to url: URL,
        dryRun: Bool,
        expecting stamp: FileStamp,
        beforeNoopReturn: (URL) throws -> Void,
        backUp: (URL) throws -> Void,
        validated: ValidatedTarget
    ) throws -> Bool {
        switch entry.kind {
        case .audio:
            let snapshot = try FileSnapshot.capture(at: url, expecting: stamp) {
                try TagFile.read(at: url)
            }
            let current = snapshot.value
            // validate(_:) garantiert diese Pflichtangabe. Das unwrap verhindert
            // trotzdem, dass ein späterer Refactor nil als "alle Tags löschen"
            // missversteht.
            guard let targetProperties = entry.properties else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "properties")
            }
            let targetArtworks = entry.artworks
            let propertiesDiffer = TagProperty.valuesByKey(current.properties) != targetProperties
            // Ohne Cover im Archiv (--without-covers) bleiben Cover unangetastet.
            let artworksDiffer = targetArtworks.map { $0 != current.artworks } ?? false
            let chaptersDiffer = entry.chapters.map { $0 != current.chapters } ?? false
            let syncedDiffer = entry.syncedLyrics.map { $0 != current.syncedLyrics } ?? false
            let languageDiffer = entry.lyricsLanguage.map { $0 != current.lyricsLanguage } ?? false
            let syncedLanguageDiffer = entry.syncedLyricsLanguage.map { $0 != current.syncedLyricsLanguage } ?? false
            guard propertiesDiffer || artworksDiffer || chaptersDiffer || syncedDiffer || languageDiffer || syncedLanguageDiffer else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try backUp(url)
                try TagFile.write(properties: propertyList(targetProperties),
                                  artworks: artworksDiffer ? targetArtworks : nil,
                                  chapters: chaptersDiffer ? entry.chapters : nil,
                                  syncedLyrics: syncedDiffer ? entry.syncedLyrics : nil,
                                  lyricsLanguage: languageDiffer ? entry.lyricsLanguage : nil,
                                  syncedLyricsLanguage: syncedLanguageDiffer || syncedDiffer || languageDiffer ? entry.syncedLyricsLanguage : nil,
                                  to: url,
                                  expecting: snapshot.stamp,
                                  allowingArchivedValues: true)
            }
            return true
        case .image:
            let snapshot = try ExifTool.readCoreFieldsSnapshot(
                url: url, expecting: stamp)
            try validated.requireCurrentDestination()
            let current = snapshot.value.fields
            guard let target = entry.image, target != current else {
                try beforeNoopReturn(url)
                try validated.requireCurrentDestination()
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Der Archivweg schreibt auch beim Dry-run zuerst auf eine
            // Geschwisterkopie und liest sie exakt zurück. Damit meldet er
            // Normalisierungen wie 48.1000 → 48.1 vor einer Sicherung. Beim
            // echten Lauf setzt der atomare Rahmen genau diese geprüfte Kopie
            // ein, statt exiftool ein zweites Mal auszuführen.
            // Kamera-RAW und Bilder mit vorhandener Sidecar schreibt der Import
            // in die Sidecar; gesichert wird dann diese, nicht das Bild.
            let destination = validated.destination ?? ExifTool.writeDestination(for: url, preferSidecar: false)
            try ExifTool.writeArchivedCoreFields(
                url: url, fields: target, original: current,
                expecting: snapshot.stamp, to: destination,
                sidecar: snapshot.value.sidecar, dryRun: dryRun,
                beforeReplace: {
                    try validated.requireCurrentDestination()
                    try backUp(destination.url)
                })
            return true
        case .ebook:
            guard let target = entry.ebook else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "ebook")
            }
            let targetArtworks = EbookTool.supportsCover(url: url) ? entry.artworks : nil
            let snapshot = try EbookTool.readSnapshot(
                url: url, includeCover: targetArtworks != nil, expecting: stamp)
            let current = snapshot.value.fields
            let fieldsDiffer = target != current
            let targetCover = targetArtworks?.first
            let currentCover = snapshot.value.cover
            // nil: Cover wurden nicht archiviert und bleiben deshalb unangetastet.
            // []: Das Archiv verlangt ausdrücklich, ein vorhandenes Cover zu entfernen.
            let coverDiffers = targetArtworks.map { _ in
                currentCover?.data != targetCover?.data
            } ?? false
            guard fieldsDiffer || coverDiffers else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Wie beim Bild: Was das Ziel-Backend nicht schreiben kann
            // (Serienindex ohne Serie außerhalb von EPUB, Coverformat außerhalb
            // des Backend-Vertrags), scheitert für Dry-run und Import gleich —
            // vor der Papierkorb-Sicherung, nicht erst mitten im Schreibweg.
            try EbookTool.requireStorableSeries(target, original: current, url: url)
            if coverDiffers, let targetCover {
                try EbookTool.requireSupportedCover(targetCover.data, for: url)
            }
            if !dryRun {
                let coverUpdate: EbookCoverUpdate
                if !coverDiffers {
                    coverUpdate = .unchanged
                } else if let targetCover {
                    coverUpdate = .set(targetCover.data)
                } else {
                    coverUpdate = .remove
                }
                try snapshot.requireCurrent(at: url)
                try backUp(url)
                try EbookTool.write(
                    url: url, fields: target, original: current,
                    coverUpdate: coverUpdate, expecting: snapshot.stamp)
            }
            return true
        case .document:
            guard let target = entry.document else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "document")
            }
            let snapshot = try DocumentTool.readSnapshot(
                url: url, includeCover: false, expecting: stamp)
            let current = snapshot.value.fields
            guard target != current else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Was das Zielformat nicht speichern kann (Feld ohne Speicherort,
            // Datumsform), scheitert für Dry-run und Import gleich — vor der
            // Papierkorb-Sicherung.
            try DocumentTool.requireWritable(target, original: current, url: url)
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try backUp(url)
                try DocumentTool.write(url: url, fields: target, original: current,
                                       expecting: snapshot.stamp)
            }
            return true
        case .sidecar:
            guard let target = entry.nfo else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "nfo")
            }
            let snapshot = try KodiNFOFile.readSnapshot(url: url, expecting: stamp)
            guard !snapshot.value.isURLOnly else { throw TagError.urlOnlyNFO(path: url.path) }
            let current = snapshot.value.fields
            guard target != current else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Unbrauchbare Werte (Jahr, Zahlen) scheitern vor der Sicherung.
            try KodiNFOFile.validate(target, original: current)
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try backUp(url)
                try KodiNFOFile.write(url: url, fields: target, original: current,
                                      expecting: snapshot.stamp)
            }
            return true
        case .invoice, .playlist:
            // Export erzeugt solche Einträge nie (build überspringt sie);
            // ein handgebautes Archiv mit Rechnungs-/Playlist-Eintrag ist fehlerhaft.
            throw TagArchiveError.inconsistentEntry(
                path: entry.path, detail: "invoices and playlists cannot be archived")
        }
    }

    /// PropertyMap-Wörterbuch → [TagProperty] (Schlüssel sortiert, damit das
    /// Ergebnis deterministisch ist).
    private static func propertyList(_ map: [String: [String]]) -> [TagProperty] {
        map.keys.sorted().flatMap { key in
            map[key]!.map { TagProperty(key: key, value: $0) }
        }
    }
}
