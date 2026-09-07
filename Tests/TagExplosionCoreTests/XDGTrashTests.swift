// Papierkorb nach freedesktop-Konvention (Linux-Weg der Sicherung). Die
// Tests laufen auf jeder Plattform: `XDGTrash` bekommt ein Temp-Verzeichnis
// als Datenverzeichnis und fasst den echten Papierkorb des Rechners nie an.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("XDG-Papierkorb", .serialized)
struct XDGTrashTests {

    /// Temp-Wurzel mit Datenverzeichnis und einem „Musik"-Ordner darin;
    /// wird am Ende komplett entfernt.
    private func withSandbox(_ body: (URL, XDGTrash) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-xdg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataHome = root.appendingPathComponent("share", isDirectory: true)
        try body(root, XDGTrash(dataHome: dataHome))
    }

    @Test("Home-Papierkorb: Ordner unter files/, Herkunft und Zeit in info/")
    func homeTrashLayout() throws {
        try withSandbox { root, trash in
            let music = root.appendingPathComponent("Musik Ärger", isDirectory: true)
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)

            let folder = try trash.createTrashedFolder(named: "Tag Explosion Backup 2026-09-03 10-00-00",
                                                       originalParent: music)

            let files = trash.homeTrash.appendingPathComponent("files", isDirectory: true)
            #expect(folder.deletingLastPathComponent().standardizedFileURL == files.standardizedFileURL)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)

            let info = trash.homeTrash.appendingPathComponent("info")
                .appendingPathComponent("Tag Explosion Backup 2026-09-03 10-00-00.trashinfo")
            let lines = try String(contentsOf: info, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            #expect(lines.count == 3)
            #expect(lines[0] == "[Trash Info]")
            // Absoluter Pfad, Leerzeichen und Umlaut prozent-kodiert, „/" bleibt.
            let expectedPath = XDGTrash.percentEncoded(
                music.standardizedFileURL.path + "/Tag Explosion Backup 2026-09-03 10-00-00")
            #expect(lines[1] == "Path=\(expectedPath)")
            #expect(expectedPath.contains("%20"))
            // macOS legt Umlaute zerlegt ab (A + Trema → %CC%88), Linux
            // zusammengesetzt (%C3%84); roh bleiben darf er nirgends.
            #expect(expectedPath.contains("%C3%84") || expectedPath.contains("%CC%88"))
            #expect(!expectedPath.contains(" ") && !expectedPath.contains("Ä"))
            #expect(lines[2].wholeMatch(of: /DeletionDate=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/) != nil)
        }
    }

    @Test("Ein belegter Name bekommt eine laufende Nummer")
    func nameCollisionGetsCounter() throws {
        try withSandbox { root, trash in
            let first = try trash.createTrashedFolder(named: "Sicherung", originalParent: root)
            let second = try trash.createTrashedFolder(named: "Sicherung", originalParent: root)
            #expect(first.lastPathComponent == "Sicherung")
            #expect(second.lastPathComponent == "Sicherung (2)")
            let info = trash.homeTrash.appendingPathComponent("info")
            #expect(FileManager.default.fileExists(atPath: info.appendingPathComponent("Sicherung.trashinfo").path))
            #expect(FileManager.default.fileExists(atPath: info.appendingPathComponent("Sicherung (2).trashinfo").path))
        }
    }

    @Test("XDG-Datenpfade müssen absolut sein")
    func configuredDataHome() {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
        for environment in [[:], ["XDG_DATA_HOME": ""], ["XDG_DATA_HOME": "share"]] {
            #expect(XDGTrash.defaultDataHome(environment: environment) == fallback)
        }
        #expect(XDGTrash.defaultDataHome(environment: ["XDG_DATA_HOME": "/tmp/tagx-share"])
            == URL(fileURLWithPath: "/tmp/tagx-share", isDirectory: true))
    }

    @Test("Die Sicherung läuft über den XDG-Papierkorb, wenn er gesetzt ist")
    func trashBackupUsesXDGTrash() throws {
        try withSandbox { _, trash in
            let backup = TrashBackup(xdgTrash: trash)
            backup.isEnabled = true
            backup.folderLabel = "Tag Explosion Testsicherung"

            let url = try Fixtures.workingCopy("sample.mp3")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let before = try Data(contentsOf: url)
            try backup.backUp(url)
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Neu")], to: url)

            let folder = try #require(backup.currentFolders.first)
            let files = trash.homeTrash.appendingPathComponent("files", isDirectory: true)
            #expect(folder.path.hasPrefix(files.standardizedFileURL.path))
            let copy = folder.appendingPathComponent(
                url.deletingLastPathComponent().lastPathComponent)
                .appendingPathComponent("sample.mp3")
            #expect(try Data(contentsOf: copy) == before)
            #expect(try Data(contentsOf: url) != before)

            let info = trash.homeTrash.appendingPathComponent("info")
                .appendingPathComponent("\(folder.lastPathComponent).trashinfo")
            #expect(FileManager.default.fileExists(atPath: info.path))
        }
    }

    @Test("Einhängepunkt: die Wurzel ist ihr eigener, ein Pfad liegt unter seinem")
    func mountPointIsAncestor() throws {
        #expect(XDGTrash.mountPoint(of: URL(fileURLWithPath: "/")).path == "/")
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL
        let mount = XDGTrash.mountPoint(of: temp)
        #expect(temp.path.hasPrefix(mount.path))
        #expect(FileManager.default.fileExists(atPath: mount.path))
    }

    @Test("Fremder Datenträger: eigener Papierkorb `.Trash-<uid>` im Einhängepunkt, Pfad relativ",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func volumeTrashIsCreatedOnTheVolume() throws {
        let volume = try TestVolume(megabytes: 20)
        defer { volume.detach() }
        try withSandbox { _, trash in
            let album = volume.mountPoint.appendingPathComponent("Album", isDirectory: true)
            try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)

            let location = try trash.location(for: album)
            #expect(location.topDirectory?.standardizedFileURL == volume.mountPoint.standardizedFileURL)
            #expect(location.trashDirectory.lastPathComponent == ".Trash-\(trash.uid)")

            let folder = try trash.createTrashedFolder(named: "Sicherung", originalParent: album)
            #expect(folder.path.hasPrefix(volume.mountPoint.path))
            let info = location.trashDirectory.appendingPathComponent("info/Sicherung.trashinfo")
            let content = try String(contentsOf: info, encoding: .utf8)
            #expect(content.contains("\nPath=Album/Sicherung\n"))
        }
    }

    @Test("Vorhandenes `.Trash` mit Sticky-Bit wird per Benutzer-Unterordner genutzt",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func sharedTrashWithStickyBitIsPreferred() throws {
        let volume = try TestVolume(megabytes: 20)
        defer { volume.detach() }
        try withSandbox { _, trash in
            let shared = volume.mountPoint.appendingPathComponent(".Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o1777])
            let album = volume.mountPoint.appendingPathComponent("Album", isDirectory: true)
            try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)

            let location = try trash.location(for: album)
            #expect(location.trashDirectory.standardizedFileURL
                    == shared.appendingPathComponent(String(trash.uid), isDirectory: true).standardizedFileURL)
        }
    }

    @Test("Persönliche Papierkorb-Verzeichnisse dürfen keine Verknüpfungen sein",
          arguments: ["", "files", "info"])
    func rejectsLinkedTrashDirectories(component: String) throws {
        try withSandbox { root, trash in
            let foreign = root.appendingPathComponent("anderes-ziel", isDirectory: true)
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            let linked = component.isEmpty ? trash.homeTrash
                : trash.homeTrash.appendingPathComponent(component, isDirectory: true)
            try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: foreign)

            #expect(throws: TagError.self) {
                try trash.createTrashedFolder(named: "Sicherung", originalParent: root)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == foreign.path)
        }
    }

    @Test("Fremd beschreibbare Papierkorb-Verzeichnisse werden nicht übernommen",
          arguments: ["", "files", "info"])
    func rejectsWritableTrashDirectories(component: String) throws {
        try withSandbox { root, trash in
            _ = try trash.location(for: root)
            let directory = component.isEmpty ? trash.homeTrash
                : trash.homeTrash.appendingPathComponent(component, isDirectory: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
            #expect(throws: TagError.self) {
                try trash.createTrashedFolder(named: "Sicherung", originalParent: root)
            }
            #expect(!FileManager.default.fileExists(atPath:
                trash.homeTrash.appendingPathComponent("info/Sicherung.trashinfo").path))
        }
    }

    @Test("Ein verknüpftes Datenverzeichnis wird nach seinem Zieldatenträger zugeordnet",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func linkedDataHomeUsesTargetDevice() throws {
        let volume = try TestVolume(megabytes: 20)
        defer { volume.detach() }
        try withSandbox { root, _ in
            let realHome = volume.mountPoint.appendingPathComponent("share", isDirectory: true)
            try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
            let linkedHome = root.appendingPathComponent("share-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
            let trash = XDGTrash(dataHome: linkedHome)
            let location = try trash.location(for: volume.mountPoint)
            #expect(location.topDirectory == nil)
            #expect(location.trashDirectory == trash.homeTrash)
        }
    }
}

@Suite("Portable SHA-256")
struct PortableSHA256Tests {

    private func hex(_ text: String) -> String {
        var hasher = PortableSHA256()
        hasher.update(data: Data(text.utf8))
        return hasher.finalizeHex()
    }

    @Test("Bekannte Vektoren: leer, abc, 56 Zeichen (Blockgrenze), hallo")
    func knownVectors() {
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(hex("hallo") == "d3751d33f9cd5049c4af2b462735457e4d3baf130bcbb87f389e349fbaeb20b9")
    }

    @Test("Stückweise Eingabe über Blockgrenzen ergibt denselben Hash")
    func chunkedUpdateMatches() {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        var whole = PortableSHA256()
        whole.update(data: payload)
        var pieces = PortableSHA256()
        for start in stride(from: 0, to: payload.count, by: 37) {
            pieces.update(data: payload[start..<min(start + 37, payload.count)])
        }
        #expect(whole.finalizeHex() == pieces.finalizeHex())
        // Dasselbe Ergebnis wie der Journal-Weg (CryptoKit unter macOS).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-sha-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try? payload.write(to: url)
        var again = PortableSHA256()
        again.update(data: payload)
        #expect((try? BackupJournal.sha256(of: url)) == again.finalizeHex())
    }
}
