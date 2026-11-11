import Foundation

public struct NetworkBytes: Sendable, Equatable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64 = 0, sent: UInt64 = 0) {
        self.received = received
        self.sent = sent
    }

    mutating func add(_ other: NetworkBytes) {
        received = received.addingReportingOverflow(other.received).overflow ? UInt64.max : received + other.received
        sent = sent.addingReportingOverflow(other.sent).overflow ? UInt64.max : sent + other.sent
    }
}

public struct NetworkProcess: Sendable, Hashable {
    public var pid: Int32
    public var startTimeUS: UInt64

    public init(pid: Int32, startTimeUS: UInt64) {
        self.pid = pid
        self.startTimeUS = startTimeUS
    }
}

public struct NetworkCounters: Sendable {
    public var interfaces: [UInt32: NetworkBytes]?
    public var processes: [NetworkProcess: NetworkBytes]
    public var processStatus: MetricStatus

    public init(interfaces: [UInt32: NetworkBytes]? = nil, processes: [NetworkProcess: NetworkBytes] = [:],
                processStatus: MetricStatus = .unsupported)
    {
        self.interfaces = interfaces
        self.processes = processes
        self.processStatus = processStatus
    }
}

/// Injected OS seam: only the agent's sampler requests collections.
public protocol NetworkSource: Sendable {
    func counters() async -> NetworkCounters
}

struct NetworkRates {
    var receive: Metric
    var send: Metric
}

struct InterfaceNetworkRates {
    private var previous: [UInt32: NetworkBytes]?
    private var time: UInt64?

    mutating func read(_ current: [UInt32: NetworkBytes]?, now: UInt64) -> NetworkRates {
        defer { previous = current; time = now }
        guard let current else { return NetworkRates(receive: .unsupported, send: .unsupported) }
        guard let previous, let time, now > time else { return NetworkRates(receive: .warmingUp, send: .warmingUp) }
        var delta = NetworkBytes()
        var receiveReset = false
        var sendReset = false
        for (index, bytes) in current {
            // New/recreated interfaces start a baseline; missing interfaces contribute no negative delta.
            guard let old = previous[index] else { continue }
            receiveReset = receiveReset || bytes.received < old.received
            sendReset = sendReset || bytes.sent < old.sent
            delta.add(NetworkBytes(received: bytes.received >= old.received ? bytes.received - old.received : 0,
                                   sent: bytes.sent >= old.sent ? bytes.sent - old.sent : 0))
        }
        let seconds = Double(now - time) / 1_000_000_000
        return NetworkRates(receive: receiveReset ? .warmingUp : .ok(Double(delta.received) / seconds),
                            send: sendReset ? .warmingUp : .ok(Double(delta.sent) / seconds))
    }
}

struct ProcessNetworkRates {
    private var previous: [NetworkProcess: NetworkBytes] = [:]
    private var time: UInt64?

    mutating func read(_ counters: NetworkCounters, processes: inout [ProcessSample], now: UInt64) {
        var next: [NetworkProcess: NetworkBytes] = [:]
        for index in processes.indices {
            let process = processes[index]
            let identity = NetworkProcess(pid: process.pid, startTimeUS: process.processKey.identity.startTimeUS)
            let bytes = counters.processes[identity]
            var missing: Metric = counters.processStatus == .stale ? .stale : .unsupported
            if counters.processStatus == .ok {
                missing = !process.isOwn && bytes == nil ? .permissionDenied : .warmingUp
            }
            // Unreported foreign processes are not measured zeros, even on systems that expose some foreign sockets.
            if counters.processStatus == .ok, process.isOwn || bytes != nil {
                let total = bytes ?? NetworkBytes()
                next[identity] = total
                processes[index].networkReceivedBytes = .ok(Double(total.received))
                processes[index].networkSentBytes = .ok(Double(total.sent))
                if let old = previous[identity], let time, now > time,
                   total.received >= old.received, total.sent >= old.sent
                {
                    let seconds = Double(now - time) / 1_000_000_000
                    processes[index].networkReceiveBps = .ok(Double(total.received - old.received) / seconds)
                    processes[index].networkSendBps = .ok(Double(total.sent - old.sent) / seconds)
                    continue
                }
                processes[index].networkReceiveBps = .warmingUp
                processes[index].networkSendBps = .warmingUp
                continue
            }
            processes[index].networkReceiveBps = missing
            processes[index].networkSendBps = missing
            processes[index].networkReceivedBytes = missing
            processes[index].networkSentBytes = missing
        }
        previous = next
        time = now
    }
}

struct NetworkSourceTotals {
    struct Source {
        var process: NetworkProcess?
        var bytes = NetworkBytes()
    }

    var sources: [UInt: Source] = [:]
    private var closed: [NetworkProcess: NetworkBytes] = [:]

    mutating func remove(_ id: UInt) {
        guard let source = sources.removeValue(forKey: id), let process = source.process else { return }
        closed[process, default: NetworkBytes()].add(source.bytes)
    }

    mutating func update(_ id: UInt, bytes: NetworkBytes) {
        guard var source = sources[id] else { return }
        // Preserve already observed traffic if the kernel resets a live source's counters.
        if bytes.received < source.bytes.received || bytes.sent < source.bytes.sent, let process = source.process {
            closed[process, default: NetworkBytes()].add(NetworkBytes(
                received: bytes.received < source.bytes.received ? source.bytes.received : 0,
                sent: bytes.sent < source.bytes.sent ? source.bytes.sent : 0
            ))
        }
        source.bytes = bytes
        sources[id] = source
    }

    mutating func totals(startTime: (Int32) -> UInt64?) -> [NetworkProcess: NetworkBytes] {
        var all = closed
        for source in sources.values {
            guard let process = source.process else { continue }
            all[process, default: NetworkBytes()].add(source.bytes)
        }
        let live = all.filter { startTime($0.key.pid) == $0.key.startTimeUS }
        closed = closed.filter { live[$0.key] != nil }
        sources = sources.filter { $0.value.process.map { live[$0] != nil } ?? true }
        return live
    }
}
