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
    private static let drainQueue = DispatchQueue(label: "io.github.tagexplosion.pipe-drain",
                                                  qos: .userInitiated, attributes: .concurrent)

    /// Fehler für Aufrufe mit bewusstem Zeitlimit (Tests und KoSIT-Prototyp).
    /// Normale Metadaten-Aufrufe verwenden weiterhin keinen Timeout.
    enum ProcessTimeoutError: Error, LocalizedError, Sendable, Equatable {
        case exceeded

        var errorDescription: String? {
            "External process exceeded its timeout"
        }
    }

    enum ProcessOutputLimitError: Error, LocalizedError, Sendable, Equatable {
        case exceeded
        var errorDescription: String? { "External process exceeded its output limit" }
    }

    /// Sammelt genau einen Pipe-Stream. Die zwei Instanzen pro Prozess werden
    /// auf getrennten festen Queue-Arbeiten gelesen, damit ein volles stderr
    /// niemals stdout (oder umgekehrt) blockieren kann.
    private final class PipeCollector: @unchecked Sendable {
        private let handle: FileHandle
        private var collected = Data()
        private(set) var exceeded = false

        init(_ handle: FileHandle) {
            self.handle = handle
        }

        func readToEnd(limit: Int?, onLimit: () -> Void) {
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { return }
                if let limit {
                    let remaining = max(0, limit - collected.count)
                    collected.append(chunk.prefix(remaining))
                    if chunk.count > remaining, !exceeded {
                        exceeded = true
                        onLimit()
                    }
                } else {
                    collected.append(chunk)
                }
            }
        }

        func data() -> Data { collected }
    }

    /// Ein Abbruchsignal gehört einem Leseauftrag, auch wenn er nacheinander
    /// mehrere Prozesse benötigt. Start und Abbruch sind unter demselben Lock.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSCondition()
        private var pid: pid_t?
        private var cancelled = false
        private var timedOut = false
        private var escalated = false

        public init() {}
        public func cancel() { stop() }
        fileprivate func stop(timedOutChild: pid_t? = nil) {
            lock.lock()
            if cancelled || (timedOutChild != nil && pid != timedOutChild) {
                lock.unlock()
                return
            }
            cancelled = true
            timedOut = timedOutChild != nil
            let running = pid
            if let running { _ = kill(-running, SIGTERM) }
            lock.unlock()
            guard let running else { return }
            // Nur nach einem Abbruch, kein Zeitlimit für große Mediendateien.
            ExternalToolRunner.signalQueue.asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard pid == running else { return }
                _ = kill(-running, SIGKILL)
                escalated = true
                lock.broadcast()
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
            // Erst das Ende beobachten, ohne die PID freizugeben. Während
            // des Wartens bleibt der Gruppenleiter für cancel erreichbar.
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 {
                let code = errno
                if code != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            }
            lock.lock()
            defer { lock.unlock() }
            // Auch Nachkommen ohne offene Pipes brauchen den Gruppen-Kill.
            // Bis dahin hält der noch nicht abgeholte Leiter die ID reserviert.
            while cancelled && !escalated { lock.wait() }
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 {
                let code = errno
                if code != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            }
            pid = nil
            return status
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
        outputLimit: Int? = nil,
        environment: [String: String]? = nil,
        cancellation: Cancellation? = nil
    ) throws -> Data {
        let result = try runResult(executable, arguments, processTimeout: processTimeout,
            outputLimit: outputLimit, environment: environment, cancellation: cancellation)
        if result.termination == .exited(0) { return result.stdout }
        let name = (executable as NSString).lastPathComponent
        let stderr = ExternalToolText.decodeLossyPlainText(result.stderr)
        switch result.termination {
        case .exited(let code): throw TagError.toolFailed(name: name, exitCode: code, stderr: stderr)
        case .signalled(let signal): throw TagError.toolTerminated(name: name, signal: signal, stderr: stderr)
        }
    }

    struct ProcessResult {
        enum Termination: Equatable {
            case exited(Int32)
            case signalled(Int32)
        }
        let stdout: Data
        let stderr: Data
        let termination: Termination
    }

    // Validatoren können bei regulärer Zurückweisung einen vollständigen
    // Bericht auf stdout liefern. Der Aufrufer muss Exit und Bericht abgleichen.
    static func runResult(
        _ executable: String,
        _ arguments: [String],
        processTimeout: TimeInterval? = nil,
        outputLimit: Int? = nil,
        environment: [String: String]? = nil,
        cancellation: Cancellation? = nil
    ) throws -> ProcessResult {
        let stdout = Pipe()
        let stderr = Pipe()
        let control = cancellation ?? Cancellation()
        let child = try control.start {
            try spawn(executable, arguments, stdout: stdout, stderr: stderr,
                      environment: environment ?? utf8Environment())
        }
        // Nur die Kinder behalten die Schreibenden; sonst käme niemals EOF.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        defer { control.finish() }
        let timer = processTimeout.map { timeout in
            let timer = DispatchSource.makeTimerSource(queue: signalQueue)
            timer.setEventHandler { control.stop(timedOutChild: child) }
            timer.schedule(deadline: .now() + timeout)
            timer.resume()
            return timer
        }
        defer { timer?.cancel() }

        // Niemals zuerst stdout und danach stderr synchron lesen: Schreibt ein
        // Tool beide Pipes über ihren Kernel-Puffer hinaus, würde es beim
        // ungelesenen zweiten Stream blockieren und `waitid()` nie
        // erreichen. Genau zwei Queue-Arbeiten pro Prozess reichen aus; sie
        // lesen jeweils bis EOF und erzeugen keine Arbeit pro Daten-Chunk.
        let outCollector = PipeCollector(stdout.fileHandleForReading)
        let errCollector = PipeCollector(stderr.fileHandleForReading)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        drainQueue.async {
            outCollector.readToEnd(limit: outputLimit) { control.cancel() }
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            errCollector.readToEnd(limit: outputLimit) { control.cancel() }
            drainGroup.leave()
        }
        // Vor dem Reaping leeren: Solange die PID nicht freigegeben ist,
        // kann der verzögerte Gruppen-Kill keine wiederverwendete PID treffen.
        drainGroup.wait()
        let status = try control.reap(child)
        timer?.cancel()
        if outCollector.exceeded || errCollector.exceeded { throw ProcessOutputLimitError.exceeded }
        try control.check()
        let signal = status & 0x7f
        let termination: ProcessResult.Termination = signal == 0
            ? .exited((status >> 8) & 0xff) : .signalled(signal)
        let outData = outCollector.data()
        let errData = errCollector.data()
        return .init(stdout: outData, stderr: errData, termination: termination)
    }

    /// posix_spawn legt vor exec eine eigene Prozessgruppe an. Ein nachträgliches
    /// setpgid beim Foundation-Process wäre ein Rennen gegen dessen exec.
    private static func spawn(_ executable: String, _ arguments: [String], stdout: Pipe, stderr: Pipe,
                              environment: [String: String]) throws -> pid_t {
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
        // Die Engine benutzt ihr stdin für JSONL. Werkzeuge bekommen ihre
        // Eingabe ausschließlich über Argumente und Dateien.
        try require(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
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
        // Ignorierte oder blockierte Signale des App-Prozesses sollen den
        // regulären SIGTERM-Abbruch des Werkzeugs nicht verhindern.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        try require(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var mask = sigset_t()
        try require(pthread_sigmask(SIG_SETMASK, nil, &mask))
        sigdelset(&mask, SIGTERM)
        try require(posix_spawnattr_setsigmask(&attributes, &mask))
        var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        try require(posix_spawnattr_setflags(&attributes, flags))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in environment { free(pointer) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
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
