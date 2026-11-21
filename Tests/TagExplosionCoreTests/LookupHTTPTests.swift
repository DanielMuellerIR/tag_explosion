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
}

#if os(Linux)
@Suite("Online-Lookup: Linux-HTTP")
struct LinuxLookupHTTPTests {
    @Test("Linux lehnt Zielprotokolle außerhalb von HTTPS für eine HTTPS-Weiterleitung ab",
          arguments: ["http://cover.test/image", "file:///tmp/image"])
    func rejectRedirectDowngrade(_ location: String) throws {
        let request = LookupHTTPRequest(url: URL(string: "https://lookup.test/cover")!)
        #expect(throws: URLError(.redirectToNonExistentLocation)) {
            _ = try LinuxLookupHTTP.redirected(request, status: 302, location: location)
        }
    }

    @Test("Linux folgt Weiterleitungen vor dem Zwischen-Body und schützt Zugangsdaten")
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

    @Test("Linux bricht eine zu große laufende Antwort ab und liefert Retry-After")
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

    @Test("Linux beendet eine laufende Anfrage bei Task-Abbruch")
    func cancelsNativeTransfer() async throws {
        let server = try LookupLoopbackServer()
        defer { server.stop() }
        let client = URLSessionLookupClient()
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

private struct LookupLoopbackServer {
    let process: Process
    let port: Int

    init() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script]
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
                if self.path == "/same":
                    self.redirect(302, "/headers")
                elif self.path == "/redirect":
                    self.redirect(302, f"http://127.0.0.1:{target.server_port}/headers")
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
                else:
                    values = [self.headers.get(name, "") for name in ("Authorization", "Accept")]
                    self.reply(200, "|".join(values).encode())

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path == "/redirect":
                    self.redirect(307, f"http://127.0.0.1:{target.server_port}/status")
                else:
                    self.reply(503, body, **{"Retry-After": "3"})

        started = threading.Event()
        target = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        print(server.server_port)
        server.serve_forever()
        """#
}
#endif
