// Netzwerkschicht des Online-Lookups: ein kleines Protokoll über HTTP, damit
// Tests einen Stub mit aufgezeichneten JSON-Antworten einsetzen können, und
// der Standardtransport libcurl verwendet. Dazu der Ratenbegrenzer (höchstens
// eine Anfrage pro Sekunde je Dienst) und die Wiederholung bei 503/429.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Eine HTTP-Anfrage. Zugangsdaten stehen nur in Headern oder im Body, nie
/// in der URL — URLs landen in Logs und Proxys.
public struct LookupHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Eine HTTP-Antwort. Header-Namen sind kleingeschrieben, damit
/// `headers["retry-after"]` unabhängig von der Schreibweise des Servers klappt.
public struct LookupHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = [:]
        // Bei mehrfacher Schreibweise gewinnt deterministisch der kleingeschriebene Name.
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            self.headers[name.lowercased()] = value
        }
        self.body = body
    }
}

/// Abstraktion über den Transport. Produktion: `URLSessionLookupClient`;
/// Tests: ein Stub, der Anfragen auf vorbereitete Antworten abbildet.
public protocol LookupHTTPClient: Sendable {
    func send(_ request: LookupHTTPRequest) async throws -> LookupHTTPResponse
}

/// Standardtransport über libcurl. Explizite Session-Konfigurationen nutzen URLSession.
public final class URLSessionLookupClient: LookupHTTPClient {
    static let maximumResponseBytes = 16 * 1024 * 1024
    private enum Transport: Sendable {
        case ownedSession(URLSession, LookupHTTPReceiver)
        case curl
        #if os(Linux)
        case unsupportedSessionDelegate
        #else
        case borrowedSession(URLSession)
        #endif
    }
    private let transport: Transport

    /// Verwendet unter macOS die übergebene Session samt Delegate.
    /// Das Empfangslimit gilt für die ausgelieferte Antwort. Zwischenschritte
    /// einer Weiterleitung verarbeitet URLSession.
    /// Linux übernimmt die Konfiguration einer Session ohne Delegate.
    /// Bei einer Linux-Session mit Delegate schlägt der Lookup vor dem Senden
    /// fehl. FoundationNetworking braucht für den begrenzten Empfang einen
    /// beim Anlegen der Session eingebauten Daten-Delegate.
    public init(session: URLSession? = nil) {
        #if os(Linux)
        if let session {
            transport = session.delegate == nil
                ? Self.makeTransport(configuration: session.configuration)
                : .unsupportedSessionDelegate
        } else {
            transport = .curl
        }
        #else
        transport = session.map(Transport.borrowedSession) ?? .curl
        #endif
    }

    /// Verwendet URLSession mit eigener Konfiguration, etwa für URLProtocol-Tests.
    /// Das Limit gilt für den von URLSession übergebenen Antwortinhalt.
    public init(configuration: URLSessionConfiguration) {
        transport = Self.makeTransport(configuration: configuration)
    }

    private static func makeTransport(configuration: URLSessionConfiguration) -> Transport {
        let receiver = LookupHTTPReceiver()
        return .ownedSession(URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil), receiver)
    }

    deinit {
        if case let .ownedSession(session, _) = transport { session.finishTasksAndInvalidate() }
    }

    public func send(_ request: LookupHTTPRequest) async throws -> LookupHTTPResponse {
        switch transport {
        case let .ownedSession(session, receiver):
            let (data, response) = try await receiver.receive(Self.urlRequest(request), using: session)
            return Self.lookupResponse(data, response)
        case .curl:
            return try await CurlLookupHTTP.send(request)
        #if os(Linux)
        case .unsupportedSessionDelegate:
            throw LookupHTTPSessionError.unsupportedDelegate
        #else
        case .borrowedSession(let session):
            let (data, response) = try await receive(Self.urlRequest(request), from: session)
            return Self.lookupResponse(data, response)
        #endif
        }
    }

    #if !os(Linux)
    private func receive(_ request: URLRequest, from session: URLSession) async throws -> (Data, URLResponse) {
        // Der Session-Delegate entscheidet weiterhin über Vertrauen, Anmeldung
        // und Redirects. URLSession begrenzt die Redirect-Kette.
        let (bytes, response) = try await session.bytes(for: request)
        let task = bytes.task
        return try await withTaskCancellationHandler {
            var body = Data()
            for try await byte in bytes {
                guard body.count < Self.maximumResponseBytes else {
                    task.cancel()
                    throw LookupHTTPResponseTooLarge(maximumBytes: Self.maximumResponseBytes)
                }
                body.append(byte)
            }
            guard !Task.isCancelled else { throw URLError(.cancelled) }
            return (body, response)
        } onCancel: {
            task.cancel()
        }
    }
    #endif

    private static func urlRequest(_ request: LookupHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private static func lookupResponse(_ data: Data, _ response: URLResponse) -> LookupHTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            return LookupHTTPResponse(statusCode: 0, body: data)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return LookupHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

#if os(Linux)
enum LookupHTTPSessionError: LocalizedError, Equatable {
    case unsupportedDelegate

    var errorDescription: String? { "Bounded online lookup cannot use a URLSession delegate on Linux." }
}
#endif

struct LookupHTTPResponseTooLarge: LocalizedError, Equatable {
    let maximumBytes: Int

    var errorDescription: String? { "Online lookup response exceeds \(maximumBytes) bytes" }
}

private final class LookupHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias ResponseStream = AsyncThrowingStream<(Data, URLResponse), Error>

    private struct Transfer {
        let completion: ResponseStream.Continuation
        var body = Data()
        var limitExceeded = false
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    func receive(_ request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        let (result, completion) = ResponseStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            transfers[task.taskIdentifier] = Transfer(completion: completion)
        }
        defer {
            lock.withLock { transfers[task.taskIdentifier] = nil }
        }
        return try await withTaskCancellationHandler {
            if !Task.isCancelled { task.resume() }
            var iterator = result.makeAsyncIterator()
            guard let response = try await iterator.next() else {
                throw URLError(.cancelled)
            }
            return response
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldCancel = lock.withLock {
            let id = dataTask.taskIdentifier
            guard transfers[id]?.limitExceeded == false, let size = transfers[id]?.body.count else { return false }
            guard data.count <= URLSessionLookupClient.maximumResponseBytes - size else {
                transfers[id]?.limitExceeded = true
                transfers[id]?.body = Data()
                return true
            }
            transfers[id]?.body.append(data)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        if transfer.limitExceeded {
            transfer.completion.finish(throwing: LookupHTTPResponseTooLarge(
                maximumBytes: URLSessionLookupClient.maximumResponseBytes))
        } else if let error {
            transfer.completion.finish(throwing: error)
        } else if let response = task.response {
            transfer.completion.yield((transfer.body, response))
            transfer.completion.finish()
        } else {
            transfer.completion.finish(throwing: URLError(.badServerResponse))
        }
    }
}

/// Das echte Schlafen für Ratenbegrenzer und 503-Wiederholung.
///
/// Bewusst `Task.sleep(nanoseconds:)` statt `Task.sleep(for:)`: Die generische
/// Variante in einer gespeicherten async-Closure ließ den Swift-6-Compiler
/// (Xcode 26) Task-Speicher in falscher Reihenfolge freigeben — Absturz
/// „freed pointer was not the last allocation" beim zweiten `waitTurn()`.
/// Die Stub-Closures der Tests waren davon nicht betroffen; der Fehler fiel
/// erst im Rauchtest gegen MusicBrainz auf.
public enum LookupSleep {
    public static let real: RateLimiter.Sleep = { seconds in
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Höchstens eine Anfrage je `minimumInterval` — MusicBrainz verlangt das
/// ausdrücklich, Discogs und AcoustID vertragen es gut. Ein Actor, damit
/// parallele Aufrufer sich nacheinander einreihen.
///
/// Uhr und Schlafen sind austauschbar, damit Tests die Wartezeiten ohne
/// echtes Warten prüfen können. Nach dem Schlafen gilt der geplante Slot als
/// Zeitpunkt der Anfrage, nicht die erneut gelesene Uhr — so bleibt das
/// Verhalten auch mit einer stehenden Testuhr deterministisch.
public actor RateLimiter {
    public typealias Clock = @Sendable () -> TimeInterval
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let minimumInterval: TimeInterval
    private let now: Clock
    private let sleep: Sleep
    private var nextAllowed: TimeInterval?

    public init(minimumInterval: TimeInterval = 1.0,
                now: @escaping Clock = { Date().timeIntervalSinceReferenceDate },
                sleep: @escaping Sleep = LookupSleep.real) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.sleep = sleep
    }

    /// Wartet, bis die nächste Anfrage erlaubt ist, und reserviert den Slot.
    public func waitTurn() async throws {
        let current = now()
        let slot = max(current, nextAllowed ?? current)
        nextAllowed = slot + minimumInterval
        if slot > current {
            try await sleep(slot - current)
        }
    }
}

/// Gemeinsamer Anfrageweg aller Clients: Ratenbegrenzer, User-Agent und die
/// Behandlung von 503/429 mit `Retry-After`.
struct LookupTransport: Sendable {
    let client: LookupHTTPClient
    let limiter: RateLimiter
    let userAgent: String
    let sleep: RateLimiter.Sleep
    /// Wie oft nach 503/429 erneut versucht wird, bevor `rateLimited` fliegt.
    let maximumRetries: Int

    init(client: LookupHTTPClient, limiter: RateLimiter, userAgent: String,
         sleep: @escaping RateLimiter.Sleep = LookupSleep.real,
         maximumRetries: Int = 2) {
        self.client = client
        self.limiter = limiter
        self.userAgent = userAgent
        self.sleep = sleep
        self.maximumRetries = maximumRetries
    }

    /// Schickt die Anfrage; 2xx liefert die Antwort, 503/429 wird nach der
    /// vom Server gewünschten Pause wiederholt, alles andere ist ein Fehler.
    func send(_ request: LookupHTTPRequest, source: LookupSource) async throws -> LookupHTTPResponse {
        var request = request
        request.headers["User-Agent"] = userAgent
        if request.headers["Accept"] == nil { request.headers["Accept"] = "application/json" }
        var attempt = 0
        while true {
            try await limiter.waitTurn()
            let response = try await client.send(request)
            switch response.statusCode {
            case 200...299:
                return response
            case 429, 503:
                let wait = Self.retryAfterSeconds(response)
                guard attempt < maximumRetries else {
                    throw LookupError.rateLimited(source: source, retryAfterSeconds: wait)
                }
                attempt += 1
                try await sleep(TimeInterval(wait))
            default:
                throw LookupError.httpStatus(source: source, status: response.statusCode)
            }
        }
    }

    /// `Retry-After` in Sekunden; ohne Header oder bei einem Datum statt einer
    /// Zahl eine konservative Vorgabe von 2 s. Nach oben begrenzt, damit ein
    /// Server keine Minuten Stillstand erzwingt.
    static func retryAfterSeconds(_ response: LookupHTTPResponse) -> Int {
        guard let raw = response.headers["retry-after"], let seconds = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            return 2
        }
        return min(max(seconds, 1), 30)
    }
}

/// Kleine JSON-Hilfen für die Parser: Die Dienste liefern gemischte Typen
/// (Zahl oder Text für Jahr und ID), deshalb lesen wir tolerant.
enum LookupJSON {
    static func object(from data: Data, source: LookupSource) throws -> [String: Any] {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            throw LookupError.invalidResponse(source: source, reason: "not a JSON object")
        }
        return object
    }

    static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber {
            // stringValue erhält große Ganzzahlen exakt; der zweite Weg
            // akzeptiert ganzzahlige Fließkommazahlen, ohne sie abzuschneiden.
            return Int(n.stringValue) ?? Int(exactly: n.doubleValue)
        }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]]) ?? []
    }

    /// "3:45" → 225000 ms (Discogs schreibt Dauern als mm:ss).
    static func milliseconds(fromClock text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var seconds = 0
        for part in parts {
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            let (scaled, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 60)
            let (total, addOverflow) = scaled.addingReportingOverflow(value)
            guard !multiplyOverflow, !addOverflow else { return nil }
            seconds = total
        }
        return milliseconds(fromSeconds: seconds)
    }

    /// Fremde Dauern müssen auch nach der Einheitenumrechnung darstellbar sein.
    static func milliseconds(fromSeconds seconds: Int) -> Int? {
        let (result, overflow) = seconds.multipliedReportingOverflow(by: 1000)
        return seconds >= 0 && !overflow ? result : nil
    }

    /// Query-String mit sauberer Prozentkodierung (auch für `&`, `+`, `:`).
    static func encodeQuery(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
