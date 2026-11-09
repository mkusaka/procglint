import CProcglintDarwin
import Darwin
import Foundation
import Synchronization

public final class DarwinProcessSource: SamplingProcessSource {
    private struct Buffers {
        var pids: [Int32] = []
        var census = pg_census_buffer()
        var path = [CChar](repeating: 0, count: 4096)
    }

    private let buffers = Mutex(Buffers())
    private let bootID: String
    public let physicalMemory: UInt64
    public let pageSize: UInt64
    public let machTimebase: MachTimebase
    private let readPressure: @Sendable (inout Int32) -> Int32
    private let readSwap: @Sendable (inout xsw_usage) -> Int32

    public init(readPressure: @escaping @Sendable (inout Int32) -> Int32 = { pg_memory_pressure(&$0) },
                readSwap: @escaping @Sendable (inout xsw_usage) -> Int32 = { pg_swap_usage(&$0) }) throws
    {
        self.readPressure = readPressure
        self.readSwap = readSwap
        var timebase = mach_timebase_info_data_t()
        try Self.checkMach(pg_timebase(&timebase))
        guard timebase.numer > 0, timebase.denom > 0 else {
            throw ProcessSourceError.unavailable("Invalid Mach timebase")
        }
        machTimebase = MachTimebase(numerator: timebase.numer, denominator: timebase.denom)
        var memory: UInt64 = 0
        try Self.checkPOSIX(pg_physical_memory(&memory))
        physicalMemory = memory
        var size: vm_size_t = 0
        try Self.checkMach(pg_page_size(&size))
        pageSize = UInt64(size)
        var boot = [CChar](repeating: 0, count: 128)
        var length = boot.count
        try Self.checkPOSIX(pg_boot_session(&boot, &length))
        guard let bootID = String(bytes: boot.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              !bootID.isEmpty else { throw ProcessSourceError.unavailable("Invalid boot session ID") }
        self.bootID = bootID
    }

    deinit {
        buffers.withLock { pg_census_free(&$0.census) }
    }

    func processCensus() throws -> [SamplingProcess] {
        try buffers.withLock { buffers in
            var count: Int32 = 0
            guard pg_census(&buffers.census, &count) == 0 else { throw ProcessSourceError.enumerationFailed }
            var result: [SamplingProcess] = []
            result.reserveCapacity(Int(count))
            for index in 0 ..< count {
                var entry = pg_census_entry()
                guard pg_census_get(&buffers.census, index, &entry) != 0 else { continue }
                result.append(SamplingProcess(pid: entry.pid, bsd: Self.bsd(entry.bsd, pid: entry.pid)))
            }
            return result
        }
    }

    public func listPIDs() throws -> [Int32] {
        try buffers.withLock { buffers in
            var count: Int32 = 0
            guard pg_list_pids(nil, 0, &count) == 0, count > 0 else {
                throw ProcessSourceError.enumerationFailed
            }
            var capacity = max(Int(count) + max(Int(count) / 4, 64), buffers.pids.count)
            for _ in 0 ..< 8 {
                guard capacity <= Int(Int32.max) / MemoryLayout<Int32>.stride else {
                    throw ProcessSourceError.enumerationFailed
                }
                if buffers.pids.count < capacity {
                    buffers.pids = [Int32](repeating: 0, count: capacity)
                }
                guard pg_list_pids(&buffers.pids, Int32(capacity), &count) == 0 else {
                    throw ProcessSourceError.enumerationFailed
                }
                if count < capacity {
                    return Array(buffers.pids.prefix(Int(count)))
                }
                capacity *= 2
            }
            throw ProcessSourceError.enumerationFailed
        }
    }

    public func rusage(pid: Int32) throws -> RawRusage? {
        var reading = try samplingUsage(pid: pid, startTimeUS: 0).usage
        // Control/path callers retain the post-counter BSD check; only sweeps use cached raw stamps.
        reading.startTimeUS = try readBSD(pid: pid).startTimeUS
        return reading
    }

    func samplingUsage(pid: Int32, startTimeUS: UInt64) throws -> SamplingUsage {
        var usage = rusage_info_v2()
        try Self.checkPOSIX(pg_rusage(pid, &usage))
        guard usage.ri_proc_start_abstime != 0 else { throw ProcessSourceError.exited }
        let (ticks, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard !overflow else { throw ProcessSourceError.unavailable("CPU counter overflow") }
        return try SamplingUsage(usage: RawRusage(
            cpuTimeNS: nanoseconds(fromMachTicks: ticks),
            footprintBytes: usage.ri_phys_footprint, rssBytes: usage.ri_resident_size,
            diskReadBytes: usage.ri_diskio_bytesread, diskWrittenBytes: usage.ri_diskio_byteswritten,
            startTimeUS: startTimeUS, executableUUID: UUID(uuid: usage.ri_uuid)
        ), startAbstime: usage.ri_proc_start_abstime)
    }

    public func bsdInfo(pid: Int32) throws -> RawBSDInfo? {
        try readBSD(pid: pid)
    }

    private func readBSD(pid: Int32) throws -> RawBSDInfo {
        var info = pg_bsd_info()
        try Self.checkPOSIX(pg_bsd(pid, &info))
        // Short BSD info cannot establish a safe identity; never invent a start timestamp.
        guard info.has_start_time != 0 else { throw ProcessSourceError.permissionDenied }
        return Self.bsd(info, pid: pid)
    }

    private static func bsd(_ info: pg_bsd_info, pid: Int32) -> RawBSDInfo {
        let name = withUnsafeBytes(of: info.name) { bytes in
            String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "pid \(pid)"
        }
        return RawBSDInfo(name: name, uid: info.uid, ppid: info.ppid, startTimeUS: info.start_time_us)
    }

    public func path(pid: Int32) throws -> String? {
        try buffers.withLock { buffers in
            try Self.checkPOSIX(pg_path(pid, &buffers.path, UInt32(buffers.path.count)))
            guard let path = String(bytes: buffers.path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8)
            else { throw ProcessSourceError.unavailable("Non-UTF8 process path") }
            return path
        }
    }

    public func hostCPUTicks() throws -> RawCPUTicks {
        var ticks = pg_cpu_ticks()
        try Self.checkMach(pg_host_cpu(&ticks))
        return RawCPUTicks(user: UInt64(ticks.user), system: UInt64(ticks.system),
                           idle: UInt64(ticks.idle), nice: UInt64(ticks.nice))
    }

    public func vmStatistics() throws -> RawVMStatistics {
        var vm = pg_vm_statistics()
        try Self.checkMach(pg_host_vm(&vm))
        return RawVMStatistics(activePages: vm.active, inactivePages: vm.inactive, wiredPages: vm.wired,
                               compressorPages: vm.compressor, freePages: vm.free)
    }

    func systemMemory() -> SystemMemorySample {
        var level: Int32 = 0
        let pressureError = readPressure(&level)
        let pressure: MemoryPressure? = switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
        var swap = xsw_usage()
        let swapError = readSwap(&swap)
        let unavailable: Metric = swapError == EACCES || swapError == EPERM ? .permissionDenied : .unsupported
        let validSwap = swapError == 0 && swap.xsu_used <= swap.xsu_total
        let pressureMetric: MemoryPressureMetric = pressureError == 0 ? pressure.map(MemoryPressureMetric.ok) ?? .unsupported : .unsupported
        return SystemMemorySample(pressure: pressureMetric,
                                  swapUsed: validSwap ? .ok(Double(swap.xsu_used)) : unavailable,
                                  swapTotal: validSwap ? .ok(Double(swap.xsu_total)) : unavailable)
    }

    public func bootSessionID() -> String {
        bootID
    }

    func nanoseconds(fromMachTicks ticks: UInt64) throws -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(machTimebase.numerator))
        let denominator = UInt64(machTimebase.denominator)
        guard product.high < denominator else { throw ProcessSourceError.unavailable("Mach time overflow") }
        return denominator.dividingFullWidth(product).quotient
    }

    private static func checkPOSIX(_ error: Int32) throws {
        switch error {
        case 0: return
        case EPERM, EACCES: throw ProcessSourceError.permissionDenied
        case ESRCH, ENOENT: throw ProcessSourceError.exited
        default: throw ProcessSourceError.unavailable("errno \(error)")
        }
    }

    private static func checkMach(_ result: kern_return_t) throws {
        guard result == KERN_SUCCESS else { throw ProcessSourceError.unavailable("Mach error \(result)") }
    }
}
