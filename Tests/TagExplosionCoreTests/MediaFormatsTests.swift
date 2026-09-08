// Dateiauswahl darf nicht vom Aufrufweg abhängen: Finder-Ordner, einzelne
// Datei und Symlink müssen dieselbe, sortierte Liste ergeben.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("MediaFormats")
struct MediaFormatsTests {

    @Test("Ordner, Einzeldatei und Doppelaufruf werden kanonisch dedupliziert")
    func expansionFiltersAndDeduplicatesStably() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-mediaformats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let music = root.appendingPathComponent("Musik")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let first = music.appendingPathComponent("A.mp3")
        let second = music.appendingPathComponent("B.flac")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        // Eine Endung macht aus einem Verzeichnis noch keine abspielbare Datei.
        let misleadingDirectory = music.appendingPathComponent("Archiv.mp3")
        try FileManager.default.createDirectory(at: misleadingDirectory,
                                                withIntermediateDirectories: true)
        try Data("kein Medium".utf8).write(
            to: misleadingDirectory.appendingPathComponent("notiz.txt"))

        let alias = root.appendingPathComponent("Alias-zu-A.mp3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)

        let expanded = MediaFormats.expandMediaFiles([
            first, music, music, alias, misleadingDirectory,
        ])
        #expect(expanded == [
            MediaFormats.canonicalFileURL(first),
            MediaFormats.canonicalFileURL(second),
        ])
    }

    @Test("Kamera-RAW, neue Bildformate und .xmp zählen als Bild")
    func rawAndSidecarExtensionsAreImages() {
        for ext in ["cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef",
                    "avif", "jxl", "bmp", "psd", "svg", "xmp", "NEF"] {
            let url = URL(fileURLWithPath: "/tmp/foto.\(ext)")
            #expect(MediaFormats.kind(of: url) == .image, Comment(rawValue: ext))
        }
        #expect(MediaFormats.isRawImage(URL(fileURLWithPath: "/tmp/a.CR2")))
        #expect(!MediaFormats.isRawImage(URL(fileURLWithPath: "/tmp/a.dng")))
        #expect(MediaFormats.sidecarURL(for: URL(fileURLWithPath: "/tmp/IMG_1.CR2")).path == "/tmp/IMG_1.xmp")
        #expect(MediaFormats.sidecarURL(for: URL(fileURLWithPath: "/tmp/IMG_1.xmp")).path == "/tmp/IMG_1.xmp")
    }

    @Test("Mitgelesene Sidecars werden versteckt, eigenständige Sidecars bleiben",
          arguments: [("nef", "xmp"), ("nef", "XMP"), ("mp4", "nfo"), ("mp4", "NFO")])
    func sidecarsOfListedImagesAreHidden(format: (String, String)) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-sidecars-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = root.appendingPathComponent("IMG_1").appendingPathExtension(format.0)
        let rawSidecar = root.appendingPathComponent("IMG_1").appendingPathExtension(format.1)
        let lone = root.appendingPathComponent("notiz.xmp")
        for url in [raw, rawSidecar, lone] {
            try Data("<movie/>".utf8).write(to: url)
        }
        let expanded = MediaFormats.expandMediaFiles([root])
        // Ausblenden nur, wenn der Backend-Pfad dieselbe Sidecar tatsächlich
        // findet; auf case-sensitiven Volumes bleibt eine .XMP eigenständig.
        let backendPath = raw.deletingPathExtension().appendingPathExtension(format.1.lowercased())
        let isReadByOwner = FileManager.default.fileExists(atPath: backendPath.path)
        #expect(expanded.contains(MediaFormats.canonicalFileURL(rawSidecar)) == !isReadByOwner)
        #expect(expanded.contains(MediaFormats.canonicalFileURL(raw)))
        #expect(expanded.contains(MediaFormats.canonicalFileURL(lone)))
        #expect(expanded.count == (isReadByOwner ? 2 : 3))
        // Direkt angegeben wird die Sidecar geöffnet (als eigenes Format).
        #expect(MediaFormats.expandMediaFiles([rawSidecar]) == [MediaFormats.canonicalFileURL(rawSidecar)])
    }

    @Test("Neue Audio-/Container-Endungen laufen über den TagLib-Weg",
          arguments: ["mod", "s3m", "xm", "it", "au", "aifc", "mp2", "mka",
                      "3gp", "3g2", "ogv"])
    func newExtensionsAreAudioKind(ext: String) {
        let url = URL(fileURLWithPath: "/nirgends/datei.\(ext)")
        #expect(MediaFormats.kind(of: url) == .audio, Comment(rawValue: ext))
        // Großschreibung der Endung darf nichts ändern.
        #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/nirgends/DATEI.\(ext.uppercased())")) == .audio)
    }

    @Test("Format-Regeln: Feldliste, Cover und Anzeige-Toleranz")
    func formatRules() {
        func url(_ ext: String) -> URL { URL(fileURLWithPath: "/nirgends/datei.\(ext)") }
        // Tracker-Module: nur Titel/Kommentar/Tracker-Name, kein Cover.
        for ext in ["mod", "s3m", "xm", "it"] {
            #expect(MediaFormats.writableTagKeys(for: url(ext)) == ["TITLE", "COMMENT", "TRACKERNAME"], Comment(rawValue: ext))
            #expect(!MediaFormats.supportsEmbeddedArtwork(url(ext)), Comment(rawValue: ext))
            #expect(!MediaFormats.toleratesMissingTagReader(url(ext)), Comment(rawValue: ext))
        }
        // Volle PropertyMap-Formate: keine Einschränkung, Cover möglich.
        for ext in ["mp3", "mp2", "aifc", "3gp", "3g2", "m4a"] {
            #expect(MediaFormats.writableTagKeys(for: url(ext)) == nil, Comment(rawValue: ext))
            #expect(MediaFormats.supportsEmbeddedArtwork(url(ext)), Comment(rawValue: ext))
        }
        // Matroska: Tags ja, Cover nein.
        for ext in ["mka", "mkv", "webm"] {
            #expect(!MediaFormats.supportsEmbeddedArtwork(url(ext)), Comment(rawValue: ext))
        }
        // Ohne TagLib-Leser: öffnen erlaubt, aber nur zur Anzeige.
        for ext in ["au", "ogv", "avi", "mov"] {
            #expect(MediaFormats.toleratesMissingTagReader(url(ext)), Comment(rawValue: ext))
        }
        #expect(!MediaFormats.toleratesMissingTagReader(url("flac")))
        #expect(!MediaFormats.supportsEmbeddedArtwork(url("au")))
    }
}
