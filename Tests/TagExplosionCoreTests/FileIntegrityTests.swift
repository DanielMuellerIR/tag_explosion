// Unversehrtheit der bearbeiteten Dateien — der Kern des abgesicherten Modus.
//
// Diese Tests prüfen nicht, ob ein Tag richtig ankommt (das machen die
// Roundtrip-Tests), sondern ob die Datei einen Schreibvorgang unbeschadet
// übersteht: Nutzdaten unverändert, Original bytegleich bei jedem Fehler,
// keine halb geschriebenen Zustände. Sie ersetzen das, was sonst nur
// menschliches Ausprobieren finden würde.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("Unversehrtheit", .serialized)
struct FileIntegrityTests {

    // MARK: - Nutzdaten

    /// Prüfsumme des reinen Audiostreams (ohne Tags/Container-Metadaten).
    /// Ohne ffmpeg wird der Test übersprungen.
    static func audioStreamChecksum(of url: URL) -> String? {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-i", url.path, "-map", "0:a",
                             "-f", "md5", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let ffmpegAvailable = audioStreamChecksum(
        of: Fixtures.directory.appendingPathComponent("sample.mp3")) != nil

    @Test("Tag-Schreiben lässt den Audiostream unverändert",
          .enabled(if: Self.ffmpegAvailable, "ffmpeg fehlt"),
          arguments: ["sample.mp3", "sample.m4a", "sample.flac", "sample.ogg", "sample.wav"])
    func audioPayloadSurvivesTagWrite(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let before = try #require(Self.audioStreamChecksum(of: url))

        try TagFile.write(properties: [
            TagProperty(key: "ARTIST", value: "Nach dem Schreiben gleich"),
            TagProperty(key: "TITLE", value: "Ümläute und 🎧"),
        ], artworks: [Artwork(data: try Fixtures.coverData("cover.jpg"),
                              pictureType: "Front Cover")], to: url)

        // Genau das ist der Kern: Die Tags ändern sich, die Musik nicht.
        #expect(Self.audioStreamChecksum(of: url) == before)
        #expect(try TagFile.read(at: url).firstValue(for: "ARTIST") == "Nach dem Schreiben gleich")
    }

    // MARK: - Fehler während des Schreibens

    @Test("Abbruch in der Prüfung lässt das Original bytegleich",
          arguments: ["sample.mp3", "sample.flac", "sample.m4a"])
    func failedValidationKeepsOriginal(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let before = try Data(contentsOf: url)

        #expect(throws: TagError.self) {
            try AtomicFileRewrite.run(url: url) { temp in
                // Vollständig gültiger Schreibvorgang auf der Kopie …
                try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "X")], to: temp)
            } validate: { _ in
                // … der erst in der Prüfung scheitert.
                throw TagError.saveFailed(path: url.path)
            }
        }

        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Schreibgeschützte Datei wird nicht angefasst")
    func readOnlyFileIsRejected() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: url.path)
        }

        #expect(throws: TagError.self) {
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "X")], to: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Schreibgeschützter Ordner bricht vor jeder Änderung ab")
    func readOnlyDirectoryIsRejected() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        let directory = url.deletingLastPathComponent()
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
        }

        // Die Geschwisterkopie kann nicht entstehen — also wird gar nicht erst
        // geschrieben.
        #expect(throws: TagError.self) {
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "X")], to: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Voller Datenträger bricht ab, statt die Datei zu beschädigen",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func fullVolumeIsRejected() throws {
        let volume = try TestVolume(megabytes: 12)
        defer { volume.detach() }

        let url = volume.mountPoint.appendingPathComponent("sample.mp3")
        try FileManager.default.copyItem(
            at: Fixtures.directory.appendingPathComponent("sample.mp3"), to: url)
        let before = try Data(contentsOf: url)
        try volume.fillRemainingSpace()

        #expect(throws: TagError.self) {
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "X")], to: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: - Kaputte und feindselige Eingaben

    @Test("Unbrauchbare Dateien werfen einen Fehler, statt zu beschädigen",
          arguments: ["leer", "abgeschnitten", "zufall", "falsche-endung"])
    func brokenInputsFailCleanly(variant: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-broken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("kaputt.mp3")

        let source = try Data(contentsOf: Fixtures.directory.appendingPathComponent("sample.mp3"))
        let content: Data
        switch variant {
        case "leer": content = Data()
        case "abgeschnitten": content = source.prefix(source.count / 3)
        case "zufall": content = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        default: content = try Data(contentsOf: Fixtures.directory
            .appendingPathComponent("cover.png")) // PNG mit .mp3-Endung
        }
        try content.write(to: url)

        // Lesen darf scheitern, aber niemals abstürzen.
        _ = try? TagFile.read(at: url)

        // Beim Schreiben gilt entweder-oder: Entweder der Versuch scheitert und
        // die Datei bleibt bytegleich, oder er gelingt — dann muss das Ergebnis
        // auch wieder lesbar sein. Ein Zustand dazwischen wäre der Datenverlust,
        // den es zu verhindern gilt.
        do {
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "X")], to: url)
            #expect(throws: Never.self) { _ = try TagFile.read(at: url) }
        } catch {
            #expect(try Data(contentsOf: url) == content)
        }
    }

    @Test("Dateinamen mit führendem Bindestrich werden nicht als Option gelesen")
    func leadingDashFileNameIsSafe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-dash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("-delete_original.jpg")
        try FileManager.default.copyItem(
            at: Fixtures.directory.appendingPathComponent("cover.jpg"), to: url)

        // exiftool würde ein Argument mit führendem "-" als Option lesen. Der
        // Core übergibt deshalb immer den absoluten Pfad.
        #expect(MediaInfoReader.toolArgument(for: url).hasPrefix("/"))
        var fields = try ExifTool.readCoreFields(url: url)
        fields.title = "Bindestrich"
        try ExifTool.writeCoreFields(url: url, fields: fields,
                                     original: try ExifTool.readCoreFields(url: url))
        #expect(try ExifTool.readCoreFields(url: url).title == "Bindestrich")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Sonderzeichen im Pfad und in den Werten überstehen den Schreibweg")
    func unusualPathsAndValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-öäü 漢字 🎵-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stück nr. 1.mp3")
        try FileManager.default.copyItem(
            at: Fixtures.directory.appendingPathComponent("sample.mp3"), to: url)

        let value = String(repeating: "Straße 🎼 ", count: 200)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: value)], to: url)
        #expect(try TagFile.read(at: url).firstValue(for: "TITLE") == value)
    }

    // MARK: - Fremde Änderungen

    @Test("Eine von außen geänderte Datei wird erkannt")
    func externalChangeIsDetected() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        let stamp = try #require(FileStamp.current(of: url))
        try FileStamp.requireUnchanged(stamp, at: url) // unverändert: kein Fehler

        // Fremdes Programm schreibt dazwischen.
        try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Fremd")], to: url)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            try FileStamp.requireUnchanged(stamp, at: url)
        }
    }
}

/// Ein kleines, im Test erzeugtes Dateisystem — nur so lässt sich „Datenträger
/// voll" ohne Rateversuche prüfen.
struct TestVolume {
    let image: URL
    let mountPoint: URL

    static var isSupported: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
    }

    init(megabytes: Int) throws {
        image = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-volume-\(UUID().uuidString).dmg")
        let name = "TagxTest\(UUID().uuidString.prefix(8))"
        try TestVolume.run("/usr/bin/hdiutil",
                           ["create", "-quiet", "-size", "\(megabytes)m", "-fs", "HFS+",
                            "-volname", name, image.path])
        let output = try TestVolume.run("/usr/bin/hdiutil",
                                        ["attach", "-quiet", "-nobrowse", image.path])
        _ = output
        mountPoint = URL(fileURLWithPath: "/Volumes/\(name)")
        guard FileManager.default.fileExists(atPath: mountPoint.path) else {
            throw TagError.cannotOpen(path: mountPoint.path)
        }
    }

    /// Belegt den restlichen Platz, damit keine Kopie mehr entstehen kann.
    func fillRemainingSpace() throws {
        let filler = mountPoint.appendingPathComponent("filler.bin")
        let handle = FileManager.default.createFile(atPath: filler.path, contents: nil)
        guard handle, let file = FileHandle(forWritingAtPath: filler.path) else { return }
        defer { try? file.close() }
        let block = Data(repeating: 0, count: 256 * 1024)
        while true {
            do { try file.write(contentsOf: block) } catch { break }
        }
    }

    func detach() {
        _ = try? TestVolume.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: image)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TagError.toolFailed(name: executable, exitCode: process.terminationStatus,
                                      stderr: "")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
