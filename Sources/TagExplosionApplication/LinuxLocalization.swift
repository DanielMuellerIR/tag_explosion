#if os(Linux)
import Foundation

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
        let language = ProcessInfo.processInfo.environment["LANGUAGE"] ?? ProcessInfo.processInfo.environment["LANG"] ?? "en"
        let text = language.lowercased().hasPrefix("de") ? value.key : ApplicationTranslations.english[value.key] ?? value.key
        self = String(format: text, arguments: value.arguments)
    }
}
#endif
