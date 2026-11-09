import Foundation
import ProcglintCore
import Testing

let testDate = Date(timeIntervalSince1970: 1_704_067_200.125)

func testProcess() throws -> ProcessSample {
    try ProcessSample(processKey: ProcessKey("p1.boot-123.42.9007199254740993"), pid: 42, ppid: 1, name: "worker",
                      uid: 501, user: "me", isOwn: true, status: .ok, cpuPercent: .ok(12.5), cpuTimeNS: UInt64.max,
                      footprintBytes: .ok(123), rssBytes: .ok(111), diskReadBytes: .ok(10), diskWrittenBytes: .ok(20),
                      diskReadBps: .warmingUp, diskWriteBps: .permissionDenied, startTime: testDate, path: "/bin/worker")
}

func testSystem() -> SystemMetrics {
    SystemMetrics(cpuPercent: .ok(25), physicalMemoryBytes: 8192, pageSize: 4096, memoryUsedBytes: 4096,
                  wiredBytes: 1024, compressedBytes: 512, activeBytes: 2560, inactiveBytes: 2048, freeBytes: 2048,
                  memoryPressure: .ok(.normal), swapUsedBytes: .ok(10_400_000_000), swapTotalBytes: .ok(12_000_000_000))
}

func testSnapshot() throws -> Snapshot {
    try Snapshot(agentInstanceID: "12345678-1234-1234-1234-123456789abc", snapshotID: "12345678-1", sampledAt: testDate,
                 intervalMS: nil, ageMS: 0, status: .warmingUp, coverage: Coverage(enumerated: 3, sampled: 1, permissionDenied: 1, exitedDuringSample: 1),
                 system: testSystem(), processes: [testProcess()])
}

func json(_ value: some Encodable) throws -> String {
    try #require(String(data: ProcglintJSON.encoder().encode(value), encoding: .utf8))
}

func roundTrip<T: Codable & Equatable>(_ value: T) throws {
    let encoded = try ProcglintJSON.encoder().encode(value)
    let decoded = try ProcglintJSON.decoder().decode(T.self, from: encoded)
    #expect(decoded == value)
    #expect(try ProcglintJSON.encoder().encode(value) == encoded)
}

let processGolden = #"{"cpu_percent":{"status":"ok","value":12.5},"cpu_time_ns":"18446744073709551615","disk_read_bps":{"status":"warming_up","value":null},"disk_read_bytes":{"status":"ok","value":10},"disk_write_bps":{"status":"permission_denied","value":null},"disk_written_bytes":{"status":"ok","value":20},"footprint_bytes":{"status":"ok","value":123},"is_own":true,"name":"worker","path":"/bin/worker","pid":42,"ppid":1,"process_key":"p1.boot-123.42.9007199254740993","rss_bytes":{"status":"ok","value":111},"start_time":"2024-01-01T00:00:00.125Z","status":"ok","uid":501,"user":"me"}"#
let systemGolden = #"{"active_bytes":2560,"compressed_bytes":512,"cpu_percent":{"status":"ok","value":25},"free_bytes":2048,"inactive_bytes":2048,"memory_pressure":{"status":"ok","value":"normal"},"memory_used_bytes":4096,"page_size":4096,"physical_memory_bytes":8192,"swap_total_bytes":{"status":"ok","value":12000000000},"swap_used_bytes":{"status":"ok","value":10400000000},"wired_bytes":1024}"#

@Test func processGoldenJSON() throws {
    let process = try testProcess()
    #expect(try json(process) == processGolden)
    try roundTrip(process)
    #expect(try ProcglintJSON.decoder().decode(ProcessSample.self, from: Data(processGolden.utf8)).cpuTimeNS == UInt64.max)
}

@Test func snapshotGoldenJSON() throws {
    let snapshot = try testSnapshot()
    let golden = #"{"age_ms":0,"agent_instance_id":"12345678-1234-1234-1234-123456789abc","coverage":{"enumerated":3,"exited_during_sample":1,"permission_denied":1,"sampled":1},"interval_ms":null,"processes":["# + processGolden + #"],"sampled_at":"2024-01-01T00:00:00.125Z","snapshot_id":"12345678-1","status":"warming_up","system":"# + systemGolden + "}"
    #expect(try json(snapshot) == golden)
    try roundTrip(snapshot)
    try roundTrip(snapshot.header)
    #expect(try json(snapshot.header) == golden.replacingOccurrences(of: #""processes":["# + processGolden + "],", with: ""))
    #expect(Snapshot(header: snapshot.header, processes: snapshot.processes) == snapshot)
}

@Test func metricGoldenJSON() throws {
    #expect(try json(Metric.ok(12.5)) == #"{"status":"ok","value":12.5}"#)
    #expect(try json(Metric.warmingUp) == #"{"status":"warming_up","value":null}"#)
    for metric in [Metric.ok(0), .ok(12.5), .warmingUp, .permissionDenied, .exited, .stale, .unsupported] {
        try roundTrip(metric)
    }
}

@Test func metricInvariant() throws {
    for status in MetricStatus.allCases {
        if status == .ok {
            #expect(throws: AgentError.self) { try Metric(value: nil, status: status) }
        } else {
            #expect(throws: AgentError.self) { try Metric(value: 1, status: status) }
        }
    }
    for invalid in [#"{"status":"ok","value":null}"#, #"{"status":"ok"}"#,
                    #"{"status":"stale","value":0}"#, #"{"status":"new_status","value":null}"#]
    {
        #expect(throws: (any Error).self) { try ProcglintJSON.decoder().decode(Metric.self, from: Data(invalid.utf8)) }
    }
}

@Test func optionalCPUTime() throws {
    var process = try testProcess()
    process.cpuTimeNS = nil
    process.ppid = nil
    process.path = nil
    #expect(try json(process).contains(#""cpu_time_ns":null"#))
    try roundTrip(process)
    let absent = try json(process).replacingOccurrences(of: #""cpu_time_ns":null,"#, with: "")
    #expect(try ProcglintJSON.decoder().decode(ProcessSample.self, from: Data(absent.utf8)).cpuTimeNS == nil)
    for value in ["9007199254740993", #""-1""#, #""18446744073709551616""#, #""+1""#] {
        let invalid = try json(process).replacingOccurrences(of: #""cpu_time_ns":null"#, with: #""cpu_time_ns":"# + value)
        #expect(throws: (any Error).self) { try ProcglintJSON.decoder().decode(ProcessSample.self, from: Data(invalid.utf8)) }
    }
}

@Test func fractionalDates() throws {
    #expect(try json(testDate) == #""2024-01-01T00:00:00.125Z""#)
    try roundTrip(testDate)
    for invalid in [#""not a date""#, #""2024-01-01T00:00:00Z""#] {
        #expect(throws: DecodingError.self) { try ProcglintJSON.decoder().decode(Date.self, from: Data(invalid.utf8)) }
    }
}
