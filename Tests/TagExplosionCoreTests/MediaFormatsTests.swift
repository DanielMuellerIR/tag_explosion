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
