import AppKit
import SwiftUI
import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Editoransichten", .serialized)
@MainActor
struct EditorRenderingTests {
    private func entry(_ ext: String, readOnly: Bool = false) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/tmp/test.\(ext)"), loaded: .audio(TagData(
            properties: [TagProperty(key: "TITLE", value: "Review-Test")], artworks: [], audio: nil,
            isReadOnly: readOnly, supportsSyncedLyrics: ext == "mp3")))
    }

    @Test("Batchfähigkeiten gelten für sämtliche ausgewählten Dateien")
    func capabilities() {
        let mp3 = entry("mp3"), module = entry("mod"), matroska = entry("mka")
        let trackerBatch = BatchEditorView(entries: [mp3, module])
        #expect(!trackerBatch.canEditCovers)
        #expect(!trackerBatch.canEdit("TRACKNUMBER"))
        #expect(trackerBatch.canEdit("TITLE"))
        #expect(!BatchEditorView(entries: [mp3, matroska]).canEditCovers)
        #expect(!BatchEditorView(entries: [mp3, entry("avi", readOnly: true)]).canEdit("ARTIST"))
    }

    @Test("Betroffene Ansichten rendern in einem Hintergrundfenster",
          .enabled(if: ProcessInfo.processInfo.environment["TAGX_REVIEW_SNAPSHOT_DIR"] != nil))
    func renderViews() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TAGX_REVIEW_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let audio = entry("mp3")
        audio.fixedFieldDrafts[FixedFields.replayGainTrackGain] = "ungültig"
        audio.lyricsLanguageDraft = "DEU"
        let model = AppModel()
        let views: [(String, AnyView)] = [
            ("fixed-fields", AnyView(VStack(spacing: 20) { LyricsSection(entry: audio); LoudnessSection(entry: audio) }.padding(20).background(.background).environment(model))),
            ("batch-tracker", AnyView(BatchEditorView(entries: [audio, entry("mod")]).environment(model))),
            ("batch-readonly", AnyView(BatchEditorView(entries: [audio, entry("avi", readOnly: true)]).environment(model))),
            ("lookup-tracker", AnyView(OnlineLookupSheet(entries: [audio, entry("mod")]).background(.background).environment(model))),
        ]
        for (name, content) in views {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.close() }
            let hosting = NSHostingView(rootView: content)
            window.contentView = hosting
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(500))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
            #expect(hosting.bounds.width == 1000)
        }
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
    }
}
