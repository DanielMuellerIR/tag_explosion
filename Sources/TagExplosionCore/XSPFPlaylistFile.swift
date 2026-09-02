// XSPF-Playlist (XML Shareable Playlist Format, Namensraum
// http://xspf.org/ns/0/):
//
//   <playlist version="1" xmlns="http://xspf.org/ns/0/">
//     <title>…</title><creator>…</creator>
//     <trackList>
//       <track><location>file:///…</location><title>…</title>
//              <creator>…</creator><album>…</album><duration>ms</duration></track>
//     </trackList>
//   </playlist>
//
// Gelesen wird über lokale Elementnamen (XMLTools); geschrieben werden nur
// title/creator der Liste und title/creator der Tracks. Unbekannte Elemente
// (annotation, extension, meta …) bleiben erhalten; wie bei den Dokument-
// Backends wird das XML beim Schreiben neu eingerückt.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum XSPFPlaylistFile: PlaylistBackend {

    static let supportedFields: Set<PlaylistField> = [
        .title, .performer, .entryTitle, .entryPerformer,
    ]

    static let namespaceURI = "http://xspf.org/ns/0/"

    private static func load(url: URL) throws -> (XMLDocument, XMLElement, [XMLElement]) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: url.path)
        }
        let document = try XMLTools.document(from: data, path: url.path)
        guard let root = document.rootElement(), XMLTools.localName(root) == "playlist" else {
            throw TagError.cannotOpen(path: url.path)
        }
        let tracks = XMLTools.firstElement(named: "trackList", in: root)
            .map { XMLTools.elements(named: "track", in: $0) } ?? []
        return (document, root, tracks)
    }

    // MARK: - Lesen

    static func read(url: URL, base: URL) throws -> PlaylistContents {
        let (_, root, tracks) = try load(url: url)
        var entries: [PlaylistEntry] = []
        for (offset, track) in tracks.enumerated() {
            let duration = Int(XMLTools.text(of: "duration", in: track))
            entries.append(PlaylistTool.makeEntry(
                number: offset + 1, location: XMLTools.text(of: "location", in: track), base: base,
                title: XMLTools.text(of: "title", in: track),
                performer: XMLTools.text(of: "creator", in: track),
                album: XMLTools.text(of: "album", in: track),
                durationMilliseconds: duration.flatMap { $0 >= 0 ? $0 : nil }))
        }
        let fields = PlaylistCoreFields(
            title: XMLTools.text(of: "title", in: root),
            performer: XMLTools.text(of: "creator", in: root),
            entries: entries.map(\.fields))
        var info: [DocumentInfoItem] = []
        for name in ["annotation", "info", "date", "license"] {
            let value = XMLTools.text(of: name, in: root)
            if !value.isEmpty { info.append(DocumentInfoItem(label: name, value: value)) }
        }
        return PlaylistContents(format: .xspf, fields: fields, entries: entries, info: info)
    }

    // MARK: - Schreiben

    static func validate(_ fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {}

    static func mutate(url: URL, fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {
        let (document, root, tracks) = try load(url: url)
        // XSPF nutzt den Standard-Namensraum (kein Präfix); neue Elemente
        // erben ihn vom Elternelement.
        let prefix = root.resolvePrefix(forNamespaceURI: namespaceURI) ?? ""
        if fields.title != original.title {
            XMLTools.setSingle(root, "title", prefix: prefix, value: fields.title) {
                root.insertChild($0, at: 0)
            }
        }
        if fields.performer != original.performer {
            XMLTools.setSingle(root, "creator", prefix: prefix, value: fields.performer) {
                // Hinter den Titel, sonst an den Anfang.
                let position = XMLTools.firstElement(named: "title", in: root)?.index ?? -1
                root.insertChild($0, at: position + 1)
            }
        }
        for (index, entry) in fields.entries.enumerated() where index < tracks.count {
            let track = tracks[index]
            if entry.title != original.entries[index].title {
                XMLTools.setSingle(track, "title", prefix: prefix, value: entry.title) {
                    let position = XMLTools.firstElement(named: "location", in: track)?.index ?? -1
                    track.insertChild($0, at: position + 1)
                }
            }
            if entry.performer != original.entries[index].performer {
                XMLTools.setSingle(track, "creator", prefix: prefix, value: entry.performer) {
                    let anchor = XMLTools.firstElement(named: "title", in: track)
                        ?? XMLTools.firstElement(named: "location", in: track)
                    track.insertChild($0, at: (anchor?.index ?? -1) + 1)
                }
            }
        }
        do {
            try XMLTools.serialize(document).write(to: url)
        } catch {
            throw TagError.saveFailed(path: url.path)
        }
    }
}
