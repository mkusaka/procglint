import Foundation
@testable import ProcglintCore
import Testing

struct PowerTests {
    private func process(energy: UInt64?, start: UInt64 = 1) -> FakeProcessSource.Process {
        FakeProcessSource.Process(rusage: RawRusage(startTimeUS: start, energyNJ: energy),
                                  bsdInfo: RawBSDInfo(name: "worker", uid: 501, ppid: 1, startTimeUS: start))
    }

    @Test func powerUsesActualIntervalAndResetsWithIdentityOrExec() async throws {
        let clock = FakeClock()
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process(energy: 1_000_000_000))
        let sampler = try Sampler(source: source, clock: clock)
        #expect(try await sampler.sample().processes.first?.powerMW == .warmingUp)
        source.update { $0.processes[42]?.rusage.energyNJ = 7_000_000_000 }
        clock.advance(by: 2_000_000_000)
        #expect(try await sampler.sample().processes.first?.powerMW == .ok(3000))
        clock.advance(by: 1_000_000_000)
        #expect(try await sampler.sample().processes.first?.powerMW == .ok(0))
        source.update { $0.processes[42]?.rusage.energyNJ = 1 }
        clock.advance(by: 1_000_000_000)
        #expect(try await sampler.sample().processes.first?.powerMW == .warmingUp)
        source.addProcess(pid: 42, process: process(energy: 99_000_000_000, start: 2))
        clock.advance(by: 1_000_000_000)
        #expect(try await sampler.sample().processes.first?.powerMW == .warmingUp)
        source.update {
            $0.processes[42]?.rusage.energyNJ = 100_000_000_000
            $0.processes[42]?.rusage.executableUUID = UUID()
        }
        clock.advance(by: 1_000_000_000)
        #expect(try await sampler.sample().processes.first?.powerMW == .warmingUp)
    }

    @Test func zeroAndMissingEnergyAreUnsupportedNotZeroPower() async throws {
        let clock = FakeClock()
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process(energy: 0))
        source.addProcess(pid: 43, process: process(energy: nil))
        let sampler = try Sampler(source: source, clock: clock)
        #expect(try await sampler.sample().processes.allSatisfy { $0.powerMW == .unsupported })
        clock.advance(by: 1_000_000_000)
        #expect(try await sampler.sample().processes.allSatisfy { $0.powerMW == .unsupported })
        #expect(processPower(2, previous: 1, elapsed: 0) == .warmingUp)
        #expect(processPower(2, previous: 0, elapsed: 1) == .warmingUp)
    }

    @Test func powerUsesPerReadingTimeAndKeepsPrecisionBeforeSubtracting() {
        #expect(processPower(9_007_199_254_740_994, previous: 9_007_199_254_740_993, elapsed: 1000) == .ok(1))
        #expect(processPower(5_000_000_000, previous: 1_000_000_000, elapsed: 4_000_000_000) == .ok(1000))
    }
}
