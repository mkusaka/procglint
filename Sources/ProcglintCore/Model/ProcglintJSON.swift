import Foundation

public enum ProcglintJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard value.contains(".") else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected fractional seconds")
            }
            do {
                return try Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
            } catch {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a fractional ISO8601 date")
            }
        }
        return decoder
    }
}

/// Property wrappers keep the Swift API numeric while making precision explicit on the wire.
@propertyWrapper
public struct JSONString<Value: FixedWidthInteger & Codable & Sendable>: Sendable, Codable, Equatable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard !string.isEmpty, string.utf8.allSatisfy({ (48 ... 57).contains($0) }), let value = Value(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an unsigned decimal integer string")
        }
        wrappedValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(wrappedValue))
    }
}

@propertyWrapper
public struct OptionalJSONString<Value: FixedWidthInteger & Codable & Sendable>: Sendable, Codable, Equatable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decodeNil() ? nil : JSONString<Value>(from: decoder).wrappedValue
    }

    public func encode(to encoder: any Encoder) throws {
        guard let wrappedValue else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
            return
        }
        try JSONString(wrappedValue: wrappedValue).encode(to: encoder)
    }
}

public extension KeyedDecodingContainer {
    func decode<T>(_ type: OptionalJSONString<T>.Type, forKey key: Key) throws -> OptionalJSONString<T> {
        try decodeIfPresent(type, forKey: key) ?? OptionalJSONString(wrappedValue: nil)
    }
}

@propertyWrapper
public struct JSONStringCounts: Sendable, Codable, Equatable {
    public var wrappedValue: [String: UInt64]

    public init(wrappedValue: [String: UInt64]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode([String: JSONString<UInt64>].self).mapValues(\.wrappedValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.mapValues { JSONString(wrappedValue: $0) })
    }
}
