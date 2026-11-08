import Darwin
import Foundation
import Synchronization

/// Mutable framing state is confined to the dedicated reader queue.
final class MCPLineReader: @unchecked Sendable {
    private let input: FileHandle
    private let queue = DispatchQueue(label: "procglint.mcp.input")
    private var chunk = Data()
    private var position = 0
    private var ended = false

    init(input: FileHandle) {
        self.input = input
    }

    func next() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readLine()) }
        }
    }

    private func readLine() -> Data? {
        var line = Data()
        var oversized = false
        while true {
            if position == chunk.count {
                guard !ended else { return oversized || !line.isEmpty ? line : nil }
                // FileHandle.read(upToCount:) can wait to fill the buffer on pipes, delaying small requests.
                chunk = Data(count: 8192)
                var count: Int
                repeat {
                    count = chunk.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
                } while count < 0 && errno == EINTR
                guard count >= 0 else {
                    ended = true; return nil
                }
                chunk.removeLast(chunk.count - count)
                position = 0
                if chunk.isEmpty {
                    ended = true; continue
                }
            }
            let byte = chunk[position]
            position += 1
            if byte == 10 {
                return line
            }
            if !oversized {
                line.append(byte)
                if line.count > MCPServer.maximumInputBytes {
                    oversized = true
                }
            }
        }
    }
}

/// Blocking writes happen only on this queue, never on a Swift executor or while holding agent state.
final class MCPLineWriter: Sendable {
    private struct State {
        var pending = 0
        var failed = false
        var capacityWaiters: [CheckedContinuation<Void, Never>] = []
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let output: FileHandle
    private let queue = DispatchQueue(label: "procglint.mcp.output")

    init(output: FileHandle) {
        self.output = output
    }

    var failed: Bool {
        state.withLock { $0.failed }
    }

    var pendingCount: Int {
        state.withLock { $0.pending }
    }

    func enqueue(_ line: String) {
        state.withLock { $0.pending += 1 }
        queue.async {
            do { try self.output.write(contentsOf: Data((line + "\n").utf8)) }
            catch { self.state.withLock { $0.failed = true } }
            let waiters = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.pending -= 1
                var ready: [CheckedContinuation<Void, Never>] = []
                if state.pending < 4 || state.failed {
                    ready += state.capacityWaiters
                    state.capacityWaiters.removeAll()
                }
                if state.pending == 0 {
                    ready += state.drainWaiters
                    state.drainWaiters.removeAll()
                }
                return ready
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitForCapacity() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.pending < 4 || state.failed {
                    return true
                }
                state.capacityWaiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.pending == 0 {
                    return true
                }
                state.drainWaiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }
}
