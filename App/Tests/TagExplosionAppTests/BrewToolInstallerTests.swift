// Prüft die Entscheidungslogik des Startangebots und den Homebrew-Aufruf mit
// einem Fake-brew-Skript — inklusive Regressionstest gegen den Pipe-Deadlock
// bei großer Fehlerausgabe.
import Foundation
import Testing
@testable import TagExplosionApp

@Suite("BrewToolInstaller")
struct BrewToolInstallerTests {
    /// Eigenes Temp-Verzeichnis je Testlauf; Aufräumen übernimmt der Aufrufer
    /// am Ende jedes Tests über `defer`.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrewToolInstallerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Legt ein ausführbares Shell-Skript an, das in Tests `brew` vertritt.
    private func makeExecutable(in directory: URL, named name: String, script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("resolveHomebrew nimmt den ersten ausführbaren Kandidaten")
    func resolveHomebrewPrefersFirstExecutableCandidate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing/brew")
        let plainFile = directory.appendingPathComponent("plain-brew")
        try Data("nicht ausführbar".utf8).write(to: plainFile)
        let executable = try makeExecutable(in: directory, named: "brew", script: "#!/bin/sh\nexit 0\n")

        #expect(BrewToolInstaller.resolveHomebrew(candidates: [missing, plainFile, executable]) == executable)
        #expect(BrewToolInstaller.resolveHomebrew(candidates: [missing, plainFile]) == nil)
    }

    @Test("Angebot nur solange Werkzeuge fehlen und nicht abgelehnt wurde")
    func offerOnlyAppearsWhileToolsAreMissingAndNotDeclined() {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

        #expect(BrewToolInstaller.offer(
            missingTools: [], installDeclined: false, brewExecutable: brew
        ) == nil)
        #expect(BrewToolInstaller.offer(
            missingTools: ["mediainfo"], installDeclined: true, brewExecutable: brew
        ) == nil)
        #expect(BrewToolInstaller.offer(
            missingTools: ["mediainfo", "exiftool"], installDeclined: false, brewExecutable: brew
        ) == .homebrewInstall(brewExecutable: brew, missingTools: ["mediainfo", "exiftool"]))
        #expect(BrewToolInstaller.offer(
            missingTools: ["exiftool"], installDeclined: false, brewExecutable: nil
        ) == .manualGuidance(missingTools: ["exiftool"]))
    }

    @Test("install ruft brew install mit den Formeln auf und übersteht große Fehlerausgabe")
    func installRunsBrewAndSurvivesLargeErrorOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordURL = directory.appendingPathComponent("arguments.txt")
        // 200.000 Zeichen auf stderr sind ein Mehrfaches des Pipe-Puffers
        // (64 KiB): Ohne das Leeren der Pipe vor `waitUntilExit()` bliebe
        // dieser Test für immer hängen.
        let brew = try makeExecutable(in: directory, named: "brew", script: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(recordURL.path)'
        head -c 200000 /dev/zero | tr '\\0' 'x' >&2
        exit 0
        """)

        try BrewToolInstaller.install(brewExecutable: brew, formulae: ["mediainfo", "exiftool"]) { true }

        #expect(try String(contentsOf: recordURL, encoding: .utf8) == "install\nmediainfo\nexiftool\n")
    }

    @Test("install reicht die brew-Fehlerausgabe durch")
    func installReportsBrewErrorOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let brew = try makeExecutable(in: directory, named: "brew", script: """
        #!/bin/sh
        echo 'Error: mediainfo bottle unavailable' >&2
        exit 1
        """)

        #expect {
            try BrewToolInstaller.install(brewExecutable: brew, formulae: ["mediainfo"]) { true }
        } throws: { error in
            error.localizedDescription.contains("Error: mediainfo bottle unavailable")
        }
    }

    @Test("install scheitert ehrlich, wenn die Werkzeuge danach weiter fehlen")
    func installFailsWhenToolsRemainUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let brew = try makeExecutable(in: directory, named: "brew", script: "#!/bin/sh\nexit 0\n")

        #expect {
            try BrewToolInstaller.install(brewExecutable: brew, formulae: ["exiftool"]) { false }
        } throws: { error in
            (error as? BrewToolInstaller.InstallError) == .verificationFailed
        }
    }
}
