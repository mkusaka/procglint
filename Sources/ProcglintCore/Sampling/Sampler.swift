import Darwin
import Foundation

public actor Sampler {
    private struct Reading {
        var usage: RawRusage
        var time: UInt64
    }

    private struct Metadata {
        var bsd: RawBSDInfo
        var executableUUID: UUID?
        var user: String
        var path: String?
    }

    private let source: any ProcessSource
    private let clock: any MonotonicClock
    private let agentInstanceID: String
    private let agentUID: UInt32
    private let bootSessionID: String
    private var sequence: UInt64 = 0
    private var previousTime: UInt64?
    private var previousCPU: RawCPUTicks?
    private var previous: [ProcessIdentity: Reading] = [:]
    private var metadata: [ProcessIdentity: Metadata] = [:]
    private var users: [UInt32: String] = [:]

    public init(source: any ProcessSource, clock: any MonotonicClock,
                agentInstanceID: String = UUID().uuidString, agentUID: UInt32 = getuid()) throws
    {
        self.source = source
        self.clock = clock
        self.agentInstanceID = agentInstanceID
        self.agentUID = agentUID
        bootSessionID = try source.bootSessionID()
    }

    /// No suspension inside a sweep: all PIDs and the baseline commit share the actor's serial executor.
    public func sample() async throws -> Snapshot {
        let now = clock.now
        let sampledAt = Date()
        let pids = try source.listPIDs()
        let ticks = try source.hostCPUTicks()
        let vm = try source.vmStatistics()
        var coverage = Coverage(enumerated: pids.count)
        var processes: [ProcessSample] = []
        processes.reserveCapacity(pids.count)
        var nextReadings: [ProcessIdentity: Reading] = [:]
        var nextMetadata: [ProcessIdentity: Metadata] = [:]
        var nextUsers: [UInt32: String] = [:]

        for pid in pids {
            do {
                guard let bsd = try source.bsdInfo(pid: pid) else { throw ProcessSourceError.exited }
                let identity = try ProcessIdentity(bootSessionID: bootSessionID, pid: pid, startTimeUS: bsd.startTimeUS)
                var usage: RawRusage?
                do {
                    guard let reading = try source.rusage(pid: pid), reading.startTimeUS == bsd.startTimeUS else { throw ProcessSourceError.exited }
                    usage = reading
                } catch ProcessSourceError.permissionDenied {
                    // Keep the verified BSD identity even when resource counters are restricted.
                }
                let readingTime = clock.now
                let user = nextUsers[bsd.uid] ?? users[bsd.uid] ?? userName(for: bsd.uid)
                nextUsers[bsd.uid] = user
                let entry: Metadata = if let cached = metadata[identity], cached.bsd == bsd, cached.executableUUID == usage?.executableUUID {
                    cached
                } else {
                    Metadata(bsd: bsd, executableUUID: usage?.executableUUID, user: user)
                }
                nextMetadata[identity] = entry
                let old = previous[identity]
                let elapsed = old.flatMap { readingTime > $0.time ? readingTime - $0.time : nil }
                let denied = usage == nil
                let missing: Metric = denied ? .permissionDenied : .warmingUp
                processes.append(ProcessSample(
                    processKey: ProcessKey(identity: identity), pid: pid, ppid: bsd.ppid, name: entry.bsd.name,
                    uid: bsd.uid, user: entry.user, isOwn: bsd.uid == agentUID,
                    status: denied ? .permissionDenied : .ok,
                    cpuPercent: usage.map { rate($0.cpuTimeNS, previous: old?.usage.cpuTimeNS, elapsed: elapsed, scale: 100) } ?? missing,
                    cpuTimeNS: usage?.cpuTimeNS,
                    footprintBytes: usage.map { .ok(Double($0.footprintBytes)) } ?? missing,
                    rssBytes: usage.map { .ok(Double($0.rssBytes)) } ?? missing,
                    diskReadBytes: usage.map { .ok(Double($0.diskReadBytes)) } ?? missing,
                    diskWrittenBytes: usage.map { .ok(Double($0.diskWrittenBytes)) } ?? missing,
                    diskReadBps: usage.map { rate($0.diskReadBytes, previous: old?.usage.diskReadBytes, elapsed: elapsed, scale: 1_000_000_000) } ?? missing,
                    diskWriteBps: usage.map { rate($0.diskWrittenBytes, previous: old?.usage.diskWrittenBytes, elapsed: elapsed, scale: 1_000_000_000) } ?? missing,
                    startTime: Date(timeIntervalSince1970: Double(bsd.startTimeUS) / 1_000_000)
                ))
                if let usage {
                    coverage.sampled += 1
                    nextReadings[identity] = Reading(usage: usage, time: readingTime)
                } else {
                    coverage.permissionDenied += 1
                }
            } catch ProcessSourceError.exited {
                coverage.exitedDuringSample += 1
            } catch ProcessSourceError.permissionDenied {
                coverage.permissionDenied += 1
            }
        }

        let interval = previousTime.flatMap { now >= $0 ? now - $0 : nil }
        let page = source.pageSize
        let system = SystemMetrics(
            cpuPercent: systemCPU(ticks, previous: previousCPU), physicalMemoryBytes: source.physicalMemory,
            pageSize: page, memoryUsedBytes: (vm.activePages + vm.wiredPages + vm.compressorPages) * page,
            wiredBytes: vm.wiredPages * page, compressedBytes: vm.compressorPages * page,
            activeBytes: vm.activePages * page, inactiveBytes: vm.inactivePages * page, freeBytes: vm.freePages * page
        )
        // Failed sweeps must not erase baselines or prune live identities.
        previous = nextReadings
        metadata = nextMetadata
        users = nextUsers
        previousCPU = ticks
        previousTime = now
        sequence += 1
        return Snapshot(agentInstanceID: agentInstanceID, snapshotID: "\(agentInstanceID.prefix(8))-\(sequence)",
                        sampledAt: sampledAt, intervalMS: interval.map { Int(clamping: $0 / 1_000_000) }, ageMS: 0,
                        status: interval == nil ? .warmingUp : .ok, coverage: coverage, system: system, processes: processes)
    }

    /// The caller must enforce include_paths; paths never enter sweep snapshots.
    public func path(for key: ProcessKey) throws -> String? {
        guard let cached = metadata[key.identity] else { throw ProcessSourceError.exited }
        try validate(key, metadata: cached)
        if let path = cached.path {
            return path
        }
        let path = try source.path(pid: key.identity.pid)
        try validate(key, metadata: cached)
        metadata[key.identity]?.path = path
        return path
    }

    private func validate(_ key: ProcessKey, metadata: Metadata) throws {
        guard let bsd = try source.bsdInfo(pid: key.identity.pid), bsd == metadata.bsd,
              let usage = try source.rusage(pid: key.identity.pid), usage.startTimeUS == key.identity.startTimeUS,
              usage.executableUUID == metadata.executableUUID
        else { throw ProcessSourceError.exited }
    }

    var cachedProcessCount: Int {
        metadata.count
    }

    var cachedUserCount: Int {
        users.count
    }

    private func rate(_ current: UInt64, previous: UInt64?, elapsed: UInt64?, scale: Double) -> Metric {
        guard let previous, current >= previous, let elapsed, elapsed > 0 else { return .warmingUp }
        return .ok(Double(current - previous) / Double(elapsed) * scale)
    }

    private func systemCPU(_ ticks: RawCPUTicks, previous: RawCPUTicks?) -> Metric {
        guard let previous else { return .warmingUp }
        // host_statistics exposes 32-bit counters, which wrap on long-running machines.
        func delta(_ current: UInt64, _ old: UInt64) -> Double {
            if current >= old {
                return Double(current - old)
            }
            return Double(UInt32(truncatingIfNeeded: current) &- UInt32(truncatingIfNeeded: old))
        }
        let busy = delta(ticks.user, previous.user) + delta(ticks.system, previous.system) + delta(ticks.nice, previous.nice)
        let total = busy + delta(ticks.idle, previous.idle)
        return total > 0 ? .ok(min(100, max(0, 100 * busy / total))) : .warmingUp
    }
}
