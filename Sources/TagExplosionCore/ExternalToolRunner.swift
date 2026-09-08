// Gemeinsame Prozess- und Werkzeugmechanik für die Metadaten-Backends.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ExternalToolRunner {
    // Signale dürfen nicht hinter blockierenden IO-Arbeiten auf der globalen
    // Queue warten, sonst verzögert Last gerade den benötigten Abbruch.
    private static let signalQueue = DispatchQueue(label: "io.github.tagexplosion.process-signals", qos: .userInitiated)

    /// Interner Fehler für Tests, die einen bewusst kurzen Schutz gegen
    /// festhängende Hilfsprozesse einschalten. Die normalen Aufrufe verwenden
    /// keinen Timeout und behalten dadurch ihr bisheriges Verhalten.
    enum ProcessTimeoutError: Error, LocalizedError, Sendable, Equatable {
        case exceeded

        var errorDescription: String? {
            "External process exceeded its test timeout"
        }
    }

    /// Sammelt genau einen Pipe-Stream. Die zwei Instanzen pro Prozess werden
    /// auf getrennten festen Queue-Arbeiten gelesen, damit ein volles stderr
    /// niemals stdout (oder umgekehrt) blockieren kann.
    private final class PipeCollector: @unchecked Sendable {
        private let handle: FileHandle
        private var collected = Data()

        init(_ handle: FileHandle) {
            self.handle = handle
        }

        func readToEnd() {
            collected = handle.readDataToEndOfFile()
        }

        func data() -> Data { collected }
    }

    /// Ein Abbruchsignal gehört einem Leseauftrag, auch wenn er nacheinander
    /// mehrere Prozesse benötigt. Start und Abbruch sind unter demselben Lock.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var cancelled = false
        private var timedOut = false
        private var escalated = false

        public init() {}
        public func cancel() { stop(timeout: false) }
        fileprivate func stop(timeout: Bool) {
            lock.lock()
            if cancelled || (timeout && pid == nil) { lock.unlock(); return }
            cancelled = true
            timedOut = timedOut || timeout
            let running = pid
            if let running { _ = kill(-running, SIGTERM) }
            lock.unlock()
            // Nur nach einem Abbruch, kein Zeitlimit für große Mediendateien.
            ExternalToolRunner.signalQueue.asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard let running, pid == running else { return }
                _ = kill(-running, SIGKILL)
                escalated = true
            }
        }
        fileprivate func start(_ launch: () throws -> pid_t) throws -> pid_t {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            let child = try launch()
            pid = child
            return child
        }
        fileprivate func finish() {
            lock.lock()
            pid = nil
            lock.unlock()
        }
        fileprivate func reap(_ child: pid_t) throws -> Int32 {
            while true {
                lock.lock()
                // Auch ein Kind ohne offene Pipes muss den Gruppen-Kill bekommen.
                // Bis dahin reserviert der unreapte Leiter die Prozessgruppen-ID.
                if cancelled && !escalated {
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                var status: Int32 = 0
                let waited = waitpid(child, &status, WNOHANG)
                let failure = errno
                if waited == child {
                    pid = nil // Reaping und PID-Freigabe atomar gegenüber dem Gruppen-Kill.
                    lock.unlock()
                    return status
                }
                lock.unlock()
                if waited == -1 && failure != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        public func check() throws {
            lock.lock()
            defer { lock.unlock() }
            if timedOut { throw ProcessTimeoutError.exceeded }
            if cancelled { throw CancellationError() }
        }
    }

    /// Dateipfad in der Form, in der externe Programme ihn bekommen dürfen.
    ///
    /// Immer absolut: mediainfo, exiftool und `ebook-meta` lesen jedes Argument
    /// mit führendem Bindestrich als Option. Ein absoluter Pfad beginnt immer
    /// mit „/" und kann deshalb nie als Option missverstanden werden — auch
    /// nicht bei einer Datei namens „-etwas.jpg".
    public static func toolArgument(for url: URL) -> String {
        let path = MediaFormats.canonicalFileURL(url).path
        guard path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return path
    }

    /// Externes Programm ausführen, stdout zurückgeben. Der optionale Timeout
    /// ist nur für Regressionstests gedacht; Produktivaufrufe übergeben nil.
    /// Umgebung für den Werkzeugaufruf mit garantierter UTF-8-Locale.
    /// mediainfo richtet seine Textausgabe nach `LC_ALL`/`LC_CTYPE`/`LANG`;
    /// ohne UTF-8-Locale (Docker-Container, CI-Job, `LANG=C`) ersetzt es
    /// jeden Umlaut durch „?" — noch vor dem JSON, das heißt unrettbar. Ist
    /// keine UTF-8-Locale gesetzt, geben wir `C.UTF-8` mit (Linux-Glibc und
    /// macOS kennen sie); eine vorhandene UTF-8-Locale bleibt unangetastet.
    static func utf8Environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let current = environment["LC_ALL"] ?? environment["LC_CTYPE"] ?? environment["LANG"] ?? ""
        let isUTF8 = current.lowercased().replacingOccurrences(of: "-", with: "").contains("utf8")
        if !isUTF8 {
            environment["LC_ALL"] = "C.UTF-8"
        }
        return environment
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        processTimeout: TimeInterval? = nil,
        cancellation: Cancellation? = nil
    ) throws -> Data {
        let stdinIsOpen = fcntl(STDIN_FILENO, F_GETFD) != -1
        let stdout = Pipe()
        let stderr = Pipe()
        let control = cancellation ?? Cancellation()
        let child = try control.start {
            try spawn(executable, arguments, stdout: stdout, stderr: stderr, stdinIsOpen: stdinIsOpen)
        }
        // Nur die Kinder behalten die Schreibenden; sonst käme niemals EOF.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        defer { control.finish() }
        let timer = processTimeout.map { timeout in
            let timer = DispatchSource.makeTimerSource(queue: signalQueue)
            timer.setEventHandler { control.stop(timeout: true) }
            timer.schedule(deadline: .now() + timeout)
            timer.resume()
            return timer
        }
        defer { timer?.cancel() }

        // Niemals zuerst stdout und danach stderr synchron lesen: Schreibt ein
        // Tool beide Pipes über ihren Kernel-Puffer hinaus, würde es beim
        // ungelesenen zweiten Stream blockieren und `waitUntilExit()` nie
        // erreichen. Genau zwei Queue-Arbeiten pro Prozess reichen aus; sie
        // lesen jeweils bis EOF und erzeugen keine Arbeit pro Daten-Chunk.
        let outCollector = PipeCollector(stdout.fileHandleForReading)
        let errCollector = PipeCollector(stderr.fileHandleForReading)
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "io.github.tagexplosion.pipe-drain",
                                       qos: .userInitiated, attributes: .concurrent)
        drainGroup.enter()
        drainQueue.async {
            outCollector.readToEnd()
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            errCollector.readToEnd()
            drainGroup.leave()
        }
        // Vor dem Reaping leeren: Solange die PID nicht freigegeben ist,
        // kann der verzögerte Gruppen-Kill keine wiederverwendete PID treffen.
        drainGroup.wait()
        let status = try control.reap(child)
        timer?.cancel()
        try control.check()
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
        let outData = outCollector.data()
        let errData = errCollector.data()
        guard exitCode == 0 else {
            throw TagError.toolFailed(
                name: (executable as NSString).lastPathComponent,
                exitCode: exitCode,
                stderr: ExternalToolText.decodeLossyPlainText(errData)
            )
        }
        return outData
    }

    /// posix_spawn legt vor exec eine eigene Prozessgruppe an. Ein nachträgliches
    /// setpgid beim Foundation-Process wäre ein Rennen gegen dessen exec.
    private static func spawn(_ executable: String, _ arguments: [String], stdout: Pipe, stderr: Pipe, stdinIsOpen: Bool) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { posix_spawnattr_destroy(&attributes) }
        func require(_ result: Int32) throws {
            if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        }
        // Geschlossene Standard-FDs können von Pipe() neu vergeben werden.
        // Sichere Quell-FDs >= 3 verhindern Überschreiben durch die dup2-Aktionen.
        let outputFD = fcntl(stdout.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard outputFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(outputFD) }
        let errorFD = fcntl(stderr.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard errorFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(errorFD) }
        if stdinIsOpen {
            try require(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO))
        } else {
            try require(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try require(posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO))
        try require(posix_spawn_file_actions_adddup2(&actions, errorFD, STDERR_FILENO))
        let descriptors = [stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting].map(\.fileDescriptor)
        for descriptor in Set(descriptors + [outputFD, errorFD]) where descriptor > STDERR_FILENO {
            try require(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        #if os(Linux)
        // Erst nach dup2 schließen: Das Werkzeug braucht nur stdin/out/err.
        // Fremde Schreib-FDs würden Dateien im Kind weiter offen halten und
        // können parallele Skriptstarts mit ETXTBSY (Text file busy) verhindern.
        try require(posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1))
        #endif
        try require(posix_spawnattr_setpgroup(&attributes, 0))
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        try require(posix_spawnattr_setflags(&attributes, flags))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = utf8Environment().map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in environment { free(pointer) }
        }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try require(result)
        return child
    }

    /// Externes Programm über eine Kandidatenliste finden: Einträge mit "/"
    /// werden als Pfad geprüft, alle anderen über PATH gesucht. Gemeinsamer
    /// Mechanismus für mediainfo/exiftool/ebook-meta.
    static func locateTool(candidates: [String], name: String) throws -> String {
        for candidate in candidates {
            if candidate.contains("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            } else if let found = which(candidate) {
                return found
            }
        }
        throw TagError.toolNotFound(name: name)
    }

    /// `which`-Ersatz: sucht ein Kommando im PATH.
    private static func which(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
