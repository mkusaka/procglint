import Foundation

public enum Permission: String, Sendable, Codable, CaseIterable {
    case observe, configure, terminate
    case forceKill = "force_kill"
    case includeSystem = "include_system"
    case includePaths = "include_paths"
    case includeCommandLines = "include_command_lines"
}

public struct PermissionSet: Sendable, Codable, Equatable, SetAlgebra, ExpressibleByArrayLiteral, Sequence {
    private var values: Set<Permission>

    public init(_ values: Set<Permission>) {
        self.values = values
    }

    public init(arrayLiteral elements: Permission...) {
        values = Set(elements)
    }

    public static let all = PermissionSet(Set(Permission.allCases))
    public var isEmpty: Bool {
        values.isEmpty
    }

    public func contains(_ permission: Permission) -> Bool {
        values.contains(permission)
    }

    public func intersection(_ other: Self) -> Self {
        Self(values.intersection(other.values))
    }

    public init() {
        values = []
    }

    public func union(_ other: Self) -> Self {
        Self(values.union(other.values))
    }

    public func symmetricDifference(_ other: Self) -> Self {
        Self(values.symmetricDifference(other.values))
    }

    public mutating func formUnion(_ other: Self) {
        values.formUnion(other.values)
    }

    public mutating func formIntersection(_ other: Self) {
        values.formIntersection(other.values)
    }

    public mutating func formSymmetricDifference(_ other: Self) {
        values.formSymmetricDifference(other.values)
    }

    @discardableResult public mutating func insert(_ permission: Permission) -> (inserted: Bool, memberAfterInsert: Permission) {
        values.insert(permission)
    }

    @discardableResult public mutating func remove(_ permission: Permission) -> Permission? {
        values.remove(permission)
    }

    @discardableResult public mutating func update(with permission: Permission) -> Permission? {
        values.update(with: permission)
    }

    public func makeIterator() -> Set<Permission>.Iterator {
        values.makeIterator()
    }

    public init(from decoder: any Decoder) throws {
        values = try Set([Permission](from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try values.sorted { $0.rawValue < $1.rawValue }.encode(to: encoder)
    }
}

public struct AccessScope: Sendable, Codable, Hashable {
    public var includeSystem: Bool
    public var includePaths: Bool
    public var includeCommandLines: Bool

    public init(includeSystem: Bool = false, includePaths: Bool = false, includeCommandLines: Bool = false) {
        self.includeSystem = includeSystem
        self.includePaths = includePaths
        self.includeCommandLines = includeCommandLines
    }

    public init(permissions: PermissionSet) {
        self.init(includeSystem: permissions.contains(.includeSystem), includePaths: permissions.contains(.includePaths),
                  includeCommandLines: permissions.contains(.includeCommandLines))
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(includeSystem: values.decode(Bool.self, forKey: .includeSystem),
                      includePaths: values.decode(Bool.self, forKey: .includePaths),
                      includeCommandLines: values.decodeIfPresent(Bool.self, forKey: .includeCommandLines) ?? false)
    }
}

public enum ClientKind: String, Sendable, Codable, CaseIterable { case gui, mcp, cli }
