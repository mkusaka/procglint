import CProcglintDarwin
import Darwin
import Foundation

public enum ProcessArguments {
    /// KERN_PROCARGS2 is argc, executable path, NUL padding, then exactly argc argv strings; the rest is private.
    public static func parse(_ data: Data) -> ProcessCommandLine {
        data.withUnsafeBytes { parse($0) }
    }

    public static func parse(_ buffer: UnsafeRawBufferPointer) -> ProcessCommandLine {
        guard buffer.count > MemoryLayout<Int32>.size else { return ProcessCommandLine(unavailable: .unsupported) }
        let argc = Int(buffer.loadUnaligned(as: Int32.self))
        guard argc > 0, argc <= buffer.count - MemoryLayout<Int32>.size else { return ProcessCommandLine(unavailable: .unsupported) }
        var offset = MemoryLayout<Int32>.size
        func readString() -> String? {
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 {
                offset += 1
            }
            guard offset < buffer.count else { return nil }
            let value = String(bytes: buffer[start ..< offset], encoding: .utf8)
            offset += 1
            return value
        }
        guard let executable = readString(), !executable.isEmpty else { return ProcessCommandLine(unavailable: .unsupported) }
        while offset < buffer.count, buffer[offset] == 0 {
            offset += 1
        }
        var arguments: [String] = []
        for _ in 0 ..< argc {
            guard let argument = readString() else { return ProcessCommandLine(unavailable: .unsupported) }
            if arguments.count < 64 {
                arguments.append(argument)
            }
        }
        return ProcessCommandLine(arguments: arguments, truncated: argc > 64)
    }
}

extension DarwinProcessSource: ProcessLaunchSource {
    public func commandLine(pid: Int32) throws -> ProcessCommandLine {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &maximum, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size, maximum > 0, maximum <= 1024 * 1024
        else { return ProcessCommandLine(unavailable: .unsupported) }
        var buffer = Data(count: Int(maximum))
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        let result = buffer.withUnsafeMutableBytes { bytes in sysctl(&mib, 3, bytes.baseAddress, &size, nil, 0) }
        if result != 0 {
            let error = errno
            // KERN_PROCARGS2 can report EINVAL for a vanished PID; verify before classifying it.
            if error == EINVAL {
                do {
                    if try bsdInfo(pid: pid) == nil {
                        return ProcessCommandLine(unavailable: .exited)
                    }
                } catch ProcessSourceError.exited { return ProcessCommandLine(unavailable: .exited) }
                catch ProcessSourceError.permissionDenied { return ProcessCommandLine(unavailable: .permissionDenied) }
                catch { return ProcessCommandLine(unavailable: .unsupported) }
            }
            return ProcessCommandLine(unavailable: Self.launchStatus(error))
        }
        guard size <= buffer.count else { return ProcessCommandLine(unavailable: .unsupported) }
        buffer.count = size
        return ProcessArguments.parse(buffer)
    }

    public func workingDirectory(pid: Int32) throws -> WorkingDirectory {
        var path = [CChar](repeating: 0, count: 4096)
        let error = pg_cwd(pid, &path, UInt32(path.count))
        guard error == 0 else { return WorkingDirectory(unavailable: Self.launchStatus(error)) }
        guard let value = String(bytes: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8), !value.isEmpty
        else { return WorkingDirectory(unavailable: .unsupported) }
        return WorkingDirectory(value: value)
    }

    private static func launchStatus(_ error: Int32) -> MetricStatus {
        switch error {
        case EPERM, EACCES: .permissionDenied
        case ESRCH, ENOENT: .exited
        default: .unsupported
        }
    }
}
