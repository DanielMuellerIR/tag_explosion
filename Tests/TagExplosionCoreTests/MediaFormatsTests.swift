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
}
