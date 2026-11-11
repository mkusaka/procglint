import CProcglintDarwin
import Darwin
import Dispatch
import Foundation

/// ABI references: github.com/staticfloat/monitor/blob/master/julia/NetworkStatistics.h and newosxbook.com/bonus/vol1ch16.html.
/// Only kNStatSrcKeyPID, kNStatSrcKeyRxBytes and kNStatSrcKeyTxBytes are read; no endpoint properties are copied.
final class NStatLibrary {
    typealias Added = @convention(block) (OpaquePointer) -> Void
    typealias DictionaryBlock = @convention(block) (CFDictionary) -> Void
    typealias Done = @convention(block) () -> Void
    typealias Create = @convention(c) (CFAllocator?, DispatchQueue, @escaping Added) -> OpaquePointer?
    typealias Destroy = @convention(c) (OpaquePointer) -> Void
    typealias Add = @convention(c) (OpaquePointer, UInt64, UInt64) -> Int32
    typealias SetDictionary = @convention(c) (OpaquePointer, @escaping DictionaryBlock) -> Void
    typealias SetRemoved = @convention(c) (OpaquePointer, @escaping Done) -> Void
    typealias Query = @convention(c) (OpaquePointer, @escaping Done) -> Void

    let handle: UnsafeMutableRawPointer
    let create: Create
    let destroy: Destroy
    let addTCP: Add
    let addUDP: Add
    let counts: SetDictionary
    let description: SetDictionary
    let removed: SetRemoved
    let queryCounts: Query
    let queryDescriptions: Query
    let queryDescription: Destroy
    let pidKey: String
    let rxKey: String
    let txKey: String

    init?(open: () -> UnsafeMutableRawPointer? = { dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LOCAL | RTLD_NOW) },
          symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { dlsym($0, $1) })
    {
        guard let handle = open() else { return nil }
        func function<T>(_ name: String, _: T.Type) -> T? {
            symbol(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        func key(_ name: String) -> String? {
            guard let address = symbol(handle, name) else { return nil }
            return address.assumingMemoryBound(to: CFString.self).pointee as String
        }
        guard let create = function("NStatManagerCreate", Create.self),
              let destroy = function("NStatManagerDestroy", Destroy.self),
              let addTCP = function("NStatManagerAddAllTCPWithFilter", Add.self),
              let addUDP = function("NStatManagerAddAllUDPWithFilter", Add.self),
              let counts = function("NStatSourceSetCountsBlock", SetDictionary.self),
              let description = function("NStatSourceSetDescriptionBlock", SetDictionary.self),
              let removed = function("NStatSourceSetRemovedBlock", SetRemoved.self),
              let queryCounts = function("NStatManagerQueryAllSources", Query.self),
              let queryDescriptions = function("NStatManagerQueryAllSourcesDescriptions", Query.self),
              let queryDescription = function("NStatSourceQueryDescription", Destroy.self),
              let pid = key("kNStatSrcKeyPID"), let rx = key("kNStatSrcKeyRxBytes"), let tx = key("kNStatSrcKeyTxBytes")
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.create = create
        self.destroy = destroy
        self.addTCP = addTCP
        self.addUDP = addUDP
        self.counts = counts
        self.description = description
        self.removed = removed
        self.queryCounts = queryCounts
        self.queryDescriptions = queryDescriptions
        self.queryDescription = queryDescription
        pidKey = pid
        rxKey = rx
        txKey = tx
    }

    deinit { dlclose(handle) }
}

/// All manager, symbol and aggregation state is confined to queue; callbacks never escape that queue.
public final class DarwinNetworkSource: NetworkSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.mkusaka.procglint.network")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let library: NStatLibrary?
    private var manager: OpaquePointer?
    private var started = false
    private var totals = NetworkSourceTotals()
    private var pending: CheckedContinuation<NetworkCounters, Never>?
    private var generation: UInt64 = 0
    private var completions = 0

    public convenience init() {
        self.init(library: NStatLibrary())
    }

    init(library: NStatLibrary?) {
        self.library = library
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // The last callback can release the collector on its own queue.
        if DispatchQueue.getSpecific(key: queueKey) == true {
            if let manager {
                library?.destroy(manager)
            }
        } else {
            queue.sync {
                if let manager {
                    library?.destroy(manager)
                }
            }
        }
    }

    public func counters() async -> NetworkCounters {
        var result = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard start(), let library, let manager else {
                    continuation.resume(returning: NetworkCounters())
                    return
                }
                // Sampler requests are single-flight; direct concurrent callers get no fabricated values.
                guard pending == nil else {
                    continuation.resume(returning: NetworkCounters(processStatus: .stale))
                    return
                }
                pending = continuation
                generation += 1
                let query = generation
                completions = 0
                let done: NStatLibrary.Done = { [weak self] in self?.completed(query) }
                library.queryDescriptions(manager, done)
                library.queryCounts(manager, done)
                // A changed private ABI or an unresponsive kernel must not stall the shared sampler.
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                    self?.finish(query, status: .stale)
                }
            }
        }
        result.interfaces = readInterfaceCounters()
        return result
    }

    private func start() -> Bool {
        if started {
            return manager != nil
        }
        started = true
        guard let library else { return false }
        manager = library.create(nil, queue) { [weak self] source in self?.added(source) }
        guard let manager else { return false }
        // The AddAll calls return Boolean success (1), not an errno-style zero.
        guard library.addTCP(manager, 0, 0) != 0, library.addUDP(manager, 0, 0) != 0 else {
            library.destroy(manager)
            self.manager = nil
            return false
        }
        return true
    }

    private func added(_ source: OpaquePointer) {
        guard let library else { return }
        let id = UInt(bitPattern: source)
        totals.sources[id] = NetworkSourceTotals.Source()
        library.description(source) { [weak self] dictionary in
            guard let self, totals.sources[id]?.process == nil,
                  let number = (dictionary as NSDictionary)[library.pidKey] as? NSNumber else { return }
            let pid = number.int32Value
            guard pid > 0, let start = Self.startTime(pid) else { return }
            totals.sources[id]?.process = NetworkProcess(pid: pid, startTimeUS: start)
        }
        library.counts(source) { [weak self] dictionary in
            guard let self,
                  let rx = (dictionary as NSDictionary)[library.rxKey] as? NSNumber,
                  let tx = (dictionary as NSDictionary)[library.txKey] as? NSNumber,
                  rx.doubleValue >= 0, tx.doubleValue >= 0 else { return }
            totals.update(id, bytes: NetworkBytes(received: rx.uint64Value, sent: tx.uint64Value))
        }
        library.removed(source) { [weak self] in self?.totals.remove(id) }
        // Attribute short-lived sources before the next periodic query, without retaining their descriptions.
        library.queryDescription(source)
    }

    private static func startTime(_ pid: Int32) -> UInt64? {
        var bsd = pg_bsd_info()
        guard pg_bsd(pid, &bsd) == 0, bsd.has_start_time != 0 else { return nil }
        return bsd.start_time_us
    }

    private func completed(_ query: UInt64) {
        guard query == generation, pending != nil else { return }
        completions += 1
        if completions == 2 {
            finish(query, status: .ok)
        }
    }

    private func finish(_ query: UInt64, status: MetricStatus) {
        guard query == generation, let continuation = pending else { return }
        pending = nil
        let processes = totals.totals(startTime: Self.startTime)
        continuation.resume(returning: NetworkCounters(processes: processes, processStatus: status))
    }
}
