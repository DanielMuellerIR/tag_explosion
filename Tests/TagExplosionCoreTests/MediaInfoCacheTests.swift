import Foundation
import TagExplosionTestSupport
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TagExplosionCore

@Suite("MediaInfo Bedarf, Cache und Abbruch")
struct MediaInfoCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Werkzeuge erben keine fremden offenen Dateien")
    func closesUnrelatedDescriptors() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("open-writer")
        let original = open(file.path, O_CREAT | O_WRONLY, 0o600)
        #expect(original >= 0)
        guard original >= 0 else { return }
        defer { close(original) }
        // Eine hohe Nummer vermeidet zufällige Wiederverwendung durch die Shell.
        // F_DUPFD setzt bewusst kein CLOEXEC: Der Starter muss selbst aufräumen.
        let descriptor = fcntl(original, F_DUPFD, 100)
        #expect(descriptor >= 100)
        guard descriptor >= 100 else { return }
        defer { close(descriptor) }
        _ = try ExternalToolRunner.run("/bin/sh", ["-c",
            "if [ -e /dev/fd/\"$1\" ]; then exit 23; fi", "test", String(descriptor)])
    }

    @Test("Fake-Werkzeug zählt JSON/Text, gemeinsame Anfrage, Invalidierung und Cache-Grenze")
    func demandAndCache() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("mediainfo")
        try Data("""
        #!/bin/sh
        printf 'x\\n' >> "$0.calls"
        printf diagnostic >&2 || exit 23
        if [ "$1" = "--Output=JSON" ]; then
          printf '%s' '{"media":{"track":[{"@type":"General","Title":"Test"}]}}'
        else
          printf '%s\\n' 'Title: Test'
        fi
        """.utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let file = dir.appendingPathComponent("a.flac")
        try Data("a".utf8).write(to: file)
        func calls() throws -> Int {
            try String(contentsOf: dir.appendingPathComponent("mediainfo.calls"), encoding: .utf8).split(separator: "\n").count
        }
        let full = try MediaInfoReader.read(url: file, output: .both, executable: exe.path)
        #expect(try calls() == 2)
        let text = try MediaInfoReader.read(url: file, output: .text, executable: exe.path)
        #expect(text.text == full.text)
        #expect(try calls() == 3)
        let json = try MediaInfoReader.read(url: file, output: .json, executable: exe.path)
        #expect(json.tracks == full.tracks)
        #expect(try calls() == 4)
        let cache = MediaInfoCache(capacity: 1) { url, output, cancellation in
            try MediaInfoReader.read(url: url, output: output, executable: exe.path, cancellation: cancellation)
        }
        // Gleichzeitigkeit prüft subscriberCancellation mit einem Gate. Hier
        // zählen Werkzeugaufrufe unabhängig davon, welcher Task zuerst startet.
        async let first = cache.read(url: file)
        async let second = cache.read(url: file)
        let reports = try await [first, second]
        #expect(reports == [full, full])
        #expect(try calls() == 6)
        #expect(try await cache.read(url: file) == full)
        #expect(try calls() == 6)
        try Data("changed".utf8).write(to: file)
        _ = try await cache.read(url: file)
        #expect(try calls() == 8)
        let other = dir.appendingPathComponent("b.flac")
        try Data("b".utf8).write(to: other)
        _ = try await cache.read(url: other)
        _ = try await cache.read(url: file)
        #expect(try calls() == 12)

        // Der echte CLI-Einstieg nutzt den Fake über PATH und genau einen Prozess.
        for (json, closed) in [(false, ""), (true, ""), (true, "exec 2>&-;"), (true, "exec 0<&-;")] {
            let count = try calls()
            let result = try runCapturedProcess(executable: "/bin/sh",
                arguments: ["-c", closed + " exec \"$@\"", "test", try TagxTestProcess.binaryURL().path,
                    "info", file.path] + (json ? ["--json"] : []),
                currentDirectory: TagxTestProcess.repoRoot,
                environment: ["PATH": dir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")])
            let output = Data(result.stdout.utf8)
            #expect(result.status == 0)
            #expect(try calls() == count + 1)
            if json { #expect(try JSONDecoder().decode([MediaInfoTrack].self, from: output) == full.tracks) }
            else { #expect(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == full.text) }
        }
    }

    @Test("Ein Abonnent bricht ab, der andere erhält denselben Auftrag; A–B–A bleibt korrekt")
    func subscriberCancellation() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.flac")
        let b = dir.appendingPathComponent("b.flac")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let gate = DispatchSemaphore(value: 0)
        // Diese Frist verhindert nur einen hängenden Test. Unter paralleler
        // CI-Last kann schon die Fortsetzung des Test-Tasks mehrere Sekunden
        // warten; der Leser darf deshalb nicht nach fünf Sekunden fertig sein.
        let cache = MediaInfoCache { url, _, cancellation in
            guard gate.wait(timeout: .now() + 60) == .success else { throw CocoaError(.fileReadUnknown) }
            try cancellation.check()
            return MediaInfoReport(tracks: [], text: url.lastPathComponent)
        }
        let first = Task { try await cache.read(url: a) }
        let second = Task { try await cache.read(url: a) }
        defer {
            first.cancel()
            second.cancel()
            gate.signal()
        }
        for _ in 0..<2000 {
            if await cache.subscriberCount == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await cache.subscriberCount == 2)
        first.cancel()
        // Ohne Freigabe des gemeinsamen Lesers muss der einzelne Abonnent enden.
        do { _ = try await first.value; Issue.record("Abgebrochener Abonnent bekam Erfolg") }
        catch is CancellationError {}
        #expect(await cache.subscriberCount == 1)
        gate.signal() // Genau ein Leser für beide Abonnenten.
        #expect(try await second.value.text == "a.flac")
        gate.signal()
        #expect(try await cache.read(url: b).text == "b.flac")
        // Kein weiteres Gate-Signal: A muss aus dem Cache kommen.
        #expect(try await cache.read(url: a).text == "a.flac")
    }

    @Test("Abbruch beendet Kindprozesse mit offenen und geschlossenen Ausgabepipes",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationWithChild(closingPipes: Bool) async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("child.py")
        let ready = dir.appendingPathComponent("ready")
        try Data("""
        import os, signal, time, sys
        if os.fork() == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            if \(closingPipes ? "True" : "False"):
                os.close(1)
                os.close(2)
            with open(sys.argv[1], 'w') as f: f.write(str(os.getpid()))
        while True: time.sleep(1)
        """.utf8).write(to: script)
        let cancellation = ExternalToolRunner.Cancellation()
        defer { cancellation.cancel() }
        let task = Task {
            try await BlockingWork.run { try ExternalToolRunner.run("/usr/bin/python3", [script.path, ready.path], processTimeout: 60, cancellation: cancellation) }
        }
        let pid = try await waitForPID(at: ready)
        let start = Date()
        cancellation.cancel()
        do { _ = try await task.value; Issue.record("Abbruch blieb wirkungslos") }
        catch is CancellationError {}
        // Der Hilfsprozess wartet auf den Abbruch. Eine feste natürliche
        // Laufzeit kann schon vor dem Fortsetzen dieser Test-Task verstreichen.
        // Das unabhängige Prozesslimit verhindert hängende Testprozesse.
        #expect(Date().timeIntervalSince(start) < 10)
        // Nach dem Gruppen-Kill kann der System-Reaper einen kurzen Moment brauchen.
        for _ in 0..<500 {
            if kill(pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(kill(pid, 0) == -1)
    }

    @Test("Abbruch beendet auch ein Werkzeug, das SIGTERM ignoriert")
    func cancellationKillsIgnoringTool() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("ignore.py")
        let ready = dir.appendingPathComponent("ready")
        try Data("""
        import signal, time, sys, os
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(sys.argv[1], 'w') as f: f.write(str(os.getpid()))
        while True: time.sleep(0.1)
        """.utf8).write(to: script)
        let cancellation = ExternalToolRunner.Cancellation()
        defer { cancellation.cancel() }
        let task = Task {
            try await BlockingWork.run { try ExternalToolRunner.run("/usr/bin/python3", [script.path, ready.path], processTimeout: 5, cancellation: cancellation) }
        }
        let pid = try await waitForPID(at: ready)
        cancellation.cancel()
        do { _ = try await task.value; Issue.record("Abbruch blieb wirkungslos") }
        catch is CancellationError {}
        catch { Issue.record("Falscher Fehler: \(error)") }
        // Der Hilfsprozess läuft unbegrenzt. Seine PID muss nach dem Abbruch
        // verschwunden sein; eine knappe Scheduler-Frist beweist das nicht.
        #expect(kill(pid, 0) == -1)
        // Ein vor dem Start abgebrochener Auftrag darf keinen Prozess erzeugen.
        do {
            _ = try ExternalToolRunner.run("/usr/bin/false", [], cancellation: cancellation)
            Issue.record("Prozess trotz Abbruch gestartet")
        } catch is CancellationError {}
    }

    /// Erst abbrechen, wenn Signalbehandlung und Ausgabe der PID abgeschlossen sind.
    private func waitForPID(at url: URL) async throws -> Int32 {
        for _ in 0..<2000 {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try #require(Int32(text))
    }

}
