import Foundation
@testable import ProcglintCore
import Testing

private struct NoNetwork: NetworkSource {
    func counters() async -> NetworkCounters {
        NetworkCounters()
    }
}

private struct LimitedNetworkBenchmarkSource: SamplingProcessSource {
    let source: DarwinProcessSource

    var physicalMemory: UInt64 {
        source.physicalMemory
    }

    var pageSize: UInt64 {
        source.pageSize
    }

    var machTimebase: MachTimebase {
        source.machTimebase
    }

    func bootSessionID() -> String {
        source.bootSessionID()
    }

    func listPIDs() throws -> [Int32] {
        try Array(source.listPIDs().prefix(700))
    }

    func processCensus() throws -> [SamplingProcess] {
        try Array(source.processCensus().prefix(700))
    }

    func samplingUsage(pid: Int32, startTimeUS: UInt64) throws -> SamplingUsage {
        try source.samplingUsage(pid: pid, startTimeUS: startTimeUS)
    }

    func bsdInfo(pid: Int32) throws -> RawBSDInfo? {
        try source.bsdInfo(pid: pid)
    }

    func rusage(pid: Int32) throws -> RawRusage? {
        try source.rusage(pid: pid)
    }

    func path(pid: Int32) throws -> String? {
        try source.path(pid: pid)
    }

    func hostCPUTicks() throws -> RawCPUTicks {
        try source.hostCPUTicks()
    }

    func vmStatistics() throws -> RawVMStatistics {
        try source.vmStatistics()
    }

    func systemMemory() -> SystemMemorySample {
        source.systemMemory()
    }

    func systemBattery() -> BatteryMetrics? {
        source.systemBattery()
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROCGLINT_PERF"] == "1"), .serialized)
struct NetworkPerformanceTests {
    @Test func pairedRealOSSweepsWith700Processes() async throws {
        let clock = FakeClock()
        let darwin = try DarwinProcessSource(clock: clock)
        let source = LimitedNetworkBenchmarkSource(source: darwin)
        let network = DarwinNetworkSource()
        let measured = try Sampler(source: source, clock: clock, networkSource: network)
        let baseline = try Sampler(source: source, clock: clock, networkSource: NoNetwork())
        let start = DispatchTime.now().uptimeNanoseconds
        let first = try await measured.sample()
        let cold = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        _ = try await baseline.sample()
        var withNetwork: [Double] = []
        var withoutNetwork: [Double] = []
        var added: [Double] = []
        for index in 0 ..< 100 {
            clock.advance(by: 1_000_000_000)
            let pair = index.isMultiple(of: 2) ? [measured, baseline] : [baseline, measured]
            var durations: [Double] = []
            for sampler in pair {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await sampler.sample()
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let withValue = durations[index.isMultiple(of: 2) ? 0 : 1]
            let withoutValue = durations[index.isMultiple(of: 2) ? 1 : 0]
            withNetwork.append(withValue)
            withoutNetwork.append(withoutValue)
            added.append(withValue - withoutValue)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return "p50_ms=\(sorted[49]) p95_ms=\(sorted[94])"
        }
        let current = await network.counters()
        try print("PERF network paired_real_os_sweeps=100 enumerated=\(first.coverage.enumerated) sampled=\(first.coverage.sampled) total_host_pids=\(darwin.listPIDs().count) cold_ms=\(cold) baseline_\(stats(withoutNetwork)) with_network_\(stats(withNetwork)) paired_added_\(stats(added)) nstat_status=\(current.processStatus.rawValue) nstat_processes=\(current.processes.count)")
        #expect(first.coverage.enumerated > 0)
        #expect(current.processStatus == .ok)
    }
}
