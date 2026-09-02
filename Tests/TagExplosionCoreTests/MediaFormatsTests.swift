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

    @Test("Sidecar eines gelisteten Bildes wird versteckt, eine .xmp ohne Bild bleibt")
    func sidecarsOfListedImagesAreHidden() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-sidecars-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = root.appendingPathComponent("IMG_1.nef")
        let rawSidecar = root.appendingPathComponent("IMG_1.xmp")
        let lone = root.appendingPathComponent("notiz.xmp")
        for url in [raw, rawSidecar, lone] {
            try Data("x".utf8).write(to: url)
        }
        let expanded = MediaFormats.expandMediaFiles([root])
        #expect(expanded == [
            MediaFormats.canonicalFileURL(raw),
            MediaFormats.canonicalFileURL(lone),
        ])
        // Direkt angegeben wird die Sidecar geöffnet (als eigenes Format).
        #expect(MediaFormats.expandMediaFiles([rawSidecar]) == [MediaFormats.canonicalFileURL(rawSidecar)])
    }
}
