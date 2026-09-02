// Echte CLI-Regressionen für `tagx layers` und `tagx set --id3v23`: Text- und
// JSON-Ausgabe, Entfernen einer Schicht, Exit-Codes bei fehlender oder
// unbekannter Schicht (Datei bleibt bytegleich) und die v2.3-Schreiboption.
import Foundation
import Testing
import TagExplosionCore

@Suite("tagx layers", .serialized)
struct LayersCommandTests {

    @Test("show listet Schichten, strip entfernt ID3v1 und lässt ID3v2 stehen",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func showAndStrip() throws {
        let directory = try makeWorkDirectory("tagx-layers")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)

        // Frisch: nur ID3v2.4.
        let fresh = try runTagx(arguments: ["layers", "show", file.path])
        #expect(fresh.status == 0, Comment(rawValue: fresh.stderr))
        #expect(fresh.stdout.contains("id3v1: ID3v1 · absent"))
        #expect(fresh.stdout.contains("id3v2: ID3v2.4 · present"))

        // `set` erzeugt zusätzlich ID3v1.
        let set = try runTagx(arguments: ["set", file.path, "-t", "TITLE=Zwei", "--no-backup"])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        let json = try runTagx(arguments: ["layers", "show", file.path, "--json"])
        #expect(json.status == 0)
        let report = try JSONDecoder().decode(Report.self, from: Data(json.stdout.utf8))
        #expect(report.layers.map(\.kind) == [.id3v1, .id3v2, .ape])
        #expect(report.layers[0].present && report.layers[0].fields == ["TITLE"])
        #expect(report.layers[1].version == 4)
        #expect(!report.layers[2].present)

        let strip = try runTagx(arguments: ["layers", "strip", file.path, "--layer", "id3v1", "--no-backup"])
        #expect(strip.status == 0, Comment(rawValue: strip.stderr))
        #expect(strip.stdout.contains("layer(s) removed: id3v1"))
        let after = try TagFile.read(at: file)
        #expect(after.layers.first { $0.kind == .id3v1 }?.present == false)
        #expect(after.layers.first { $0.kind == .id3v2 }?.present == true)
        #expect(after.firstValue(for: "TITLE") == "Zwei")

        // Dieselbe Schicht noch einmal: Fehler 64, Datei unverändert.
        let bytes = try Data(contentsOf: file)
        let again = try runTagx(arguments: ["layers", "strip", file.path, "--layer", "id3v1", "--no-backup"])
        #expect(again.status == 64)
        #expect(again.stderr.contains("not present or cannot be removed"))
        #expect(try Data(contentsOf: file) == bytes)

        // Unbekannter Schichtname.
        let unknown = try runTagx(arguments: ["layers", "strip", file.path, "--layer", "xyz", "--no-backup"])
        #expect(unknown.status == 64)
        #expect(unknown.stderr.contains("Unknown layer"))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Formate ohne Schichten: show liefert leere Liste, strip scheitert mit 64",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func formatWithoutLayers() throws {
        let directory = try makeWorkDirectory("tagx-layers-m4a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.m4a")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.m4a"), to: file)
        let before = try Data(contentsOf: file)

        let show = try runTagx(arguments: ["layers", "show", file.path, "--json"])
        #expect(show.status == 0)
        let report = try JSONDecoder().decode(Report.self, from: Data(show.stdout.utf8))
        #expect(report.layers.isEmpty)
        let text = try runTagx(arguments: ["layers", "show", file.path])
        #expect(text.status == 0)
        #expect(text.stdout.isEmpty)
        #expect(text.stderr.contains("no tag layers"))

        let strip = try runTagx(arguments: ["layers", "strip", file.path, "--layer", "id3v2", "--no-backup"])
        #expect(strip.status == 64)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("set --id3v23 schreibt ID3v2.3 mit Umlauten und Datum",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func setWithID3v23() throws {
        let directory = try makeWorkDirectory("tagx-id3v23")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("alt.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)

        let set = try runTagx(arguments: ["set", file.path, "-t", "TITLE=Grüße", "DATE=2024-03-15",
                                          "--id3v23", "--no-backup"])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        let show = try runTagx(arguments: ["layers", "show", file.path, "--json"])
        let report = try JSONDecoder().decode(Report.self, from: Data(show.stdout.utf8))
        #expect(report.layers.first { $0.kind == .id3v2 }?.version == 3)
        let data = try TagFile.read(at: file)
        #expect(data.firstValue(for: "TITLE") == "Grüße")
        #expect(data.firstValue(for: "DATE") == "2024-03-15")
    }

    // MARK: - Helfer

    /// Spiegel der CLI-JSON-Ausgabe (`LayerReport` ist im CLI-Target privat).
    private struct Report: Decodable {
        var file: String
        var layers: [TagLayer]
    }

    private func makeWorkDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Baut das CLI-Produkt und startet genau das entstandene Binary.
    private func runTagx(arguments: [String]) throws -> CapturedProcessResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runCapturedProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return try runCapturedProcess(
            executable: URL(fileURLWithPath: binaryDirectory).appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
    }
}
