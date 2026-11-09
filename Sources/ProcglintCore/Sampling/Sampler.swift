import Darwin
import Foundation

public actor Sampler {
    private struct Reading {
        var usage: RawRusage
        var time: UInt64
    }

    private struct Acquisition {
        var bsd: RawBSDInfo
        var usage: RawRusage?
        var startAbstime: UInt64?
    }

    private struct Metadata {
        var bsd: RawBSDInfo
        var executableUUID: UUID?
        var startAbstime: UInt64?
        var comm: String?
        var retryDeniedAt: UInt64?
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
    private var metadata: [Int32: Metadata] = [:]
    private var users: [UInt32: String] = [:]
    private var nextReadings: [ProcessIdentity: Reading] = [:]
    private var nextMetadata: [Int32: Metadata] = [:]
    private var nextUsers: [UInt32: String] = [:]

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
        let census: [SamplingProcess]?
        do {
            if let fast = source as? any SamplingProcessSource {
                census = try fast.processCensus()
            } else {
                census = try source.listPIDs().map { SamplingProcess(pid: $0) }
            }
        } catch ProcessSourceError.enumerationFailed {
            census = nil
        }
        let ticks = try source.hostCPUTicks()
        let vm = try source.vmStatistics()
        let memory = (source as? any SamplingProcessSource)?.systemMemory() ?? SystemMemorySample()
        var coverage = Coverage(enumerated: census?.count ?? 0)
        var processes: [ProcessSample] = []
        processes.reserveCapacity(coverage.enumerated)
        nextReadings.removeAll(keepingCapacity: true)
        nextMetadata.removeAll(keepingCapacity: true)
        nextUsers.removeAll(keepingCapacity: true)

        for process in census ?? [] {
            let pid = process.pid
            do {
                let reading = try acquire(pid: pid, census: process.bsd)
                let bsd = reading.bsd
                let usage = reading.usage
                let startAbstime = reading.startAbstime
                let identity = try ProcessIdentity(bootSessionID: bootSessionID, pid: pid, startTimeUS: bsd.startTimeUS)
                let readingTime = clock.now
                let user = nextUsers[bsd.uid] ?? users[bsd.uid] ?? userName(for: bsd.uid)
                nextUsers[bsd.uid] = user
                var entry: Metadata = if let cached = metadata[pid], cached.bsd == bsd, cached.executableUUID == usage?.executableUUID, cached.startAbstime == startAbstime, cached.comm == process.bsd?.name {
                    cached
                } else {
                    Metadata(bsd: bsd, executableUUID: usage?.executableUUID, startAbstime: startAbstime, comm: process.bsd?.name, user: user)
                }
                if usage == nil {
                    let retry = metadata[pid]?.retryDeniedAt ?? 0
                    entry.retryDeniedAt = entry.bsd == metadata[pid]?.bsd && retry > sequence ? retry : sequence + 12
                } else {
                    entry.retryDeniedAt = nil
                }
                nextMetadata[pid] = entry
                let sameStamp = metadata[pid]?.startAbstime == startAbstime
                let old = sameStamp ? previous[identity].flatMap { $0.usage.executableUUID == usage?.executableUUID ? $0 : nil } : nil
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
                    startTime: Date(timeIntervalSince1970: Double(bsd.startTimeUS) / 1_000_000),
                    powerMW: usage.map { processPower($0.energyNJ, previous: old?.usage.energyNJ, elapsed: elapsed) } ?? missing
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
            activeBytes: vm.activePages * page, inactiveBytes: vm.inactivePages * page, freeBytes: vm.freePages * page,
            memoryPressure: memory.pressure, memoryPressurePercent: memory.pressurePercent,
            swapUsedBytes: memory.swapUsed, swapTotalBytes: memory.swapTotal,
            battery: (source as? any SamplingProcessSource)?.systemBattery()
        )
        // A failed census is not an empty successful sweep: keep baselines and live identities.
        var status: SnapshotStatus = .unavailable
        if census != nil {
            swap(&previous, &nextReadings)
            swap(&metadata, &nextMetadata)
            swap(&users, &nextUsers)
            previousCPU = ticks
            previousTime = now
            status = interval == nil ? .warmingUp : .ok
        }
        sequence += 1
        return Snapshot(agentInstanceID: agentInstanceID, snapshotID: "\(agentInstanceID.prefix(8))-\(sequence)",
                        sampledAt: sampledAt, intervalMS: interval.map { Int(clamping: $0 / 1_000_000) }, ageMS: 0,
                        status: status, coverage: coverage, system: system, processes: processes)
    }

    private func acquire(pid: Int32, census: RawBSDInfo?) throws -> Acquisition {
        if let fast = source as? any SamplingProcessSource, let census {
            if let cached = metadata[pid], census.startTimeUS == cached.bsd.startTimeUS, census.name == cached.comm {
                var bsd = cached.bsd
                bsd.uid = census.uid
                bsd.ppid = census.ppid
                if bsd == cached.bsd, let retry = cached.retryDeniedAt, sequence < retry {
                    return Acquisition(bsd: bsd)
                }
                do {
                    let reading = try fast.samplingUsage(pid: pid, startTimeUS: bsd.startTimeUS)
                    if reading.startAbstime == cached.startAbstime, reading.usage.executableUUID == cached.executableUUID {
                        return Acquisition(bsd: bsd, usage: reading.usage, startAbstime: reading.startAbstime)
                    }
                } catch ProcessSourceError.permissionDenied {
                    return Acquisition(bsd: bsd)
                }
            }
            let before: RawBSDInfo
            do {
                guard let info = try source.bsdInfo(pid: pid) else { throw ProcessSourceError.exited }
                before = info
            } catch ProcessSourceError.permissionDenied {
                return Acquisition(bsd: census)
            }
            guard before.startTimeUS == census.startTimeUS else { throw ProcessSourceError.exited }
            do {
                let reading = try fast.samplingUsage(pid: pid, startTimeUS: before.startTimeUS)
                guard reading.usage.startTimeUS == before.startTimeUS,
                      try source.bsdInfo(pid: pid) == before else { throw ProcessSourceError.exited }
                return Acquisition(bsd: before, usage: reading.usage, startAbstime: reading.startAbstime)
            } catch ProcessSourceError.permissionDenied {
                return Acquisition(bsd: before)
            }
        }
        guard let bsd = try source.bsdInfo(pid: pid) else { throw ProcessSourceError.exited }
        do {
            guard let usage = try source.rusage(pid: pid), usage.startTimeUS == bsd.startTimeUS else { throw ProcessSourceError.exited }
            return Acquisition(bsd: bsd, usage: usage)
        } catch ProcessSourceError.permissionDenied {
            return Acquisition(bsd: bsd)
        }
    }

    /// The caller must enforce include_paths; paths never enter sweep snapshots.
    public func path(for key: ProcessKey) throws -> String? {
        guard key.identity.bootSessionID == bootSessionID,
              let cached = metadata[key.identity.pid], cached.bsd.startTimeUS == key.identity.startTimeUS else { throw ProcessSourceError.exited }
        try validate(key, metadata: cached)
        if let path = cached.path {
            return path
        }
        let path = try source.path(pid: key.identity.pid)
        try validate(key, metadata: cached)
        metadata[key.identity.pid]?.path = path
        return path
    }

    private func validate(_ key: ProcessKey, metadata: Metadata) throws {
        guard let bsd = try source.bsdInfo(pid: key.identity.pid), bsd == metadata.bsd,
              let usage = try source.rusage(pid: key.identity.pid), usage.startTimeUS == key.identity.startTimeUS,
              usage.executableUUID == metadata.executableUUID
        else { throw ProcessSourceError.exited }
    }

    var cachedReadingCount: Int {
        previous.count
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
