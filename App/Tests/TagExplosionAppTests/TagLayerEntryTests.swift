// Tag-Schichten im Editor-Modell: Schichten nur bei Audio, Entfernen nur auf
// sauberer Datei, echter Strip auf einer Fixture-Kopie mit Neuladen — und
// die Einstellung „ID3v2.3 schreiben" mit Voreinstellung aus. Headless.
import Foundation
import TagExplosionTestSupport
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
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixtures fehlen (ffmpeg)"))
    func stripReloadsEntry() async throws {
        let url = try MediaTestFixtures.workingCopy()
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
