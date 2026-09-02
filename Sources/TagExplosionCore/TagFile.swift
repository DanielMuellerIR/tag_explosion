// Swift-Fassade über den C-Shim (CTagShim). Öffnet eine Datei, liest/schreibt
// Tags und Bilder. Ein `TagFile` hält das TagLib-Handle bis `close()`/deinit.
import CTagShim
import Foundation

/// Zugriff auf die Tags einer einzelnen Mediendatei.
///
/// Typischer Ablauf:
/// ```swift
/// let data = try TagFile.read(at: url)                  // nur lesen
/// try TagFile.write(properties: ..., artworks: ..., to: url)  // ändern
/// ```
public final class TagFile {
    private var handle: OpaquePointer?
    public let path: String

    /// Öffnet die Datei; wirft `TagError.cannotOpen`, wenn TagLib sie nicht lesen kann.
    public init(path: String) throws {
        guard let h = tx_open(path) else {
            throw TagError.cannotOpen(path: path)
        }
        self.handle = h
        self.path = path
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    deinit { close() }

    /// Gibt das TagLib-Handle explizit frei (idempotent).
    public func close() {
        if let h = handle {
            tx_close(h)
            handle = nil
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let h = handle else { throw TagError.cannotOpen(path: path) }
        return h
    }

    public var isReadOnly: Bool {
        guard let h = handle else { return true }
        return tx_is_readonly(h) != 0
    }

    // MARK: - Lesen

    /// Alle Textfelder. Felder mit eigenem Speicherort außerhalb der
    /// PropertyMap (`FixedFields.nativeSlots`, z.B. das Podcast-Flag oder
    /// TKWD/keyw) kommen aus dem Frame/Atom und verdrängen einen gleichnamigen
    /// PropertyMap-Wert.
    public func properties() throws -> [TagProperty] {
        let h = try requireHandle()
        var count: Int32 = 0
        let raw = tx_get_properties(h, &count)
        defer { tx_free_properties(raw, count) }
        guard count >= 0 else { throw TagError.cannotOpen(path: path) }
        var result: [TagProperty] = []
        if let raw, count > 0 {
            result = (0..<Int(count)).map { i in
                TagProperty(
                    key: String(cString: raw[i].key),
                    value: String(cString: raw[i].value)
                )
            }
        }
        for slot in supportedNativeSlots() {
            result.removeAll { $0.key == slot.key }
            if let value = nativeValue(slot) {
                result.append(TagProperty(key: slot.key, value: value))
            }
        }
        return result
    }

    /// Die festen Felder, die diese Datei als Frame/Atom statt über die
    /// PropertyMap führt (leer bei Formaten ohne ID3v2/MP4).
    private func supportedNativeSlots() -> [FixedFields.NativeSlot] {
        guard let h = handle else { return [] }
        return FixedFields.nativeSlots.filter {
            tx_native_field_supported(h, $0.id3Frame, $0.mp4Atom) == 1
        }
    }

    private func nativeValue(_ slot: FixedFields.NativeSlot) -> String? {
        guard let h = handle, let raw = tx_get_native_field(h, slot.id3Frame, slot.mp4Atom) else {
            return nil
        }
        defer { free(raw) }
        return String(cString: raw)
    }

    // MARK: - Lyrics

    /// Ob die Datei einen ID3v2-Tag trägt — nur dort gibt es SYLT und die
    /// Sprache der Lyrics (MP3/MP2, WAV, AIFF, DSF).
    public var supportsSyncedLyrics: Bool {
        guard let h = handle else { return false }
        return tx_id3v2_supported(h) != 0
    }

    /// Sprache der unsynchronisierten Lyrics (USLT); leer = unbekannt/keine.
    public func lyricsLanguage() -> String {
        guard let h = handle, let raw = tx_get_lyrics_language(h) else { return "" }
        defer { free(raw) }
        return FixedFields.normalizedLanguage(String(cString: raw))
    }

    /// Synchronisierte Lyrics (SYLT) in Zeitreihenfolge; leer ohne SYLT.
    public func syncedLyrics() throws -> [SyncedLyricLine] {
        let h = try requireHandle()
        var count: Int32 = 0
        let raw = tx_get_synced_lyrics(h, &count, nil)
        defer { tx_free_synced_lyrics(raw, count) }
        guard count >= 0 else { throw TagError.cannotOpen(path: path) }
        guard let raw, count > 0 else { return [] }
        return (0..<Int(count)).map { i in
            SyncedLyricLine(milliseconds: Int(raw[i].time_ms), text: String(cString: raw[i].text))
        }
    }

    public func artworks() throws -> [Artwork] {
        let h = try requireHandle()
        var count: Int32 = 0
        let raw = tx_get_pictures(h, &count)
        defer { tx_free_pictures(raw, count) }
        guard count >= 0 else { throw TagError.cannotOpen(path: path) }
        guard let raw, count > 0 else { return [] }
        return (0..<Int(count)).map { i in
            let pic = raw[i]
            let data = pic.size > 0
                ? Data(bytes: pic.data, count: Int(pic.size))
                : Data()
            return Artwork(
                data: data,
                mimeType: String(cString: pic.mime),
                pictureType: String(cString: pic.picture_type),
                description: String(cString: pic.description)
            )
        }
    }

    /// Ob das Format der Datei Kapitel tragen kann (MP3, MP4, Matroska).
    public var supportsChapters: Bool {
        guard let h = handle else { return false }
        return tx_chapters_supported(h) != 0
    }

    /// Kapitel in Abspielreihenfolge. Formate ohne Kapitel liefern `[]`.
    ///
    /// MP4 kennt nur Startzeiten (der Shim liefert dort `end_ms == -1`). Das
    /// Ende wird deshalb hier ergänzt: nächster Kapitelbeginn, für das letzte
    /// Kapitel die Spielzeit der Datei (oder der eigene Beginn, wenn TagLib
    /// keine Spielzeit kennt).
    public func chapters() throws -> [Chapter] {
        let h = try requireHandle()
        var count: Int32 = 0
        let raw = tx_get_chapters(h, &count)
        defer { tx_free_chapters(raw, count) }
        guard count >= 0 else { throw TagError.cannotOpen(path: path) }
        guard let raw, count > 0 else { return [] }
        let length = audioInfo().map(\.lengthMilliseconds) ?? 0
        return (0..<Int(count)).map { i in
            let entry = raw[i]
            let start = Int(entry.start_ms)
            var end = Int(entry.end_ms)
            if end < 0 {
                let next = i + 1 < Int(count) ? Int(raw[i + 1].start_ms) : length
                end = max(start, next)
            }
            return Chapter(title: String(cString: entry.title),
                           startMilliseconds: start, endMilliseconds: end)
        }
    }

    /// Tag-Schichten der Datei (ID3v1, ID3v2, APE, RIFF INFO, Vorbis) — auch
    /// fehlende Schichten, damit die Anzeige weiß, was das Format kennt.
    /// Formate ohne Schichtenmodell liefern `[]`.
    public func layers() throws -> [TagLayer] {
        let h = try requireHandle()
        var count: Int32 = 0
        let raw = tx_layers_get(h, &count)
        defer { tx_free_layers(raw, count) }
        guard count >= 0 else { throw TagError.cannotOpen(path: path) }
        guard let raw, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            let entry = raw[i]
            guard let kind = TagLayerKind.fromShim(entry.kind) else { return nil }
            // Schlüssel kommen '\n'-getrennt aus dem Shim.
            let keys = String(cString: entry.keys)
            return TagLayer(kind: kind, version: Int(entry.version), present: entry.present == 1,
                            strippable: entry.strippable == 1,
                            fields: keys.isEmpty ? [] : keys.components(separatedBy: "\n"))
        }
    }

    public func audioInfo() -> AudioInfo? {
        guard let h = handle else { return nil }
        var props = tx_audio_properties()
        guard tx_get_audio_properties(h, &props) == 1 else { return nil }
        return AudioInfo(
            lengthMilliseconds: Int(props.length_ms),
            bitrateKbps: Int(props.bitrate_kbps),
            sampleRateHz: Int(props.sample_rate_hz),
            channels: Int(props.channels)
        )
    }

    /// Liest den kompletten Tag-Zustand in einem Rutsch.
    public func readAll() throws -> TagData {
        TagData(
            properties: try properties(),
            artworks: try artworks(),
            audio: audioInfo(),
            isReadOnly: isReadOnly,
            chapters: try chapters(),
            supportsChapters: supportsChapters,
            layers: try layers(),
            lyricsLanguage: lyricsLanguage(),
            syncedLyrics: try syncedLyrics(),
            supportsSyncedLyrics: supportsSyncedLyrics
        )
    }

    // MARK: - Schreiben

    /// Ersetzt alle Text-Properties (noch nicht persistent — `save()` aufrufen).
    /// Wirft `propertiesRejected`, wenn das Format Felder nicht aufnehmen kann;
    /// die restlichen Felder sind dann trotzdem gesetzt.
    ///
    /// Bewusst nicht public: Von außen führt jeder Schreibweg über das
    /// statische `write(properties:artworks:to:)` (Backup + atomarer
    /// Austausch). Ein öffentlicher Mutator würde einladen, TagLib in-place
    /// auf ein Original loszulassen.
    func setProperties(_ properties: [TagProperty]) throws {
        let h = try requireHandle()
        // Felder mit eigenem Frame/Atom gehen nicht durch die PropertyMap —
        // dort würden sie als TXXX/Freeform landen oder (PCST) verloren gehen.
        let nativeSlots = supportedNativeSlots()
        let nativeKeys = Set(nativeSlots.map(\.key))
        let plain = properties.filter { !nativeKeys.contains($0.key) }
        var cProps: [tx_prop] = []
        // C-Strings müssen bis zum Aufruf gültig bleiben — strdup + explizites free.
        cProps.reserveCapacity(plain.count)
        for prop in plain {
            cProps.append(tx_prop(key: strdup(prop.key), value: strdup(prop.value)))
        }
        defer {
            for p in cProps { free(p.key); free(p.value) }
        }
        let rejected = tx_set_properties(h, cProps, Int32(cProps.count))
        guard rejected >= 0 else { throw TagError.cannotOpen(path: path) }
        // Erst nach der PropertyMap, weil TagLib dort Frames ohne Schlüssel in
        // der neuen Map entfernt (das PCST-Flag) — der eigene Weg setzt sie
        // anschließend wieder. Ein fehlender Schlüssel entfernt das Feld.
        for slot in nativeSlots {
            let value = properties.first { $0.key == slot.key }?.value ?? ""
            guard tx_set_native_field(h, slot.id3Frame, slot.mp4Atom, value) == 1 else {
                throw TagError.saveFailed(path: path)
            }
        }
        if rejected > 0 { throw TagError.propertiesRejected(count: Int(rejected)) }
    }

    /// Ersetzt alle SYLT-Frames (leer = entfernen); nicht public — siehe
    /// `setProperties`. `language`: ISO 639-2 oder leer (= "XXX").
    func setSyncedLyrics(_ lines: [SyncedLyricLine], language: String) throws {
        let h = try requireHandle()
        guard supportsSyncedLyrics else { throw TagError.syncedLyricsUnsupported(path: path) }
        var cLines: [tx_synced_line] = []
        cLines.reserveCapacity(lines.count)
        for line in lines {
            cLines.append(tx_synced_line(text: strdup(line.text), time_ms: Int64(line.milliseconds)))
        }
        defer { for line in cLines { free(line.text) } }
        let lang = language.isEmpty ? "XXX" : language
        guard tx_set_synced_lyrics(h, cLines, Int32(cLines.count), lang) == 1 else {
            throw TagError.saveFailed(path: path)
        }
    }

    /// Setzt die Sprache aller USLT-Frames (leer = "XXX"). Ohne USLT-Frame
    /// passiert nichts; Formate ohne ID3v2 ignorieren den Aufruf.
    func setLyricsLanguage(_ language: String) throws {
        let h = try requireHandle()
        guard supportsSyncedLyrics else { return }
        let lang = language.isEmpty ? "XXX" : language
        guard tx_set_lyrics_language(h, lang) == 1 else { throw TagError.saveFailed(path: path) }
    }

    /// Ersetzt alle eingebetteten Bilder (noch nicht persistent — `save()`
    /// aufrufen). Nicht public — siehe `setProperties`.
    func setArtworks(_ artworks: [Artwork]) throws {
        let h = try requireHandle()
        // Bilddaten in stabile Heap-Puffer kopieren, damit die Pointer während
        // des C-Aufrufs garantiert gültig bleiben.
        var cPics: [tx_picture] = []
        cPics.reserveCapacity(artworks.count)
        for art in artworks {
            let size = art.data.count
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
            art.data.copyBytes(to: buffer, count: size)
            // Leerer MIME-Type wird beim Schreiben aus den Magic Bytes ergänzt,
            // damit Player das Bild zuverlässig anzeigen.
            cPics.append(tx_picture(
                data: buffer,
                size: Int32(size),
                mime: strdup(art.resolvedMimeType),
                picture_type: strdup(art.pictureType),
                description: strdup(art.description)
            ))
        }
        defer {
            for p in cPics {
                p.data?.deallocate()
                free(p.mime); free(p.picture_type); free(p.description)
            }
        }
        guard tx_set_pictures(h, cPics, Int32(cPics.count)) == 1 else {
            throw TagError.saveFailed(path: path)
        }
    }

    /// Ersetzt alle Kapitel (noch nicht persistent — `save()` aufrufen).
    /// Nicht public — siehe `setProperties`. Wirft `chaptersUnsupported`,
    /// wenn das Format keine Kapitel kennt.
    func setChapters(_ chapters: [Chapter]) throws {
        let h = try requireHandle()
        guard supportsChapters else { throw TagError.chaptersUnsupported(path: path) }
        // C-Strings bis zum Aufruf am Leben halten — strdup + explizites free.
        var cChapters: [tx_chapter] = []
        cChapters.reserveCapacity(chapters.count)
        for chapter in chapters {
            cChapters.append(tx_chapter(
                title: strdup(chapter.title),
                start_ms: Int64(chapter.startMilliseconds),
                end_ms: Int64(chapter.endMilliseconds)))
        }
        defer { for c in cChapters { free(c.title) } }
        guard tx_set_chapters(h, cChapters, Int32(cChapters.count)) == 1 else {
            throw TagError.saveFailed(path: path)
        }
    }

    /// Schreibt alle Änderungen in die Datei. TagLib schreibt dabei in-place —
    /// deshalb nicht public und nur innerhalb von `write(...)` auf der
    /// Geschwisterkopie erlaubt, nie auf einem Original.
    func save(id3Version: ID3Version = .v24) throws {
        let h = try requireHandle()
        if isReadOnly { throw TagError.readOnly(path: path) }
        // v2.4 ist TagLibs Standard; nur v2.3 braucht den Versions-Overload.
        let ok = id3Version == .v24 ? tx_save(h) : tx_save_id3v2(h, id3Version.shimValue)
        guard ok == 1 else { throw TagError.saveFailed(path: path) }
    }

    /// Entfernt Tag-Schichten und schreibt die Datei sofort (TagLibs
    /// `strip()` arbeitet in-place). Deshalb nicht public — von außen nur über
    /// das statische `stripLayers(_:from:)` auf der Geschwisterkopie.
    /// Wirft `layerUnsupported`, wenn das Format eine der Schichten nicht
    /// kennt oder nicht entfernen kann.
    func stripLayers(_ kinds: Set<TagLayerKind>) throws {
        let h = try requireHandle()
        if isReadOnly { throw TagError.readOnly(path: path) }
        let known = try layers()
        for kind in kinds {
            guard let layer = known.first(where: { $0.kind == kind }), layer.strippable else {
                throw TagError.layerUnsupported(path: path, layer: kind.rawValue)
            }
        }
        let mask = kinds.reduce(Int32(0)) { $0 | $1.shimMask }
        guard tx_layers_strip(h, mask) == 1 else { throw TagError.saveFailed(path: path) }
    }

    // MARK: - Bequeme statische Helfer

    /// Liest Tags, Bilder und Audio-Infos einer Datei.
    public static func read(at url: URL) throws -> TagData {
        let file = try TagFile(url: url)
        defer { file.close() }
        return try file.readAll()
    }

    /// Schreibt Properties, Artworks und/oder Kapitel in eine Datei
    /// (nil = unverändert lassen; `chapters: []` entfernt alle Kapitel).
    ///
    /// TagLib schreibt grundsätzlich in-place. Damit ein Absturz, ein voller
    /// Datenträger oder ein Formatfehler die Originaldatei nicht halb fertig
    /// zurücklässt, läuft der Schreibvorgang über eine Geschwisterkopie: Erst
    /// wird die Kopie beschrieben und geprüft, dann ersetzt sie das Original in
    /// einem einzigen atomaren Schritt.
    ///
    /// Nebenwirkung dieses Verfahrens: Die Datei bekommt eine neue Inode.
    /// Zusätzliche Hardlinks auf dieselben Daten zeigen danach weiter auf den
    /// alten Stand.
    ///
    /// `expecting` (optional): Stempel des Standes, den der Aufrufer gelesen
    /// hat. Weicht die Datei unmittelbar vor dem Austausch davon ab, bricht
    /// das Schreiben mit `fileChangedOnDisk` ab, statt die fremde Änderung zu
    /// überschreiben.
    ///
    /// `syncedLyrics` (nil = unverändert, `[]` = SYLT entfernen) und
    /// `lyricsLanguage` (nil = bisherige Sprache behalten) gibt es nur bei
    /// ID3v2-Trägern; andere Formate lehnen `syncedLyrics` ab und ignorieren
    /// die Sprache. Feste Felder (`FixedFields`) werden vor der Sicherung
    /// geprüft; ein ungültiger Wert lässt die Datei unangetastet.
    /// `id3Version`: ID3v2.4 (Standard) oder v2.3 für alte Player. Wirkt nur
    /// bei Formaten mit ID3v2 (MP3/MP2, WAV, AIFF, DSF); andere ignorieren sie.
    public static func write(
        properties: [TagProperty]? = nil,
        artworks: [Artwork]? = nil,
        chapters: [Chapter]? = nil,
        syncedLyrics: [SyncedLyricLine]? = nil,
        lyricsLanguage: String? = nil,
        to url: URL,
        expecting stamp: FileStamp? = nil,
        id3Version: ID3Version = .v24
    ) throws {
        // Vorher-Zustand als Vergleichsmaßstab für die Prüfung danach.
        let before = try TagFile.read(at: url)
        if before.isReadOnly { throw TagError.readOnly(path: url.path) }
        // Unstimmige Kapitel und Werte vor Kopie und Sicherung ablehnen — ein
        // Fehler NACH der Papierkorb-Kopie hinterließe eine sinnlose Sicherung.
        if let chapters {
            guard before.supportsChapters else { throw TagError.chaptersUnsupported(path: url.path) }
            try ChapterList.validate(chapters)
        }
        if let properties {
            try FixedFields.validate(properties, changedFrom: before.properties)
        }
        if let syncedLyrics {
            guard before.supportsSyncedLyrics else { throw TagError.syncedLyricsUnsupported(path: url.path) }
            try LRC.validate(syncedLyrics)
        }
        if let lyricsLanguage, !FixedFields.isValidLanguage(lyricsLanguage) {
            throw TagError.invalidFieldValue(
                field: "LYRICS language", reason: "expected three letters (ISO 639-2), got \"\(lyricsLanguage)\"")
        }
        let language = lyricsLanguage.map(FixedFields.normalizedLanguage) ?? before.lyricsLanguage

        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            let file = try TagFile(url: temp)
            defer { file.close() }
            if let properties { try file.setProperties(properties) }
            // Ein neuer Lyrics-Text bekommt von TagLib die Sprache "XXX" —
            // die gewünschte bzw. bisherige Sprache danach wieder setzen.
            if properties != nil || lyricsLanguage != nil { try file.setLyricsLanguage(language) }
            if let artworks { try file.setArtworks(artworks) }
            if let chapters { try file.setChapters(chapters) }
            if let syncedLyrics { try file.setSyncedLyrics(syncedLyrics, language: language) }
            try file.save(id3Version: id3Version)
        } validate: { temp in
            try validateWriteResult(at: temp, expecting: artworks, chapters: chapters,
                                    syncedLyrics: syncedLyrics,
                                    comparedTo: before.audio, originalPath: url.path)
        }
    }

    /// Entfernt Tag-Schichten (z.B. einen ID3v1-Rest neben ID3v2) aus einer
    /// Datei. Gleicher Sicherheitsrahmen wie `write`: Geschwisterkopie,
    /// Prüfung, atomarer Austausch. Der Aufrufer sichert vorher per
    /// `TrashBackup.shared.backUp(url)` — wie bei allen Schreibwegen.
    ///
    /// Geprüft wird auf der Kopie, dass jede genannte Schicht danach wirklich
    /// fehlt (FLAC-Vorbis: keine Felder mehr, TagLib behält den Vendor-Block)
    /// und dass der Audiostream unverändert ist.
    public static func stripLayers(
        _ kinds: Set<TagLayerKind>,
        from url: URL,
        expecting stamp: FileStamp? = nil
    ) throws {
        guard !kinds.isEmpty else { return }
        let before = try TagFile.read(at: url)
        if before.isReadOnly { throw TagError.readOnly(path: url.path) }
        // Unbekannte, fehlende oder nicht entfernbare Schichten VOR Kopie und
        // Sicherung ablehnen — ein Fehler danach hinterließe eine sinnlose
        // Papierkorb-Kopie.
        for kind in kinds {
            guard let layer = before.layers.first(where: { $0.kind == kind }),
                  layer.present, layer.strippable
            else { throw TagError.layerUnsupported(path: url.path, layer: kind.rawValue) }
        }

        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            let file = try TagFile(url: temp)
            defer { file.close() }
            try file.stripLayers(kinds) // schreibt sofort, kein save() danach
        } validate: { temp in
            let file = try TagFile(url: temp)
            defer { file.close() }
            let after = try file.layers()
            for kind in kinds {
                guard let layer = after.first(where: { $0.kind == kind }) else {
                    throw TagError.saveFailed(path: url.path)
                }
                // Vorbis-Block bleibt als leere Hülle stehen; Felder müssen weg sein.
                let gone = kind == .vorbis ? layer.fields.isEmpty : !layer.present
                guard gone else { throw TagError.saveFailed(path: url.path) }
            }
            try validateWriteResult(at: temp, expecting: nil, chapters: nil,
                                    comparedTo: before.audio, originalPath: url.path)
        }
    }

    /// Prüft die frisch beschriebene Kopie, bevor sie das Original ersetzt.
    ///
    /// Ein reiner Tag-Schreibvorgang darf den Audiostream nicht anfassen. Wenn
    /// Kanäle, Samplerate oder Spielzeit wegbrechen, hat TagLib die Datei
    /// beschädigt — dann bleibt das Original stehen.
    private static func validateWriteResult(
        at url: URL, expecting artworks: [Artwork]?, chapters: [Chapter]?,
        syncedLyrics: [SyncedLyricLine]? = nil,
        comparedTo before: AudioInfo?, originalPath: String
    ) throws {
        let file = try TagFile(url: url) // muss überhaupt wieder lesbar sein
        defer { file.close() }
        _ = try file.properties()

        if let syncedLyrics, (try file.syncedLyrics()) != syncedLyrics {
            throw TagError.saveFailed(path: originalPath)
        }

        if let artworks, (try file.artworks()).count != artworks.count {
            throw TagError.saveFailed(path: originalPath)
        }
        // Kapitel müssen in gleicher Zahl und mit gleichen Titeln und
        // Startzeiten zurückkommen. Das Ende wird nicht verglichen: MP4
        // speichert keins, dort ergibt es sich erst beim Lesen.
        if let chapters {
            let readBack = try file.chapters()
            guard readBack.count == chapters.count,
                  zip(readBack, chapters).allSatisfy({
                      $0.title == $1.title && $0.startMilliseconds == $1.startMilliseconds
                  })
            else { throw TagError.saveFailed(path: originalPath) }
        }

        guard let before, before.lengthMilliseconds > 0 else { return }
        guard let after = file.audioInfo() else {
            throw TagError.saveFailed(path: originalPath)
        }
        // Zwei Prozent Toleranz: manche Formate berechnen die Spielzeit aus der
        // Dateigröße, die sich mit der Tag-Größe minimal verschiebt.
        let tolerance = max(1000, before.lengthMilliseconds / 50)
        guard after.channels == before.channels,
              after.sampleRateHz == before.sampleRateHz,
              abs(after.lengthMilliseconds - before.lengthMilliseconds) <= tolerance
        else { throw TagError.saveFailed(path: originalPath) }
    }

    /// Version der gelinkten TagLib, z.B. "2.3.0".
    public static var tagLibVersion: String {
        String(cString: tx_taglib_version())
    }
}
