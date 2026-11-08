import Foundation
import ProcglintCore

/// The only dynamically shaped JSON in the protocol; dictionary keys retain their wire spelling.
enum JSONValue: Sendable, Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = try .array(container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        // Foundation accepts trailing commas even with JSON5 disabled; JSON-RPC requires strict JSON.
        var quoted = false
        var escaped = false
        var previous: UInt8?
        guard String(data: data, encoding: .utf8) != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected UTF-8"))
        }
        for byte in data {
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    quoted = false
                }
            } else {
                if byte == 93 || byte == 125, previous == 44 {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Trailing comma"))
                }
                if byte == 34 {
                    quoted = true
                }
            }
            if ![9, 10, 13, 32].contains(byte) {
                previous = byte
            }
        }
        return try ProcglintJSON.decoder().decode(Self.self, from: data)
    }

    static func encoded(_ value: some Encodable) throws -> JSONValue {
        try ProcglintJSON.decoder().decode(Self.self, from: ProcglintJSON.encoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ProcglintJSON.decoder().decode(type, from: ProcglintJSON.encoder().encode(self))
    }

    func text() throws -> String {
        guard let text = try String(bytes: ProcglintJSON.encoder().encode(self), encoding: .utf8) else {
            throw AgentError.internalError("JSON encoding was not UTF-8")
        }
        return text
    }

    var object: [String: JSONValue]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    subscript(_ key: String) -> JSONValue? {
        object?[key]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(integerLiteral value: Int) {
        self = .number(Decimal(value))
    }

    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
