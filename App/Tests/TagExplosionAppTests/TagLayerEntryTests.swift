// Tag-Schichten im Editor-Modell: Schichten nur bei Audio, Entfernen nur auf
// sauberer Datei, echter Strip auf einer Fixture-Kopie mit Neuladen — und
// die Einstellung „ID3v2.3 schreiben" mit Voreinstellung aus. Headless.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("FileEntry Tag-Schichten", .serialized)
@MainActor
struct TagLayerEntryTests {

    private let sampleLayers = [
        TagLayer(kind: .id3v1, version: 1, present: true, strippable: true, fields: ["TITLE"]),
        TagLayer(kind: .id3v2, version: 4, present: true, strippable: true, fields: ["TITLE", "ARTIST"]),
        TagLayer(kind: .ape, version: 0, present: false, strippable: true, fields: []),
    ]

    @Test("Schichten kommen aus dem Original und nur bei Audio")
    func layersComeFromOriginal() {
        let audio = FileEntry(
            url: URL(fileURLWithPath: "/tmp/schichten.mp3"),
            loaded: .audio(TagData(properties: [], artworks: [], audio: nil, layers: sampleLayers)))
        #expect(audio.layers == sampleLayers)
        #expect(audio.layers.map(\.displayName) == ["ID3v1", "ID3v2.4", "APE"])

        let image = FileEntry(
            url: URL(fileURLWithPath: "/tmp/bild.jpg"),
            loaded: .image(ImageCoreReading(fields: ImageCoreFields())))
        #expect(image.layers.isEmpty)
    }

    @Test("Entfernen läuft nicht auf einer Datei mit ungespeicherten Änderungen")
    func stripRefusesDirtyEntry() async {
        let entry = FileEntry(
            url: URL(fileURLWithPath: "/tmp/dirty.mp3"),
            loaded: .audio(TagData(properties: [], artworks: [], audio: nil, layers: sampleLayers)))
        entry.properties = [TagProperty(key: "TITLE", value: "geändert")]
        let model = AppModel()
        #expect(await model.stripLayer(entry: entry, kind: .id3v1) == false)
        // Der Puffer bleibt, es gibt keinen Fehler — der Knopf ist in der View gesperrt.
        #expect(entry.isDirty)
        #expect(entry.lastError == nil)
        #expect(model.alertMessage == nil)
    }

    @Test("Echter Strip: ID3v1 weg, Eintrag neu geladen und sauber",
          .enabled(if: LayerFixture.isAvailable, "Audio-Fixtures fehlen (ffmpeg)"))
    func stripReloadsEntry() async throws {
        let url = try LayerFixture.workingCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Zwei Schichten")], to: url)

        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        #expect(entry.layers.first { $0.kind == .id3v1 }?.present == true)

        let model = AppModel()
        #expect(await model.stripLayer(entry: entry, kind: .id3v1))

        #expect(entry.layers.first { $0.kind == .id3v1 }?.present == false)
        #expect(entry.layers.first { $0.kind == .id3v2 }?.present == true)
        #expect(entry.firstValue("TITLE") == "Zwei Schichten")
        #expect(!entry.isDirty)
        #expect(!entry.isSaving)
        #expect(entry.lastError == nil)

        // Noch einmal: Schicht fehlt → Fehler landet am Eintrag und im Alert.
        #expect(await model.stripLayer(entry: entry, kind: .id3v1) == false)
        #expect(entry.lastError?.contains("id3v1") == true)
        #expect(model.alertMessage?.contains("Schicht entfernen fehlgeschlagen") == true)
    }

    @Test("Einstellung ID3v2.3: Voreinstellung aus, Schalter wirkt")
    func id3VersionSetting() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppModel.id3v23DefaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: AppModel.id3v23DefaultsKey) }
            else { defaults.removeObject(forKey: AppModel.id3v23DefaultsKey) }
        }
        defaults.removeObject(forKey: AppModel.id3v23DefaultsKey)
        #expect(AppModel.preferredID3Version == .v24)
        defaults.set(true, forKey: AppModel.id3v23DefaultsKey)
        #expect(AppModel.preferredID3Version == .v23)
    }
}

/// Audio-Fixtures des Root-Pakets, bei Bedarf selbst erzeugt (idempotent).
private enum LayerFixture {
    static let directory: URL? = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TagExplosionAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // Repo-Wurzel
        let generated = repoRoot
            .appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated")
        let sample = generated.appendingPathComponent("sample.mp3")
        if !FileManager.default.fileExists(atPath: sample.path) {
            let script = repoRoot.appendingPathComponent(
                "Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        return FileManager.default.fileExists(atPath: sample.path) ? generated : nil
    }()

    static var isAvailable: Bool { directory != nil }

    enum FixtureError: Error { case notGenerated }

    static func workingCopy() throws -> URL {
        guard let directory else { throw FixtureError.notGenerated }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-layers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("sample.mp3")
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("sample.mp3"), to: target)
        return target
    }
}
