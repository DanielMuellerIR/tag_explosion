import CLookupHTTP
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CurlLookupProxy: Sendable, Equatable {
    // nil verwendet libcurl-Umgebungsvariablen, "" erzwingt DIRECT.
    var address: String?
    var username: String? = nil
    var password: String? = nil
}

enum CurlLookupHTTP {
    typealias ProxyResolver = @Sendable (URL, @Sendable () -> Bool) throws -> [CurlLookupProxy]

    private static let maximumRedirects = 20
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    static func send(_ request: LookupHTTPRequest) async throws -> LookupHTTPResponse {
        #if os(macOS)
        try await send(request, resolvingProxies: MacLookupProxy.systemRoutes)
        #else
        try await send(request, resolvingProxies: { _, _ in [CurlLookupProxy(address: nil)] })
        #endif
    }

    static func send(_ request: LookupHTTPRequest,
                     connectTimeoutMilliseconds: Int = 30_000,
                     resolvingProxies: @escaping ProxyResolver) async throws -> LookupHTTPResponse {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await followRedirects(request, cancellation: cancellation, connectTimeoutMilliseconds: connectTimeoutMilliseconds,
                                      resolvingProxies: resolvingProxies)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func followRedirects(_ initialRequest: LookupHTTPRequest,
                                        cancellation: Cancellation,
                                        connectTimeoutMilliseconds: Int,
                                        resolvingProxies: @escaping ProxyResolver) async throws -> LookupHTTPResponse {
        var request = initialRequest
        for hop in 0...maximumRedirects {
            try cancellation.check()
            guard validURL(request.url) else { throw URLError(.unsupportedURL) }
            let current = request
            let response: LookupHTTPResponse
            let location: String?
            do {
                (response, location) = try await BlockingWork.run {
                    let proxies = try resolvingProxies(current.url) { cancellation.isCancelled }
                    return try receive(current, proxies: proxies, cancellation: cancellation,
                                       connectTimeoutMilliseconds: connectTimeoutMilliseconds)
                }
            } catch {
                #if os(macOS)
                guard error as? MacLookupProxy.Failure == .requiresSystemTransport else { throw error }
                response = try await URLSessionLookupClient.systemProxyResponse(current)
                location = redirectStatuses.contains(response.statusCode) ? response.headers["location"] : nil
                #else
                throw error
                #endif
            }
            guard let location else { return response }
            guard hop < maximumRedirects else { break }
            request = try redirected(request, status: response.statusCode, location: location)
        }
        throw URLError(.httpTooManyRedirects)
    }

    private static func receive(_ request: LookupHTTPRequest, proxies: [CurlLookupProxy],
                                cancellation: Cancellation,
                                connectTimeoutMilliseconds: Int) throws -> (LookupHTTPResponse, String?) {
        var lastFailure: TransferError?
        for proxy in proxies {
            try cancellation.check()
            let transfer = Transfer(cancellation: cancellation)
            do {
                let response = try transfer.perform(request, proxy: proxy, connectTimeoutMilliseconds: connectTimeoutMilliseconds)
                return (response, transfer.redirectLocation)
            } catch let error as TransferError where error.canTryNextProxy {
                // Nach Fehlern beim Empfang könnte der Dienst den Auftrag bereits verarbeitet haben.
                lastFailure = error
            }
        }
        if let lastFailure {
            if tagx_lookup_is_timeout(lastFailure.code) { throw URLError(.timedOut) }
            throw lastFailure
        }
        throw URLError(.cannotConnectToHost)
    }

    static func redirected(_ initialRequest: LookupHTTPRequest, status: Int,
                           location: String) throws -> LookupHTTPRequest {
        var request = initialRequest
        guard let target = URL(string: location, relativeTo: request.url)?.absoluteURL,
              validURL(target),
              request.url.scheme?.lowercased() != "https" || target.scheme?.lowercased() == "https" else {
            throw URLError(.redirectToNonExistentLocation)
        }
        let method = request.method.uppercased()
        if (status == 303 && method != "HEAD") || ([301, 302].contains(status) && method == "POST") {
            request.method = "GET"
            request.body = nil
            request.headers = request.headers.filter {
                let name = $0.key.lowercased()
                return !name.hasPrefix("content-") && name != "transfer-encoding" && name != "expect"
            }
        }
        if origin(request.url) != origin(target) {
            // Token und POST-Daten sind nur für den ursprünglichen Dienst bestimmt.
            guard request.body == nil, ["GET", "HEAD"].contains(request.method.uppercased()) else {
                throw URLError(.redirectToNonExistentLocation)
            }
            request.headers = request.headers.filter { ["accept", "user-agent"].contains($0.key.lowercased()) }
        }
        request.url = target
        return request
    }

    private static func validURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    private struct Origin: Equatable {
        let scheme: String?
        let host: String?
        let port: Int
    }

    private static func origin(_ url: URL) -> Origin {
        let scheme = url.scheme?.lowercased()
        return Origin(scheme: scheme, host: url.host?.lowercased(), port: url.port ?? (scheme == "https" ? 443 : 80))
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

        func check() throws {
            if isCancelled { throw URLError(.cancelled) }
        }
    }

    private final class Transfer {
        private static let maximumHeaderBytes = 64 * 1024
        private let cancellation: Cancellation
        private var headerBytes = 0
        private var limitExceeded: Int?
        private var status = 0
        private var headers: [String: String] = [:]
        private var body = Data()
        private(set) var redirectLocation: String?

        init(cancellation: Cancellation) {
            self.cancellation = cancellation
        }

        func perform(_ request: LookupHTTPRequest, proxy: CurlLookupProxy,
                     connectTimeoutMilliseconds: Int) throws -> LookupHTTPResponse {
            guard Self.isToken(request.method),
                  request.headers.allSatisfy({ Self.isToken($0.key) && Self.isHeaderValue($0.value) }) else {
                throw URLError(.badURL)
            }
            let lines = request.headers.map { name, value in
                strdup(value.isEmpty ? "\(name);" : "\(name): \(value)")
            }
            defer { lines.forEach { free($0) } }
            guard lines.allSatisfy({ $0 != nil }) else { throw URLError(.resourceUnavailable) }
            let headerPointers = lines.map { UnsafePointer($0) }
            let proxyAddress = proxy.address.flatMap { strdup($0) }
            let proxyUsername = proxy.username.flatMap { strdup($0) }
            let proxyPassword = proxy.password.flatMap { strdup($0) }
            defer {
                free(proxyAddress)
                free(proxyUsername)
                free(proxyPassword)
            }
            guard proxy.address == nil || proxyAddress != nil,
                  proxy.username == nil || proxyUsername != nil,
                  proxy.password == nil || proxyPassword != nil else { throw URLError(.resourceUnavailable) }
            let requestBody = request.body ?? Data()
            var responseStatus = 0
            var canTryNextProxy = false
            let code = request.url.absoluteString.withCString { url in
                request.method.withCString { method in
                    headerPointers.withUnsafeBufferPointer { headers in
                        requestBody.withUnsafeBytes { bytes in
                            var transfer = tagx_lookup_transfer(
                                url: url, method: method,
                                proxy: UnsafePointer(proxyAddress), proxy_username: UnsafePointer(proxyUsername),
                                proxy_password: UnsafePointer(proxyPassword), headers: headers.baseAddress,
                                header_count: headers.count,
                                body: bytes.bindMemory(to: UInt8.self).baseAddress, body_count: bytes.count,
                                has_body: request.body != nil, connect_timeout_ms: connectTimeoutMilliseconds,
                                context: Unmanaged.passUnretained(self).toOpaque(),
                                receive_header: { context, bytes, count in
                                    Unmanaged<Transfer>.fromOpaque(context!).takeUnretainedValue()
                                        .receiveHeader(bytes!, count: count)
                                },
                                receive_body: { context, bytes, count in
                                    Unmanaged<Transfer>.fromOpaque(context!).takeUnretainedValue()
                                        .receiveBody(bytes!, count: count)
                                },
                                is_cancelled: { context in
                                    Unmanaged<Transfer>.fromOpaque(context!).takeUnretainedValue()
                                        .cancellation.isCancelled
                                })
                            return tagx_lookup_perform(&transfer, &responseStatus, &canTryNextProxy)
                        }
                    }
                }
            }
            try cancellation.check()
            if let limitExceeded { throw LookupHTTPResponseTooLarge(maximumBytes: limitExceeded) }
            if redirectLocation == nil {
                if tagx_lookup_is_timeout(code), !canTryNextProxy { throw URLError(.timedOut) }
                guard code == 0 else { throw TransferError(code: code, canTryNextProxy: canTryNextProxy) }
            }
            return LookupHTTPResponse(statusCode: redirectLocation == nil ? responseStatus : status,
                                      headers: headers, body: body)
        }

        private func receiveHeader(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int {
            guard count <= Self.maximumHeaderBytes - headerBytes else {
                limitExceeded = Self.maximumHeaderBytes
                return 0
            }
            headerBytes += count
            let line = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            if line.hasPrefix("HTTP/") {
                let parts = line.split(separator: " ", maxSplits: 2)
                status = parts.count >= 2 ? Int(parts[1].trimmingCharacters(in: .newlines)) ?? 0 : 0
                headers.removeAll(keepingCapacity: true)
            } else if line == "\r\n" || line == "\n" {
                if redirectStatuses.contains(status), let location = headers["location"], !location.isEmpty {
                    redirectLocation = location
                    // libcurl liest ab hier keinen Zwischen-Body. Der Aufrufer entscheidet über das Ziel.
                    return 0
                }
            } else if let separator = line.firstIndex(of: ":") {
                let name = line[..<separator].lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[name] = value
            }
            return count
        }

        private func receiveBody(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int {
            let limit = URLSessionLookupClient.maximumResponseBytes
            guard count <= limit - body.count else {
                limitExceeded = limit
                return 0
            }
            body.append(bytes, count: count)
            return count
        }

        private static func isToken(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || "!#$%&'*+-.^`_|~".utf8.contains($0)
            }
        }

        private static func isHeaderValue(_ value: String) -> Bool {
            value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
        }
    }

    private struct TransferError: LocalizedError {
        let code: Int32
        let canTryNextProxy: Bool
        var errorDescription: String? { String(cString: tagx_lookup_error_description(code)) }
    }
}
