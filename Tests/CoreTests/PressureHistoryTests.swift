import Foundation
import ProcglintCore
import Testing

@Test func continuousPressureRoundTripsAndOldHistoryDecodes() throws {
    var system = testSystem()
    system.memoryPressurePercent = .ok(39)
    #expect(try json(system).contains(#""memory_pressure_percent":{"status":"ok","value":39}"#))
    try roundTrip(system)
    let point = HistoryPoint(t: testDate, cpuPercent: .ok(10), memoryPressurePercent: .ok(65), memoryPressure: .warning)
    try roundTrip(point)
    #expect(try json(point).contains(#""memory_pressure":"warning""#))
    #expect(try json(point).contains(#""memory_pressure_percent":{"status":"ok","value":65}"#))
    let legacy = #"{"t":"2026-01-01T00:00:00.000Z","cpu_percent":{"value":10,"status":"ok"},"memory_used_bytes":{"value":4096,"status":"ok"}}"#
    let decoded = try ProcglintJSON.decoder().decode(HistoryPoint.self, from: Data(legacy.utf8))
    #expect(decoded.memoryPressurePercent == nil)
    #expect(decoded.memoryPressure == nil)
    #expect(decoded.memoryUsedBytes == .ok(4096))
}

@Test func systemHistoryRetainsPressureButProcessHistoryDoesNot() throws {
    var store = try HistoryStore(clock: FakeClock(), policy: SamplingPolicy())
    let process = try storeProcess()
    try store.pin(key: process.processKey, pinned: true)
    var snapshot = storeSnapshot(processes: [process])
    snapshot.system.memoryPressurePercent = .ok(65)
    snapshot.system.memoryPressure = .ok(.warning)
    store.record(snapshot)
    let point = try #require(store.series("system").points.first)
    #expect(point.memoryPressurePercent == .ok(65))
    #expect(point.memoryPressure == .warning)
    let processPoint = try #require(store.series(process.processKey.rawValue).points.first)
    #expect(processPoint.memoryPressurePercent == nil)
    #expect(processPoint.memoryPressure == nil)
}
