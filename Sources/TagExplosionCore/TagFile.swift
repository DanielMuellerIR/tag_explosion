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

    public func properties() throws -> [TagProperty] {
        let h = try requireHandle()
        var count: Int32 = 0
        let raw = tx_get_properties(h, &count)
        defer { tx_free_properties(raw, count) }
        guard count >= 0 else { throw TagError.cannotOpen(path: path) }
        guard let raw, count > 0 else { return [] }
        return (0..<Int(count)).map { i in
            TagProperty(
                key: String(cString: raw[i].key),
                value: String(cString: raw[i].value)
            )
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
            isReadOnly: isReadOnly
        )
    }

    // MARK: - Schreiben

    /// Ersetzt alle Text-Properties (noch nicht persistent — `save()` aufrufen).
    /// Wirft `propertiesRejected`, wenn das Format Felder nicht aufnehmen kann;
    /// die restlichen Felder sind dann trotzdem gesetzt.
    public func setProperties(_ properties: [TagProperty]) throws {
        let h = try requireHandle()
        var cProps: [tx_prop] = []
        // C-Strings müssen bis zum Aufruf gültig bleiben — strdup + explizites free.
        cProps.reserveCapacity(properties.count)
        for prop in properties {
            cProps.append(tx_prop(key: strdup(prop.key), value: strdup(prop.value)))
        }
        defer {
            for p in cProps { free(p.key); free(p.value) }
        }
        let rejected = tx_set_properties(h, cProps, Int32(cProps.count))
        guard rejected >= 0 else { throw TagError.cannotOpen(path: path) }
        if rejected > 0 { throw TagError.propertiesRejected(count: Int(rejected)) }
    }

    /// Ersetzt alle eingebetteten Bilder (noch nicht persistent — `save()` aufrufen).
    public func setArtworks(_ artworks: [Artwork]) throws {
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

    /// Schreibt alle Änderungen in die Datei.
    public func save() throws {
        let h = try requireHandle()
        if isReadOnly { throw TagError.readOnly(path: path) }
        guard tx_save(h) == 1 else { throw TagError.saveFailed(path: path) }
    }

    // MARK: - Bequeme statische Helfer

    /// Liest Tags, Bilder und Audio-Infos einer Datei.
    public static func read(at url: URL) throws -> TagData {
        let file = try TagFile(url: url)
        defer { file.close() }
        return try file.readAll()
    }

    /// Schreibt Properties und/oder Artworks in eine Datei (nil = unverändert lassen).
    public static func write(
        properties: [TagProperty]? = nil,
        artworks: [Artwork]? = nil,
        to url: URL
    ) throws {
        let file = try TagFile(url: url)
        defer { file.close() }
        if let properties { try file.setProperties(properties) }
        if let artworks { try file.setArtworks(artworks) }
        try file.save()
    }

    /// Version der gelinkten TagLib, z.B. "2.3.0".
    public static var tagLibVersion: String {
        String(cString: tx_taglib_version())
    }
}
