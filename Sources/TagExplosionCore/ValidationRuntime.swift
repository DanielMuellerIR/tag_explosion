import Foundation

/// Herstellerlaufzeiten sind an Betriebssystem UND Architektur gebunden.
/// Alte macOS-Manifeste ohne OS-Feld bleiben eindeutig macOS zugeordnet.
enum ValidationRuntime {
    static var operatingSystem: String {
        #if os(Linux)
        "linux"
        #else
        "macos"
        #endif
    }
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }
    static var target: String { operatingSystem + "-" + architecture }
    static func java(in package: URL) -> URL {
        package.appendingPathComponent(operatingSystem == "linux" ? "runtime/bin/java" : "runtime/Contents/Home/bin/java")
    }
}
