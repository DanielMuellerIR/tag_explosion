// Tag-Schichten (ID3v1, ID3v2, APEv2, RIFF INFO, Vorbis): Anzeige je Format,
// gezieltes Entfernen einzelner Schichten mit unverändertem Audiostream,
// Fehlerfälle vor jeder Mutation und die ID3v2.3-Schreiboption (Umlaute,
// Emoji und Datum müssen den Weg über UTF-16 und TYER/TDAT überleben).
// Cross-Check mit kid3-cli, wo es installiert ist.
import Foundation
import Testing
@testable import TagExplosionCore

/// kid3-cli als unabhängiger Zeuge: liest jede Schicht getrennt („Tag 1" =
/// ID3v1, „Tag 2" = ID3v2/APE) und nennt die ID3v2-Version.
private enum Kid3 {
    static let path = "/Applications/kid3.app/Contents/MacOS/kid3-cli"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// Führt kid3-cli-Befehle auf einer Datei aus und liefert stdout.
    @discardableResult
    static func run(_ commands: [String], on url: URL) -> String? {
        guard isAvailable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = commands.flatMap { ["-c", $0] } + [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Tag-Schichten", .serialized)
struct TagLayerTests {

    private func layer(_ kind: TagLayerKind, of url: URL) throws -> TagLayer {
        try #require(try TagFile.read(at: url).layers.first { $0.kind == kind },
                     "\(url.lastPathComponent): Schicht \(kind) fehlt in der Liste")
    }

    // MARK: - Anzeige

    @Test("Frische MP3: nur ID3v2.4, ID3v1 und APE werden als fehlend gemeldet")
    func freshMP3ReportsAllThreeLayers() throws {
        let layers = try TagFile.read(at: Fixtures.directory.appendingPathComponent("sample.mp3")).layers
        #expect(layers.map(\.kind) == [.id3v1, .id3v2, .ape])
        let v2 = try #require(layers.first { $0.kind == .id3v2 })
        #expect(v2.present && v2.version == 4 && v2.displayName == "ID3v2.4")
        #expect(v2.fields.contains("ENCODING"))
        let v1 = try #require(layers.first { $0.kind == .id3v1 })
        #expect(!v1.present && v1.fields.isEmpty && v1.version == 0)
        #expect(layers.allSatisfy { $0.strippable })
    }

    @Test("Formate ohne Schichtenmodell liefern keine Schichten",
          arguments: ["sample.m4a", "sample.ogg", "sample.opus", "sample.mkv"])
    func formatsWithoutLayerModel(format: String) throws {
        #expect(try TagFile.read(at: Fixtures.directory.appendingPathComponent(format)).layers.isEmpty)
    }

    @Test("Nach dem Schreiben trägt eine MP3 ID3v1 und ID3v2 mit ihren Feldern")
    func writingMP3CreatesBothID3Layers() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Zwei Schichten"),
                                       TagProperty(key: "ARTIST", value: "Test")], to: url)
        let v1 = try layer(.id3v1, of: url)
        let v2 = try layer(.id3v2, of: url)
        #expect(v1.present && v1.version == 1 && v1.fields.contains("TITLE"))
        #expect(v2.present && v2.version == 4)
        #expect(Set(v2.fields).isSuperset(of: ["TITLE", "ARTIST"]))
    }

    @Test("WAV trägt ID3v2 und RIFF INFO, WavPack APEv2, FLAC Vorbis")
    func otherFormatsReportTheirLayers() throws {
        let wav = try Fixtures.workingCopy("sample.wav")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Wav")], to: wav)
        #expect(try TagFile.read(at: wav).layers.map(\.kind) == [.id3v2, .info])
        #expect(try layer(.id3v2, of: wav).present)
        #expect(try layer(.info, of: wav).present)
        #expect(try layer(.info, of: wav).displayName == "RIFF INFO")

        let wv = try Fixtures.workingCopy("sample.wv")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Wv")], to: wv)
        let ape = try layer(.ape, of: wv)
        #expect(ape.present && ape.version == 2 && ape.displayName == "APEv2")
        #expect(try layer(.id3v1, of: wv).present == false)

        let flac = Fixtures.directory.appendingPathComponent("sample.flac")
        #expect(try TagFile.read(at: flac).layers.map(\.kind) == [.vorbis, .id3v1, .id3v2])
        #expect(try layer(.vorbis, of: flac).present)
    }

    // MARK: - Strippen

    @Test("ID3v1 entfernen lässt ID3v2 und den Audiostream unverändert",
          .enabled(if: FileIntegrityTests.ffmpegAvailable, "ffmpeg fehlt"))
    func stripID3v1KeepsID3v2AndAudio() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Bleibt"),
                                       TagProperty(key: "ARTIST", value: "Ümläut")], to: url)
        let audioBefore = try #require(FileIntegrityTests.audioStreamChecksum(of: url))
        #expect(try layer(.id3v1, of: url).present)

        try TagFile.stripLayers([.id3v1], from: url)

        #expect(!(try layer(.id3v1, of: url).present))
        #expect(try layer(.id3v2, of: url).present)
        let after = try TagFile.read(at: url)
        #expect(after.firstValue(for: "TITLE") == "Bleibt")
        #expect(after.firstValue(for: "ARTIST") == "Ümläut")
        #expect(FileIntegrityTests.audioStreamChecksum(of: url) == audioBefore)

        if Kid3.isAvailable {
            // kid3 sieht Tag 1 (ID3v1) leer, Tag 2 (ID3v2) gefüllt.
            #expect(Kid3.run(["get title 1"], on: url) == "")
            #expect(Kid3.run(["get title 2"], on: url)?.trimmingCharacters(in: .newlines) == "Bleibt")
        }
    }

    @Test("Mehrere Schichten auf einmal: MP3 danach ohne Tags, Audio gleich",
          .enabled(if: FileIntegrityTests.ffmpegAvailable, "ffmpeg fehlt"))
    func stripAllID3Layers() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Weg")], to: url)
        let audioBefore = try #require(FileIntegrityTests.audioStreamChecksum(of: url))

        try TagFile.stripLayers([.id3v1, .id3v2], from: url)

        let after = try TagFile.read(at: url)
        #expect(after.layers.allSatisfy { !$0.present })
        #expect(after.properties.isEmpty)
        #expect(FileIntegrityTests.audioStreamChecksum(of: url) == audioBefore)
    }

    @Test("WAV: RIFF INFO und ID3v2 lassen sich getrennt entfernen")
    func stripWavLayersSeparately() throws {
        let url = try Fixtures.workingCopy("sample.wav")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Wav"),
                                       TagProperty(key: "ARTIST", value: "Ärger")], to: url)

        try TagFile.stripLayers([.info], from: url)
        #expect(!(try layer(.info, of: url).present))
        #expect(try layer(.id3v2, of: url).present)
        #expect(try TagFile.read(at: url).firstValue(for: "ARTIST") == "Ärger")

        // Ohne ID3v2 liest TagLib die Felder aus INFO — hier ist INFO schon
        // weg, also bleibt nichts übrig.
        try TagFile.stripLayers([.id3v2], from: url)
        #expect(!(try layer(.id3v2, of: url).present))
        #expect(try TagFile.read(at: url).properties.isEmpty)
    }

    @Test("WavPack: kid3-ID3v1 neben APEv2 wird erkannt und einzeln entfernt",
          .enabled(if: Kid3.isAvailable, "kid3-cli fehlt"))
    func stripID3v1FromWavPack() throws {
        let url = try Fixtures.workingCopy("sample.wv")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Ape-Titel")], to: url)
        // kid3 legt „Tag 1" = ID3v1 an; TagLib selbst erzeugt bei WavPack keins.
        try #require(Kid3.run(["set title Eins 1"], on: url) != nil)
        #expect(try layer(.id3v1, of: url).present)
        #expect(try layer(.ape, of: url).present)

        try TagFile.stripLayers([.id3v1], from: url)

        #expect(!(try layer(.id3v1, of: url).present))
        #expect(try layer(.ape, of: url).present)
        #expect(try TagFile.read(at: url).firstValue(for: "TITLE") == "Ape-Titel")
    }

    @Test("FLAC: Vorbis-Felder entfernen leert den Block, TagLib behält den Vendor-String",
          .enabled(if: FileIntegrityTests.ffmpegAvailable, "ffmpeg fehlt"))
    func stripVorbisFromFlac() throws {
        let url = try Fixtures.workingCopy("sample.flac")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Flac")], to: url)
        let audioBefore = try #require(FileIntegrityTests.audioStreamChecksum(of: url))

        try TagFile.stripLayers([.vorbis], from: url)

        let vorbis = try layer(.vorbis, of: url)
        #expect(vorbis.present, "Block bleibt als leere Hülle stehen")
        #expect(vorbis.fields.isEmpty)
        #expect(try TagFile.read(at: url).properties.isEmpty)
        #expect(FileIntegrityTests.audioStreamChecksum(of: url) == audioBefore)
    }

    @Test("AIFF: die einzige ID3v2-Schicht lässt sich entfernen (Chunk weg)")
    func stripID3v2FromAiff() throws {
        let url = try Fixtures.workingCopy("sample.aiff")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Aiff")], to: url)
        #expect(try layer(.id3v2, of: url).present)
        try TagFile.stripLayers([.id3v2], from: url)
        #expect(!(try layer(.id3v2, of: url).present))
        #expect(try TagFile.read(at: url).properties.isEmpty)
    }

    @Test("Fehlende oder unbekannte Schicht: Fehler vor jeder Änderung, Datei bytegleich")
    func stripRejectsMissingLayerBeforeTouchingTheFile() throws {
        let mp3 = try Fixtures.workingCopy("sample.mp3")
        let before = try Data(contentsOf: mp3)
        // ID3v1 fehlt in der frischen Fixture; INFO kennt MP3 gar nicht.
        #expect(throws: TagError.layerUnsupported(path: mp3.path, layer: "id3v1")) {
            try TagFile.stripLayers([.id3v1], from: mp3)
        }
        #expect(throws: TagError.layerUnsupported(path: mp3.path, layer: "info")) {
            try TagFile.stripLayers([.info], from: mp3)
        }
        #expect(try Data(contentsOf: mp3) == before)

        let m4a = try Fixtures.workingCopy("sample.m4a")
        #expect(throws: TagError.layerUnsupported(path: m4a.path, layer: "id3v2")) {
            try TagFile.stripLayers([.id3v2], from: m4a)
        }
    }

    // MARK: - ID3v2.3-Schreiboption

    @Test("ID3v2.3: Umlaute, Emoji und Datum überleben den Roundtrip",
          arguments: ["sample.mp3", "sample.wav", "sample.aiff"])
    func id3v23Roundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let written = [
            TagProperty(key: "TITLE", value: "Übermut Ä 🎧"),
            TagProperty(key: "ARTIST", value: "Größenwahn"),
            TagProperty(key: "DATE", value: "2024-03-15"),
        ]
        try TagFile.write(properties: written, to: url, id3Version: .v23)

        let v2 = try layer(.id3v2, of: url)
        #expect(v2.present && v2.version == 3, "\(format): erwartet ID3v2.3")
        let readBack = try TagFile.read(at: url)
        for property in written {
            #expect(readBack.firstValue(for: property.key) == property.value,
                    "\(format): \(property.key)")
        }
        if Kid3.isAvailable {
            let report = try #require(Kid3.run(["get"], on: url))
            #expect(report.contains("ID3v2.3.0"), Comment(rawValue: report))
            #expect(report.contains("Übermut Ä 🎧"))
            #expect(report.contains("2024-03-15"))
        }

        // Ohne die Option schreibt der nächste Save wieder v2.4 — die Option
        // gilt je Schreibvorgang, nicht je Datei.
        try TagFile.write(properties: written + [TagProperty(key: "ALBUM", value: "A")], to: url)
        #expect(try layer(.id3v2, of: url).version == 4, Comment(rawValue: format))
    }

    @Test("ID3v2.3 kürzt Zeitangaben: Sekunden fallen weg, Originaldatum nur Jahr")
    func id3v23DateLimits() throws {
        // Dokumentierte Grenze, kein Fehler: v2.3 kennt TYER/TDAT/TIME (Minute
        // ist das Feinste) und TORY (nur Jahr) statt TDRC/TDOR.
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "DATE", value: "2024-03-15T10:20:30"),
                                       TagProperty(key: "ORIGINALDATE", value: "2001-05-06")],
                          to: url, id3Version: .v23)
        let readBack = try TagFile.read(at: url)
        #expect(readBack.firstValue(for: "DATE") == "2024-03-15 10:20")
        #expect(readBack.firstValue(for: "ORIGINALDATE") == "2001")
    }

    @Test("Formate ohne ID3v2 ignorieren die Versionsoption")
    func id3VersionIgnoredElsewhere() throws {
        let url = try Fixtures.workingCopy("sample.flac")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Flac v23")], to: url,
                          id3Version: .v23)
        #expect(try TagFile.read(at: url).firstValue(for: "TITLE") == "Flac v23")
        #expect(!(try layer(.id3v2, of: url).present))
    }
}
