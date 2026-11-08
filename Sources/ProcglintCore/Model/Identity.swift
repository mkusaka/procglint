import Foundation

public struct ProcessIdentity: Sendable, Codable, Hashable {
    public let bootSessionID: String
    public let pid: Int32
    @JSONString public private(set) var startTimeUS: UInt64

    public init(bootSessionID: String, pid: Int32, startTimeUS: UInt64) throws {
        guard !bootSessionID.isEmpty,
              bootSessionID.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 }),
              pid >= 0
        else { throw AgentError.invalidProcessKey("Invalid process identity") }
        self.bootSessionID = bootSessionID
        self.pid = pid
        self.startTimeUS = startTimeUS
    }

    enum CodingKeys: String, CodingKey {
        case bootSessionID = "bootSessionId"
        case pid
        case startTimeUS = "startTimeUs"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bootSessionID: container.decode(String.self, forKey: .bootSessionID),
            pid: container.decode(Int32.self, forKey: .pid),
            startTimeUS: container.decode(JSONString<UInt64>.self, forKey: .startTimeUS).wrappedValue
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bootSessionID)
        hasher.combine(pid)
        hasher.combine(startTimeUS)
    }
}

public struct ProcessKey: Sendable, Codable, Hashable, CustomStringConvertible {
    public let identity: ProcessIdentity
    public var rawValue: String {
        "p1.\(identity.bootSessionID).\(identity.pid).\(identity.startTimeUS)"
    }

    public var description: String {
        rawValue
    }

    public init(identity: ProcessIdentity) {
        self.identity = identity
    }

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "p1",
              !parts[2].isEmpty, parts[2].utf8.allSatisfy({ (48 ... 57).contains($0) }),
              !parts[3].isEmpty, parts[3].utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let pid = Int32(parts[2]), let startTimeUS = UInt64(parts[3])
        else { throw AgentError.invalidProcessKey("Malformed process_key") }
        identity = try ProcessIdentity(bootSessionID: String(parts[1]), pid: pid, startTimeUS: startTimeUS)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
