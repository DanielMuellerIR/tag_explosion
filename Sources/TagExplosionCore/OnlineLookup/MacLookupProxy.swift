#if os(macOS)
import CFNetwork
import Foundation

enum MacLookupProxy {
    enum Failure: LocalizedError, Equatable {
        case unavailable
        case timedOut
        case requiresSystemTransport

        var errorDescription: String? {
            switch self {
            case .unavailable, .requiresSystemTransport: "The system proxy route for the online lookup could not be determined."
            case .timedOut: "Determining the system proxy route for the online lookup timed out."
            }
        }
    }

    static func systemRoutes(for url: URL, isCancelled: @Sendable () -> Bool) throws -> [CurlLookupProxy] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            throw Failure.unavailable
        }
        return try routes(for: url, settings: settings, useSystemTransport: true, isCancelled: isCancelled)
    }

    static func routes(for url: URL, settings: [String: Any], timeout: Duration = .seconds(10),
                       useSystemTransport: Bool = false, isCancelled: () -> Bool) throws -> [CurlLookupProxy] {
        guard !isCancelled() else { throw URLError(.cancelled) }
        let entries = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary).takeRetainedValue()
        guard let candidates = entries as? [[String: Any]], !candidates.isEmpty else { throw Failure.unavailable }
        if let automatic = candidates.first(where: { proxyType($0) == kCFProxyTypeAutoConfigurationURL as String
            || proxyType($0) == kCFProxyTypeAutoConfigurationJavaScript as String }) {
            // DIRECT hinter dem PAC-Platzhalter ist eine CFNetwork-Vorgabe.
            // Nur das ausgewertete Skript darf eine direkte Route freigeben.
            let resolved = try evaluate(automatic, target: url, timeout: timeout, isCancelled: isCancelled)
            return try resolved.map(route)
        }
        let autoConfigured = settings[kCFNetworkProxiesProxyAutoConfigEnable as String] as? NSNumber
        let autoDiscovered = settings[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? NSNumber
        guard autoConfigured?.boolValue != true, autoDiscovered?.boolValue != true else {
            // Ohne PAC-Platzhalter lässt CFNetwork nicht erkennen, ob WPAD
            // noch aussteht oder DIRECT eine konfigurierte Ausnahme ist.
            // URLSession löst dieses Ziel mit der vollständigen Systemlogik.
            throw useSystemTransport ? Failure.requiresSystemTransport : Failure.unavailable
        }
        return try candidates.map(route)
    }

    private static func proxyType(_ entry: [String: Any]) -> String? {
        entry[kCFProxyTypeKey as String] as? String
    }

    private static func route(_ entry: [String: Any]) throws -> CurlLookupProxy {
        let type = proxyType(entry)
        if type == kCFProxyTypeNone as String { return CurlLookupProxy(address: "") }
        let scheme: String
        if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String {
            // CFNetwork bezeichnet auch einen HTTP-CONNECT-Proxy für HTTPS so.
            scheme = "http"
        } else if type == kCFProxyTypeSOCKS as String {
            let version = entry[kCFStreamPropertySOCKSVersion as String] as? String
            scheme = version == kCFStreamSocketSOCKSVersion4 as String ? "socks4a" : "socks5h"
        } else {
            throw Failure.unavailable
        }
        guard let host = entry[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
              let port = entry[kCFProxyPortNumberKey as String] as? Int, (1...65535).contains(port) else {
            throw Failure.unavailable
        }
        var address = URLComponents()
        address.scheme = scheme
        address.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        address.port = port
        guard let proxyURL = address.string else { throw Failure.unavailable }
        let username = entry[kCFProxyUsernameKey as String] as? String
        let password = entry[kCFProxyPasswordKey as String] as? String
        guard username?.utf8.contains(0) != true, password?.utf8.contains(0) != true else {
            throw Failure.unavailable
        }
        return CurlLookupProxy(address: proxyURL, username: username, password: password)
    }

    private final class Evaluation {
        var finished = false
        var proxies: [[String: Any]]?
    }

    private static func evaluate(_ entry: [String: Any], target: URL, timeout: Duration,
                                 isCancelled: () -> Bool) throws -> [[String: Any]] {
        let evaluation = Evaluation()
        var context = CFStreamClientContext(
            version: 0, info: Unmanaged.passUnretained(evaluation).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return Unmanaged<Evaluation>.fromOpaque(info).retain().toOpaque()
            },
            release: { info in
                if let info { Unmanaged<Evaluation>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let completion: CFProxyAutoConfigurationResultCallback = { info, proxies, error in
            let evaluation = Unmanaged<Evaluation>.fromOpaque(info).takeUnretainedValue()
            evaluation.proxies = error == nil ? proxies as? [[String: Any]] : nil
            evaluation.finished = true
        }
        let source: CFRunLoopSource
        if let pacURL = entry[kCFProxyAutoConfigurationURLKey as String] as? URL {
            source = CFNetworkExecuteProxyAutoConfigurationURL(pacURL as CFURL, target as CFURL, completion, &context)
        } else if let script = entry[kCFProxyAutoConfigurationJavaScriptKey as String] as? String {
            source = CFNetworkExecuteProxyAutoConfigurationScript(script as CFString, target as CFURL, completion, &context)
        } else {
            throw Failure.unavailable
        }
        defer { CFRunLoopSourceInvalidate(source) }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        let deadline = ContinuousClock.now + timeout
        while !evaluation.finished {
            guard !isCancelled() else { throw URLError(.cancelled) }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        guard let proxies = evaluation.proxies, !proxies.isEmpty else { throw Failure.unavailable }
        return proxies
    }
}
#endif
