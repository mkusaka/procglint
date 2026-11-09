import Foundation
import ProcglintCore

public struct MCPFlags: Sendable, Equatable {
    public var permissions: PermissionSet
    public var help: Bool

    public init(permissions: PermissionSet = [], help: Bool = false) {
        self.permissions = permissions
        self.help = help
    }

    /// The executable should print usage to stderr and exit 0 for help, or exit 2 on a parse error.
    public static func parse(_ arguments: [String]) throws -> Self {
        var flags = Self()
        for argument in arguments {
            switch argument {
            case "--allow-observe": flags.permissions.insert(.observe)
            case "--allow-configure": flags.permissions.insert(.configure)
            case "--allow-terminate": flags.permissions.insert(.terminate)
            case "--allow-force-kill": flags.permissions.insert(.forceKill)
            case "--include-system": flags.permissions.insert(.includeSystem)
            case "--include-paths": flags.permissions.insert(.includePaths)
            case "--include-command-lines": flags.permissions.insert(.includeCommandLines)
            case "--help": flags.help = true
            default: throw MCPFlagError(argument: argument)
            }
        }
        return flags
    }

    public static let usage = """
    Usage: procglint-mcp [--allow-observe] [--allow-configure] [--allow-terminate]
                         [--allow-force-kill] [--include-system] [--include-paths]
                         [--include-command-lines] [--help]
    Default: read-only, own processes, no paths or command lines. Force kill also requires --allow-terminate.
    """
}

public struct MCPFlagError: Error, Sendable, LocalizedError {
    public let argument: String
    public var errorDescription: String? {
        "Unknown flag: \(argument)\n\(MCPFlags.usage)"
    }
}
