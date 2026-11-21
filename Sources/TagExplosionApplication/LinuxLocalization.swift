#if os(Linux)
import Foundation

private enum LinuxLanguage {
    static let language = resolve(ProcessInfo.processInfo.environment)

    static func resolve(_ environment: [String: String]) -> String {
        func supported(_ locale: String) -> String? {
            let code = locale.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix { !"_-.@".contains($0) }.lowercased()
            return ["de", "en"].contains(code) ? code : nil
        }
        if let chosen = environment["TAGX_DESKTOP_LANGUAGE"], let language = supported(chosen) {
            return language
        }
        if let preferred = environment["LANGUAGE"] {
            for locale in preferred.split(separator: ":") {
                if let language = supported(String(locale)) { return language }
            }
        }
        let locale = ["LC_ALL", "LC_MESSAGES", "LANG"].lazy.compactMap { environment[$0] }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return locale.flatMap(supported) ?? "en"
    }
}

/// SwiftUI liefert diese Katalogauflösung auf macOS. Linux verwendet denselben
/// Katalog einschließlich der Formatargumente, ohne Apple-Frameworks zu laden.
struct ApplicationLocalizedString: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [CVarArg]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [CVarArg] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) {
            if let integer = value as? Int { key += "%lld"; arguments.append(Int64(integer)) }
            else if let integer = value as? Int64 { key += "%lld"; arguments.append(integer) }
            else if let number = value as? Double { key += "%f"; arguments.append(number) }
            else { key += "%@"; arguments.append(String(describing: value)) }
        }
    }
}
extension String {
    init(localized value: ApplicationLocalizedString) {
        let text = LinuxLanguage.language == "de" ? value.key : ApplicationTranslations.english[value.key] ?? value.key
        self = String(format: text, arguments: value.arguments)
    }
}
#endif
