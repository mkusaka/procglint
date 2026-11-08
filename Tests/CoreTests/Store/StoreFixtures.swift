import Foundation
import ProcglintCore

func storeProcess(pid: Int32 = 42, start: UInt64 = 10, name: String = "worker", own: Bool = true,
                  cpu: Metric = .ok(12), path: String? = "/bin/worker") throws -> ProcessSample
{
    let key = try ProcessKey(identity: ProcessIdentity(bootSessionID: "boot-a", pid: pid, startTimeUS: start))
    return ProcessSample(processKey: key, pid: pid, name: name, uid: own ? 501 : 0, user: own ? "me" : "root",
                         isOwn: own, status: .ok, cpuPercent: cpu, cpuTimeNS: UInt64(pid), footprintBytes: .ok(Double(pid) * 10),
                         rssBytes: .ok(Double(pid) * 5), diskReadBytes: .ok(20), diskWrittenBytes: .ok(30),
                         diskReadBps: .ok(2), diskWriteBps: .ok(3), startTime: Date(timeIntervalSince1970: 0), path: path)
}

func storeSnapshot(_ sequence: Int = 1, tick: UInt64 = 0, processes: [ProcessSample] = []) -> Snapshot {
    Snapshot(agentInstanceID: "agent-a", snapshotID: "agent-a-\(sequence)",
             sampledAt: Date(timeIntervalSince1970: Double(tick) / 1_000_000_000), intervalMS: 1000, ageMS: 0,
             status: .ok, coverage: Coverage(enumerated: processes.count, sampled: processes.count),
             system: SystemMetrics(cpuPercent: .ok(10), physicalMemoryBytes: 1000, pageSize: 16,
                                   memoryUsedBytes: 400, wiredBytes: 100, compressedBytes: 100,
                                   activeBytes: 200, inactiveBytes: 50, freeBytes: 550), processes: processes)
}
