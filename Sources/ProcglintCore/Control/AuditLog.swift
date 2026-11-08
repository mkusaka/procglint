import Darwin
import Foundation
import Synchronization

public final class AuditLog: Sendable {
    private static let maximumSize = 1024 * 1024
    private let url: URL
    private let lock = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    public func append(_ entry: AuditEntry) throws {
        try appendLine(ProcglintJSON.encoder().encode(entry))
    }

    /// An unrecognized token has no target; do not invent a process identity for the audit.
    func appendUnresolvedTermination(timestamp: Date, clientKind: ClientKind, clientPID: Int32,
                                     rejection: TerminationRejection) throws
    {
        try appendLine(ProcglintJSON.encoder().encode(UnresolvedTermination(
            timestamp: timestamp, clientKind: clientKind, clientPID: clientPID, rejection: rejection
        )))
    }

    private func appendLine(_ data: Data) throws {
        guard url.isFileURL else { throw AgentError.invalidArgument("Audit log requires a file URL") }
        var line = data
        line.append(0x0A)
        guard line.count <= Self.maximumSize else {
            throw AgentError.invalidArgument("Audit entry exceeds 1 MiB")
        }
        try lock.withLock { _ in
            let directoryURL = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let directory = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw posixError() }
            defer { _ = Darwin.close(directory) }
            guard fchmod(directory, 0o700) == 0 else { throw posixError() }

            var handle = try openFile(in: directory)
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw posixError() }
            if info.st_size > Self.maximumSize - line.count {
                try handle.close()
                guard renameat(directory, url.lastPathComponent, directory, "audit.1.jsonl") == 0 else {
                    throw posixError()
                }
                handle = try openFile(in: directory)
            }
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()
        }
    }

    private func openFile(in directory: Int32) throws -> FileHandle {
        let descriptor = openat(directory, url.lastPathComponent, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        return handle
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private struct UnresolvedTermination: Encodable {
        let timestamp: Date
        let clientKind: ClientKind
        let clientPID: Int32
        let rejection: TerminationRejection

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: AuditEntry.CodingKeys.self)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(clientKind, forKey: .clientKind)
            try container.encode(clientPID, forKey: .clientPID)
            try container.encode("rejected", forKey: .outcome)
            try container.encode(rejection, forKey: .rejection)
            for key in [AuditEntry.CodingKeys.processKey, .pid, .name, .signal] {
                try container.encodeNil(forKey: key)
            }
        }
    }
}
