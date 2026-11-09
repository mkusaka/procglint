import Foundation

public struct ProcessCommandLine: Sendable, Codable, Equatable {
    public let value: [String]?
    public let status: MetricStatus
    public let truncated: Bool
    private enum CodingKeys: String, CodingKey { case value, status, truncated }

    public init(arguments: [String], truncated: Bool = false) {
        let redacted = CommandLineRedactor.redact(Array(arguments.prefix(64)))
        var remaining = 16 * 1024
        var values: [String] = []
        var cut = truncated || arguments.count > 64
        for argument in redacted {
            let limit = min(4096, remaining)
            var bytes = Array(argument.utf8.prefix(limit))
            while String(bytes: bytes, encoding: .utf8) == nil {
                bytes.removeLast()
            }
            let text = String(bytes: bytes, encoding: .utf8) ?? ""
            cut = cut || text.utf8.count != argument.utf8.count
            values.append(text)
            remaining -= bytes.count
            if remaining == 0 {
                cut = cut || values.count < redacted.count
                break
            }
        }
        value = values
        status = .ok
        self.truncated = cut
    }

    public init(unavailable status: MetricStatus) {
        precondition(status != .ok)
        value = nil
        self.status = status
        truncated = false
    }

    public var displayText: String {
        guard let value else { return "— (\(status.rawValue))" }
        let text = value.map { argument in
            let escaped = argument.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            return escaped.isEmpty || escaped.contains(where: { $0.isWhitespace || $0 == "'" })
                ? "'" + escaped.replacingOccurrences(of: "'", with: "'\\''") + "'" : escaped
        }.joined(separator: " ")
        return text + (truncated ? " [truncated]" : "")
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let status = try fields.decode(MetricStatus.self, forKey: .status)
        let value = try fields.decodeIfPresent([String].self, forKey: .value)
        guard (status == .ok) == (value != nil) else { throw AgentError.invalidArgument("Invalid command-line status") }
        if let value {
            try self.init(arguments: value, truncated: fields.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        } else {
            self.init(unavailable: status)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(value, forKey: .value)
        try fields.encode(status, forKey: .status)
        try fields.encode(truncated, forKey: .truncated)
    }
}

public struct WorkingDirectory: Sendable, Codable, Equatable {
    public let value: String?
    public let status: MetricStatus
    private enum CodingKeys: String, CodingKey { case value, status }

    public init(value: String) {
        self.value = value
        status = .ok
    }

    public init(unavailable status: MetricStatus) {
        precondition(status != .ok)
        value = nil
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let status = try fields.decode(MetricStatus.self, forKey: .status)
        let value = try fields.decodeIfPresent(String.self, forKey: .value)
        guard (status == .ok) == (value != nil) else { throw AgentError.invalidArgument("Invalid cwd status") }
        if let value {
            self.init(value: value)
        } else {
            self.init(unavailable: status)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(value, forKey: .value)
        try fields.encode(status, forKey: .status)
    }
}

public struct ProcessAncestor: Sendable, Codable, Equatable {
    public var pid: Int32
    public var name: String
    public var processKey: ProcessKey?
    public var commandLine: ProcessCommandLine?

    public init(pid: Int32, name: String, processKey: ProcessKey? = nil, commandLine: ProcessCommandLine? = nil) {
        self.pid = pid
        self.name = name
        self.processKey = processKey
        self.commandLine = commandLine
    }
}

public extension ProcessSample {
    mutating func hideCommandLines() {
        commandLine = nil
        cwd = nil
        if let ancestors {
            self.ancestors = ancestors.map {
                var ancestor = $0
                ancestor.commandLine = nil
                return ancestor
            }
        }
    }

    mutating func addLineage(from census: [ProcessSample]) {
        let byPID = Dictionary(census.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [ProcessAncestor] = []
        var visited: Set<Int32> = [pid]
        var parent = ppid
        var complete = pid == 1
        while !complete, chain.count < 64, let next = parent, next > 0,
              visited.insert(next).inserted, let sample = byPID[next], sample.status != .exited
        {
            chain.append(ProcessAncestor(pid: next, name: sample.name, processKey: sample.processKey))
            complete = next == 1
            parent = sample.ppid
        }
        ancestors = chain
        ancestorsIncomplete = !complete
        childrenCount = census.filter { $0.ppid == pid && $0.status != .exited }.count
    }
}

/// The optional OS seam keeps legacy ProcessSource implementations source compatible.
public protocol ProcessLaunchSource: ProcessSource {
    func commandLine(pid: Int32) throws -> ProcessCommandLine
    func workingDirectory(pid: Int32) throws -> WorkingDirectory
}
