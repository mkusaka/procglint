import Darwin
import Foundation
import Synchronization

private struct UsageError: Error {}

private let usage = """
Usage: procglint-workload spawn --count N
       procglint-workload cpu --threads T --seconds S
       procglint-workload memory --mib M
       procglint-workload disk --mib M
       procglint-workload churn --rate R --seconds S
Memory and spawn hold until SIGINT/SIGTERM. Disk writes, fsyncs and reads a temporary file.
"""

private final class Stop: Sendable {
    private let state = Mutex(false)
    let event = DispatchSemaphore(value: 0)
    var requested: Bool {
        state.withLock { $0 }
    }

    func request() {
        state.withLock { $0 = true }
        event.signal()
    }
}

private func options(_ arguments: [String], names: Set<String>) throws -> [String: Int] {
    guard arguments.count == names.count * 2 else { throw UsageError() }
    var values: [String: Int] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let name = arguments[index]
        guard names.contains(name), values[name] == nil,
              let value = Int(arguments[index + 1]), (1 ... 1_000_000).contains(value)
        else { throw UsageError() }
        values[name] = value
    }
    return values
}

private func child(parent: Int32) throws -> Process {
    let process = Process()
    guard let executable = Bundle.main.executableURL else { throw POSIXError(.ENOENT) }
    process.executableURL = executable
    process.arguments = ["--idle-child", String(parent)]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    return process
}

private func spawn(count: Int, stop: Stop) throws {
    var children: [Process] = []
    defer {
        for child in children where child.isRunning {
            child.terminate()
        }
        for child in children {
            child.waitUntilExit()
        }
    }
    for _ in 0 ..< count {
        if stop.requested {
            return
        }
        try children.append(child(parent: getpid()))
    }
    print("Ready: \(children.count) idle children, parent \(getpid())")
    fflush(stdout)
    stop.event.wait()
}

private func cpu(threads: Int, seconds: Int, stop: Stop) {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
    let checksum = Mutex<UInt64>(0)
    let group = DispatchGroup()
    for index in 0 ..< threads {
        group.enter()
        // Dedicated threads honor --threads even when GCD would serialize a small iteration count.
        Thread.detachNewThread {
            defer { group.leave() }
            var value = UInt64(index + 1)
            while !stop.requested, DispatchTime.now().uptimeNanoseconds < deadline {
                for _ in 0 ..< 100_000 {
                    value = value &* 1_664_525 &+ 1_013_904_223
                }
            }
            checksum.withLock { $0 &+= value }
        }
    }
    group.wait()
    print("CPU checksum: \(checksum.withLock { $0 })")
}

private func memory(mib: Int, stop: Stop) throws {
    let size = mib * 1024 * 1024
    guard let address = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), address != MAP_FAILED else {
        throw POSIXError(.ENOMEM)
    }
    defer { munmap(address, size) }
    memset(address, 1, size)
    print("Ready: \(mib) MiB touched, pid \(getpid())")
    fflush(stdout)
    stop.event.wait()
}

private func disk(mib: Int, stop: Stop) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-workload-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw POSIXError(.EIO) }
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try FileHandle(forUpdating: url)
    defer { try? file.close() }
    let block = Data(repeating: 1, count: 1024 * 1024)
    for _ in 0 ..< mib {
        if stop.requested {
            return
        }
        try file.write(contentsOf: block)
    }
    try file.synchronize()
    try file.seek(toOffset: 0)
    var read = 0
    while !stop.requested, let data = try file.read(upToCount: block.count), !data.isEmpty {
        read += data.count
    }
    guard stop.requested || read == mib * block.count else { throw POSIXError(.EIO) }
    print("Disk: wrote and read \(read) bytes (filesystem cache may satisfy reads)")
}

private func churn(rate: Int, seconds: Int, stop: Stop) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = start + UInt64(seconds) * 1_000_000_000
    var count = 0
    var children: Set<Int32> = []
    defer {
        for pid in children {
            kill(pid, SIGTERM)
        }
        for pid in children {
            while waitpid(pid, nil, 0) < 0, errno == EINTR {}
        }
    }
    guard let argument = strdup("true") else { throw POSIXError(.ENOMEM) }
    defer { free(argument) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    while !stop.requested, DispatchTime.now().uptimeNanoseconds < deadline {
        var pid: Int32 = 0
        let error = posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, &environment)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        children.insert(pid)
        count += 1
        var status: Int32 = 0
        while true {
            let exited = waitpid(-1, &status, WNOHANG)
            if exited <= 0 {
                break
            }
            children.remove(exited)
            guard status == 0 else { throw POSIXError(.ECHILD) }
        }
        let next = start + UInt64(Double(count) / Double(rate) * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        if next > now {
            _ = stop.event.wait(timeout: .now() + .nanoseconds(Int(next - now)))
        }
    }
    // Wait directly: Foundation's waitUntilExit adds run-loop latency that caps high churn rates.
    for pid in Array(children) {
        var status: Int32 = 0
        var result: Int32
        repeat {
            result = waitpid(pid, &status, 0)
        } while result < 0 && errno == EINTR
        children.remove(pid)
        guard result == pid, status == 0 else {
            throw POSIXError(.ECHILD)
        }
    }
    children.removeAll()
    print("Churn: \(count) exits in \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000) s; requested \(rate)/s")
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print(usage); return
    }
    let stop = Stop()
    let signals = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stop.request() }
        source.resume()
        return source
    }
    defer { for source in signals {
        source.cancel()
    } }
    if arguments.count == 2, arguments[0] == "--idle-child", let parent = Int32(arguments[1]), parent > 1 {
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        source.setEventHandler { stop.request() }
        source.resume()
        defer { source.cancel() }
        if getppid() == parent {
            stop.event.wait()
        }
        return
    }
    guard let command = arguments.first else { throw UsageError() }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "spawn": try spawn(count: options(rest, names: ["--count"])["--count"]!, stop: stop)
    case "cpu":
        let values = try options(rest, names: ["--threads", "--seconds"])
        guard values["--threads"]! <= 256 else { throw UsageError() }
        cpu(threads: values["--threads"]!, seconds: values["--seconds"]!, stop: stop)
    case "memory": try memory(mib: options(rest, names: ["--mib"])["--mib"]!, stop: stop)
    case "disk": try disk(mib: options(rest, names: ["--mib"])["--mib"]!, stop: stop)
    case "churn":
        let values = try options(rest, names: ["--rate", "--seconds"])
        try churn(rate: values["--rate"]!, seconds: values["--seconds"]!, stop: stop)
    default: throw UsageError()
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8))
    exit(64)
}
