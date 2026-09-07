import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Historien-Konflikte")
@MainActor
struct VersionHistoryTests {
    @Test("Restore schützt fremd geänderte und neu angelegte Sidecars",
          arguments: ["lrc", "nfo", "xmp"], [false, true])
    func protectsSidecarReadState(kind: String, existed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media.\(kind == "xmp" ? "jpg" : "mp4")")
        let sidecar = root.appendingPathComponent("media.\(kind)")
        let copy = root.appendingPathComponent("backup.\(kind)")
        try Data("Medieninhalt".utf8).write(to: media)
        let saved = Data("Historischer Stand".utf8)
        try saved.write(to: copy)
        if existed { try Data("Beim Öffnen".utf8).write(to: sidecar) }
        let state = SidecarState.current(of: sidecar)
        let loaded: LoadedData
        switch kind {
        case "xmp":
            loaded = .image(ImageCoreReading(fields: ImageCoreFields(), sidecarURL: sidecar, sidecar: state))
        case "nfo":
            let nfo = existed ? NFOSidecarReading(url: sidecar,
                contents: NFOContents(rootName: "movie", fields: NFOFields(), info: [], urls: []),
                stamp: FileStamp.current(of: sidecar)) : nil
            loaded = .audio(TagData(properties: [], artworks: [], audio: nil), sidecars: AudioSidecars(nfo: nfo))
        default:
            loaded = .audio(TagData(properties: [], artworks: [], audio: nil), sidecars: AudioSidecars(lrcState: state))
        }
        let entry = FileEntry(url: media, loaded: loaded)
        let foreign = Data("Fremde Fassung nach dem Öffnen".utf8)
        try foreign.write(to: sidecar)
        let version = BackupVersion(number: 1, entry: BackupJournalEntry(
            originalPath: sidecar.path, backupPath: copy.path, date: Date(),
            size: Int64(saved.count), sha256: nil, reason: BackupReason.sidecar))
        let model = AppModel()
        #expect(await model.restoreVersion(version, for: entry, backup: TrashBackup()) == false)
        #expect(try Data(contentsOf: sidecar) == foreign)
        #expect(try Data(contentsOf: media) == Data("Medieninhalt".utf8))
        #expect(!entry.isSaving)
        #expect(entry.lastError?.contains("changed on disk") == true)
    }
}
