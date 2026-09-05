// Gemeinsame Prozess- und Werkzeugmechanik für die Metadaten-Backends.
import Foundation

public enum ExternalToolRunner {
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

    /// Steuert genau einen optionalen Ablauf-Timer für einen Prozess. Das Lock
    /// entscheidet atomar, ob der Prozess normal fertig wurde oder der Timer
    /// ihn beendet; so kann ein bereits beendeter Prozess nicht nachträglich
    /// als Timeout gelten. `Process` ist nicht als Sendable annotiert; der
    /// Controller kapselt deshalb seinen einzigen Zugriff aus der Timer-Queue
    /// und schützt seinen eigenen Zustand mit dem Lock.
    private final class ProcessTimeoutController: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var didTimeout = false

        init(process: Process) {
            self.process = process
        }

        /// Startet den einmaligen Timer erst, nachdem der Prozess wirklich
        /// läuft. Eine Referenz auf Argumente wird bewusst nicht gespeichert.
        func start(after timeout: TimeInterval) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.setEventHandler { [weak self] in
                self?.terminateIfStillRunning()
            }
            timer.schedule(deadline: .now() + timeout)

            lock.lock()
            self.timer = timer
            lock.unlock()
            timer.resume()
        }

        /// Macht den Timer nach einem regulären Prozessende unschädlich und
        /// meldet, ob er zuvor die Beendigung auslösen musste.
        func finish() -> Bool {
            lock.lock()
            let timer = self.timer
            self.timer = nil
            let didTimeout = self.didTimeout
            lock.unlock()

            timer?.cancel()
            return didTimeout
        }

        private func terminateIfStillRunning() {
            lock.lock()
            guard timer != nil, process.isRunning else {
                lock.unlock()
                return
            }
            didTimeout = true
            let timer = self.timer
            self.timer = nil
            lock.unlock()

            // Erst den Einmal-Timer freigeben, dann den noch laufenden
            // Kindprozess beenden. Nach `waitUntilExit()` liefern die beiden
            // Pipe-Reader dadurch zuverlässig EOF.
            timer?.cancel()
            process.terminate()
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
        processTimeout: TimeInterval? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = utf8Environment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Ein einziger Timer schützt den Hänger-Regressionstest. Er wird nach
        // einem normalen Ende sofort abgebrochen und speichert keine Argumente.
        let timeoutController = processTimeout.map { timeout in
            let controller = ProcessTimeoutController(process: process)
            controller.start(after: timeout)
            return controller
        }

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
        process.waitUntilExit()
        let didTimeout = timeoutController?.finish() ?? false
        // EOF erst nach dem Prozessende abwarten, damit die Fehlerdiagnose die
        // vollständige stderr-Ausgabe enthält, nicht nur ihren ersten Puffer.
        drainGroup.wait()
        if didTimeout {
            throw ProcessTimeoutError.exceeded
        }
        let outData = outCollector.data()
        let errData = errCollector.data()
        guard process.terminationStatus == 0 else {
            throw TagError.toolFailed(
                name: (executable as NSString).lastPathComponent,
                exitCode: process.terminationStatus,
                stderr: ExternalToolText.decodeLossyPlainText(errData)
            )
        }
        return outData
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
