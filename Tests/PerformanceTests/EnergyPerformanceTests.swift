import Darwin
import Dispatch
import Foundation
@testable import ProcglintCore
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROCGLINT_PERF"] == "1"), .serialized)
struct EnergyPerformanceTests {
    @Test func batteryReadAndCachedSweepCost() async throws {
        let clock = FakeClock()
        let source = try DarwinProcessSource(clock: clock)
        let baseline = try DarwinProcessSource(readBattery: { nil }, clock: clock)
        let sampler = try Sampler(source: source, clock: clock)
        let baselineSampler = try Sampler(source: baseline, clock: clock)
        _ = try await sampler.sample()
        _ = try await baselineSampler.sample()
        var refresh: [Double] = []
        var refreshCPU: [Double] = []
        var cached: [Double] = []
        for _ in 0 ..< 100 {
            clock.advance(by: 10_000_000_000)
            var start = DispatchTime.now().uptimeNanoseconds
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = source.systemBattery()
            refreshCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
            refresh.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            for _ in 0 ..< 10 {
                start = DispatchTime.now().uptimeNanoseconds
                _ = source.systemBattery()
                cached.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        var measuredSweeps: [Double] = []
        var baselineSweeps: [Double] = []
        for index in 0 ..< 100 {
            clock.advance(by: 10_000_000_000)
            let pair = index.isMultiple(of: 2) ? [sampler, baselineSampler] : [baselineSampler, sampler]
            for item in pair {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await item.sample()
                let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if item === sampler {
                    measuredSweeps.append(duration)
                } else {
                    baselineSweeps.append(duration)
                }
            }
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return "p50_ms=\(sorted[(values.count - 1) / 2]) p95_ms=\(sorted[Int(ceil(Double(values.count) * 0.95)) - 1])"
        }
        print("PERF battery refresh_n=100 \(stats(refresh)) refresh_cpu_\(stats(refreshCPU)); cached_n=1000 \(stats(cached)); paired_sweeps_n=100 without_battery_\(stats(baselineSweeps)) with_refresh_\(stats(measuredSweeps)); battery_present=\(source.systemBattery() != nil)")
        #if !DEBUG
            #expect(refresh.sorted()[94] < 10, "A battery refresh should stay below 10 ms at p95")
            #expect(cached.sorted()[949] < 1, "Cached battery reads should stay below 1 ms at p95")
        #endif
    }
}
