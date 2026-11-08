import Foundation

/// Ausschließlich JSON-Werte an der Prozessgrenze; keine dynamischen Foundation-Objekte.
public enum DesktopValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([DesktopValue]), object([String: DesktopValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode([DesktopValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: DesktopValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .object(let result): try value.encode(result)
        }
    }

    public static func encoding<T: Encodable>(_ value: T) throws -> Self {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }

    public subscript(_ key: String) -> DesktopValue { if case .object(let value) = self { value[key] ?? .null } else { .null } }
    public var text: String? { if case .string(let value) = self { value } else { nil } }
    public var flag: Bool { if case .bool(let value) = self { value } else { false } }
    public var values: [DesktopValue] { if case .array(let value) = self { value } else { [] } }
    public var fields: [String: DesktopValue] { if case .object(let value) = self { value } else { [:] } }
    public var integer: Int? {
        guard case .number(let value) = self, value.isFinite,
              value >= Double(Int.min), value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
}

public struct DesktopRequest: Codable, Sendable {
    public let id: UInt64
    public let session: String
    public let method: String
    public let params: DesktopValue

    public init(id: UInt64, session: String = "main", method: String, params: DesktopValue = .object([:])) {
        self.id = id; self.session = session; self.method = method; self.params = params
    }
}

public struct DesktopFailure: Codable, Sendable, Error {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public struct DesktopResponse: Codable, Sendable {
    public let id: UInt64
    public let result: DesktopValue?
    public let error: DesktopFailure?
}

/// Begrenzung vor dem Aufbau einer vollständigen Eingabezeile. Auch eine Zeile
/// ohne abschließendes LF darf keinen unbegrenzten Speicherverbrauch verursachen.
public struct DesktopFramer: Sendable {
    public static let maximumBytes = 24 * 1024 * 1024
    private var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 10 {
            let slice = data[start..<index]
            guard pending.count + slice.count <= Self.maximumBytes else { throw DesktopFailure("message_too_large", "IPC message exceeds its size limit") }
            pending.append(slice)
            if !pending.isEmpty { lines.append(pending) }
            pending = Data()
            start = data.index(after: index)
        }
        let tail = data[start...]
        guard pending.count + tail.count <= Self.maximumBytes else { throw DesktopFailure("message_too_large", "IPC message exceeds its size limit") }
        pending.append(tail)
        return lines
    }
}
