import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TagExplosionCore

private final class LookupHTTPTestProtocol: URLProtocol {
    static let pendingRequests = AsyncStream<Void>.makeStream()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let isStatusCheck = url.path == "/status"
        let response = HTTPURLResponse(url: url, statusCode: isStatusCheck ? 503 : 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: isStatusCheck ? ["Retry-After": "3"] : nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch url.path {
        case "/at-limit", "/over-limit":
            let chunk = Data(repeating: 65, count: 8 * 1024 * 1024)
            client.urlProtocol(self, didLoad: chunk)
            client.urlProtocol(self, didLoad: chunk)
            if url.path == "/over-limit" {
                // Ohne Content-Length und ohne Signal für das Antwortende.
                client.urlProtocol(self, didLoad: Data([66]))
                return
            }
        case "/pending":
            Self.pendingRequests.continuation.yield()
            return
        default:
            client.urlProtocol(self, didLoad: Data("status".utf8))
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LookupSessionPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects: [ObjectIdentifier] = []
    private var challenges: [ObjectIdentifier] = []

    var redirectSessions: [ObjectIdentifier] { lock.withLock { redirects } }
    var challengeSessions: [ObjectIdentifier] { lock.withLock { challenges } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { redirects.append(ObjectIdentifier(session)) }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.withLock { challenges.append(ObjectIdentifier(session)) }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

@Suite("Online-Lookup: URLSession")
struct LookupHTTPTests {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LookupHTTPTestProtocol.self]
        return config
    }

    private func request(_ path: String) -> LookupHTTPRequest {
        LookupHTTPRequest(url: URL(string: "https://lookup.test/\(path)")!)
    }

    @Test("Antwort genau an der Empfangsgrenze bleibt vollständig")
    func acceptResponseAtLimit() async throws {
        let client = URLSessionLookupClient(configuration: configuration())
        let response = try await client.send(request("at-limit"))
        #expect(response.statusCode == 200)
        #expect(response.body.count == 16 * 1024 * 1024)
        #expect(response.body.first == 65 && response.body.last == 65)
    }

    @Test("Zu große Antwort bricht vor dem Antwortende ab")
    func cancelOversizedResponseDuringReceive() async throws {
        let client = URLSessionLookupClient(configuration: configuration())
        let oversized = request("over-limit")
        await #expect(throws: LookupHTTPResponseTooLarge(maximumBytes: 16 * 1024 * 1024)) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await client.send(oversized) }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }

        let response = try await client.send(request("status"))
        #expect(response.statusCode == 503)
        #expect(response.headers["retry-after"] == "3")
        #expect(response.body == Data("status".utf8))
    }

    @Test("Abbruch betrifft nur die laufende Anfrage", .timeLimit(.minutes(1)))
    func cancelPendingResponse() async throws {
        let client = URLSessionLookupClient(configuration: configuration())
        let pending = request("pending")
        let task = Task { try await client.send(pending) }
        var requests = LookupHTTPTestProtocol.pendingRequests.stream.makeAsyncIterator()
        _ = try #require(await requests.next())
        task.cancel()
        let error = await #expect(throws: URLError.self) {
            _ = try await task.value
        }
        #expect(error?.code == .cancelled)
        #expect(try await client.send(request("status")).statusCode == 503)
    }

    @Test("Eine übergebene Session bleibt nach dem Lookup benutzbar")
    func preserveSuppliedSession() async throws {
        let session = URLSession(configuration: configuration())
        defer { session.finishTasksAndInvalidate() }
        let status = request("status")
        let response = try await URLSessionLookupClient(session: session).send(status)
        #expect(response.statusCode == 503)
        let (data, _) = try await session.data(from: status.url)
        #expect(data == Data("status".utf8))
    }

    #if os(Linux)
    @Test("Linux lehnt eine übergebene Session mit Delegate vor dem Lookup ab")
    func rejectsUnsupportedSuppliedDelegate() async {
        let session = URLSession(configuration: configuration(), delegate: LookupSessionPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        await #expect(throws: LookupHTTPSessionError.unsupportedDelegate) {
            _ = try await URLSessionLookupClient(session: session).send(request("status"))
        }
    }
    #else
    @Test("Die übergebene Session entscheidet über Weiterleitung und Anmeldung")
    func preservesSuppliedSessionPolicy() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let policy = LookupSessionPolicy()
        let session = URLSession(configuration: .ephemeral, delegate: policy, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let client = URLSessionLookupClient(session: session)

        let response = try await client.send(LookupHTTPRequest(url: server.url("finite-redirect")))
        #expect(response.statusCode == 302)
        #expect(response.body == Data("redirect".utf8))
        #expect(policy.redirectSessions == [ObjectIdentifier(session)])

        await #expect(throws: URLError.self) {
            _ = try await client.send(LookupHTTPRequest(url: server.url("auth-required")))
        }
        #expect(policy.challengeSessions == [ObjectIdentifier(session)])
    }

    @Test("URLSession begrenzt die Weiterleitungskette einer übergebenen Session")
    func capsSuppliedSessionRedirects() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let client = URLSessionLookupClient(session: session)
        #expect(try await client.send(LookupHTTPRequest(url: server.url("finite-redirect"))).statusCode == 200)
        let error = await #expect(throws: URLError.self) {
            _ = try await client.send(LookupHTTPRequest(url: server.url("redirect-loop")))
        }
        #expect(error?.code == .httpTooManyRedirects)
    }

    @Test("Eine übergebene Session stoppt eine zu große Antwort beim Empfang")
    func capsSuppliedSessionBodyDuringReceive() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let client = URLSessionLookupClient(session: session)
        let request = LookupHTTPRequest(url: server.url("large"))
        await #expect(throws: LookupHTTPResponseTooLarge(maximumBytes: 16 * 1024 * 1024)) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await client.send(request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }
    #endif

    @Test("Task-Abbruch beendet eine laufende HTTP-Anfrage")
    func cancelsNativeTransfer() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        #if os(Linux)
        let client = URLSessionLookupClient()
        #else
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let client = URLSessionLookupClient(session: session)
        #endif
        let pending = Task { try await client.send(LookupHTTPRequest(url: server.url("pending"))) }
        defer { pending.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while try await client.send(LookupHTTPRequest(url: server.url("started"))).statusCode != 200 {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }

        let start = Date()
        pending.cancel()
        let error = await #expect(throws: URLError.self) { _ = try await pending.value }
        #expect(error?.code == .cancelled)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite("Online-Lookup: Standardtransport")
struct DefaultLookupHTTPTests {
    @Test("Der Standardtransport lehnt Zielprotokolle außerhalb von HTTPS für eine HTTPS-Weiterleitung ab",
          arguments: ["http://cover.test/image", "file:///tmp/image"])
    func rejectRedirectDowngrade(_ location: String) throws {
        let request = LookupHTTPRequest(url: URL(string: "https://lookup.test/cover")!)
        #expect(throws: URLError(.redirectToNonExistentLocation)) {
            _ = try CurlLookupHTTP.redirected(request, status: 302, location: location)
        }
    }

    @Test("Der Standardtransport folgt Weiterleitungen vor dem Zwischen-Body und schützt Zugangsdaten")
    func redirectsBeforeBody() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let client = URLSessionLookupClient()
        let headers = ["Authorization": "test-token", "Accept": "application/json"]

        let sameOrigin = try await client.send(LookupHTTPRequest(url: server.url("same"), headers: headers))
        #expect(sameOrigin.statusCode == 200)
        #expect(String(decoding: sameOrigin.body, as: UTF8.self) == "test-token|application/json")
        let redirected = try await client.send(LookupHTTPRequest(url: server.url("redirect"), headers: headers))
        #expect(redirected.statusCode == 200)
        #expect(String(decoding: redirected.body, as: UTF8.self) == "|application/json")

        let refused = LookupHTTPRequest(method: "POST", url: server.url("redirect"), body: Data("test".utf8))
        let error = await #expect(throws: URLError.self) { _ = try await client.send(refused) }
        #expect(error?.code == .redirectToNonExistentLocation)
    }

    @Test("Der Standardtransport bricht eine zu große laufende Antwort ab und liefert Retry-After")
    func capsReceivedBody() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let client = URLSessionLookupClient()
        await #expect(throws: LookupHTTPResponseTooLarge(maximumBytes: 16 * 1024 * 1024)) {
            _ = try await client.send(LookupHTTPRequest(url: server.url("large")))
        }
        let response = try await client.send(LookupHTTPRequest(method: "POST", url: server.url("status"),
                                                              body: Data("metadata".utf8)))
        #expect(response.statusCode == 503)
        #expect(response.headers["retry-after"] == "3")
        #expect(response.body == Data("metadata".utf8))
    }

    @Test("Nur ein Proxy-Ausfall beim CONNECT erlaubt die nächste Route", arguments: [502, 503, 504, 403, 407])
    func retriesFailedProxyTunnel(_ status: Int) async throws {
        let first = try LookupLoopbackServer(connectStatus: status)
        defer { first.stop() }
        let second = try LookupLoopbackServer(connectStatus: 407)
        defer { second.stop() }
        let proxies = [first, second].map { CurlLookupProxy(address: "http://127.0.0.1:\($0.port)") }
        let request = LookupHTTPRequest(method: "POST", url: URL(string: "https://lookup.test/")!,
                                        body: Data("lookup".utf8))

        await #expect(throws: (any Error).self) {
            _ = try await CurlLookupHTTP.send(request, resolvingProxies: { _, _ in proxies })
        }
        let direct: CurlLookupHTTP.ProxyResolver = { _, _ in [CurlLookupProxy(address: "")] }
        let firstState = try await CurlLookupHTTP.send(LookupHTTPRequest(url: first.url("connect-seen")),
                                                       resolvingProxies: direct)
        let secondState = try await CurlLookupHTTP.send(LookupHTTPRequest(url: second.url("connect-seen")),
                                                        resolvingProxies: direct)
        #expect(firstState.statusCode == 200)
        #expect(secondState.statusCode == ([502, 503, 504].contains(status) ? 200 : 404))
    }
}

#if os(macOS)
@Suite("Online-Lookup: macOS-Systemproxy")
struct MacLookupProxyTests {
    @Test("Systemeinstellungen wählen den passenden Proxy oder eine Ausnahme")
    func staticRoutes() throws {
        let settings: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "http-proxy.test", "HTTPPort": 8080,
            "HTTPSEnable": 1, "HTTPSProxy": "https-proxy.test", "HTTPSPort": 8081,
            "ExceptionsList": ["*.local"]
        ]
        #expect(try MacLookupProxy.routes(for: URL(string: "http://lookup.test")!, settings: settings,
                                        isCancelled: { false }).map(\.address) == ["http://http-proxy.test:8080"])
        #expect(try MacLookupProxy.routes(for: URL(string: "https://lookup.test")!, settings: settings,
                                        isCancelled: { false }).map(\.address) == ["http://https-proxy.test:8081"])
        #expect(try MacLookupProxy.routes(for: URL(string: "https://lookup.local")!, settings: settings,
                                        isCancelled: { false }).map(\.address) == [""])
    }

    @Test("PAC entscheidet für jede Ziel-URL erneut und libcurl nutzt den gewählten Proxy")
    func routeRedirectThroughPAC() async throws {
        let first = try LookupLoopbackServer()
        defer { first.stop() }
        let second = try LookupLoopbackServer()
        defer { second.stop() }
        let script = """
        function FindProxyForURL(url, host) {
            if (host === 'first.test') return 'PROXY 127.0.0.1:\(first.port)';
            return 'PROXY 127.0.0.1:\(second.port)';
        }
        """
        let request = LookupHTTPRequest(url: URL(string: "http://first.test/proxy-redirect")!)
        let response = try await CurlLookupHTTP.send(request) { url, isCancelled in
            try MacLookupProxy.routes(for: url, settings: ["ProxyAutoConfigEnable": 1,
                                                          "ProxyAutoConfigJavaScript": script],
                                      isCancelled: isCancelled)
        }
        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "http://second.test/proxy-result|\(second.port)")
    }

    @Test("Nur ein PAC-Ergebnis darf nach einem Proxy DIRECT erlauben")
    func explicitDirect() throws {
        let url = URL(string: "https://lookup.test")!
        let proxy = "http://proxy.test:8080"
        for routes in ["PROXY proxy.test:8080", "PROXY proxy.test:8080; DIRECT"] {
            let script = "function FindProxyForURL(url, host) { return '\(routes)'; }"
            let result = try MacLookupProxy.routes(for: url, settings: ["ProxyAutoConfigEnable": 1,
                                                                      "ProxyAutoConfigJavaScript": script],
                                                  isCancelled: { false })
            #expect(result.map(\.address) == (routes.hasSuffix("DIRECT") ? [proxy, ""] : [proxy]))
        }
    }

    @Test("Unbrauchbare automatische Proxyregeln verhindern den Request")
    func invalidAutomaticRoutes() {
        let url = URL(string: "https://lookup.test")!
        let broken: [[String: Any]] = [
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigJavaScript": "function }"],
            ["ProxyAutoConfigEnable": 1],
            ["ProxyAutoDiscoveryEnable": 1]
        ]
        for settings in broken {
            #expect(throws: MacLookupProxy.Failure.unavailable) {
                _ = try MacLookupProxy.routes(for: url, settings: settings, isCancelled: { false })
            }
        }
    }

    @Test("Die PAC-Auflösung hat ein Zeitlimit")
    func pendingPAC() throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let url = URL(string: "https://lookup.test")!
        let settings: [String: Any] = ["ProxyAutoConfigEnable": 1,
                                       "ProxyAutoConfigURLString": server.url("pending").absoluteString]
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: MacLookupProxy.Failure.timedOut) {
            _ = try MacLookupProxy.routes(for: url, settings: settings, timeout: .milliseconds(500),
                                          isCancelled: { false })
        }
        #expect(clock.now - start < .seconds(3))
    }
}
#endif

private struct LookupLoopbackServer {
    let process: Process
    let port: Int

    init(connectStatus: Int = 407) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, String(connectStatus)]
        process.standardOutput = output
        try process.run()
        try output.fileHandleForWriting.close()
        let address = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = Int(address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw URLError(.cannotConnectToHost)
        }
        self.process = process
        self.port = port
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static let script = #"""
        import signal
        import sys
        import threading
        import time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        # Swift Testing startet Unterprozesse mit blockierten Signalen.
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def reply(self, status, body, **headers):
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                for name, value in headers.items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(body)

            def redirect(self, status, target):
                self.send_response(status)
                self.send_header("Location", target)
                self.send_header("Content-Length", "4")
                self.send_header("Connection", "close")
                self.end_headers()
                # Der Lookup muss weitergehen, bevor der Server den Body liefert.
                time.sleep(35)

            def do_GET(self):
                if self.path == "http://first.test/proxy-redirect":
                    self.redirect(302, "http://second.test/proxy-result")
                elif self.path == "http://second.test/proxy-result":
                    self.reply(200, f"{self.path}|{self.server.server_port}".encode())
                elif self.path == "/same":
                    self.redirect(302, "/headers")
                elif self.path == "/redirect":
                    self.redirect(302, f"http://127.0.0.1:{target.server_port}/headers")
                elif self.path == "/finite-redirect":
                    self.reply(302, b"redirect", Location="/headers")
                elif self.path == "/redirect-loop":
                    self.reply(302, b"redirect", Location="/redirect-loop")
                elif self.path == "/auth-required":
                    self.reply(401, b"authentication required", **{"WWW-Authenticate": 'Basic realm="Lookup"'})
                elif self.path == "/large":
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    chunk = b"8000\r\n" + b"x" * 32768 + b"\r\n"
                    try:
                        for _ in range(513):
                            self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    time.sleep(35)
                elif self.path == "/pending":
                    self.send_response(200)
                    self.send_header("Content-Length", "4")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(b"x")
                    started.set()
                    time.sleep(35)
                elif self.path == "/started":
                    self.reply(200 if started.is_set() else 404, b"")
                elif self.path == "/connect-seen":
                    self.reply(200 if connect_seen.is_set() else 404, b"")
                else:
                    values = [self.headers.get(name, "") for name in ("Authorization", "Accept")]
                    self.reply(200, "|".join(values).encode())

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path == "/redirect":
                    self.redirect(307, f"http://127.0.0.1:{target.server_port}/status")
                else:
                    self.reply(503, body, **{"Retry-After": "3"})

            def do_CONNECT(self):
                connect_seen.set()
                headers = {"Proxy-Authenticate": 'Basic realm="Lookup"'} if connect_status == 407 else {}
                self.reply(connect_status, b"", **headers)

        started = threading.Event()
        connect_seen = threading.Event()
        connect_status = int(sys.argv[1])
        target = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        print(server.server_port)
        server.serve_forever()
        """#
}
