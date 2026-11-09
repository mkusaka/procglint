import Darwin
import Foundation
@testable import ProcglintCore
import Synchronization
import Testing

struct SystemMemoryTests {
    @Test(arguments: [Int32(1), 2, 4, 0, 3, 5, 8, -1, Int32.max])
    func pressureLevels(level: Int32) throws {
        let source = try DarwinProcessSource(readPressure: { $0 = level; return 0 }, readSwap: { _ in ENOTSUP })
        let expected: MemoryPressure? = [1: .normal, 2: .warning, 4: .critical][level]
        let reading = source.systemMemory()
        #expect(reading.pressure.value == expected)
        #expect(reading.pressure.status == (expected == nil ? .unsupported : .ok))
        #expect(reading.swapUsed == .unsupported)
        #expect(reading.swapTotal == .unsupported)
    }

    @Test(arguments: [Int32(0), 1, 61, 99, 100, -1, 101, Int32.min, Int32.max])
    func continuousPressureMapping(level: Int32) throws {
        let source = try DarwinProcessSource(readMemoryLevel: { $0 = level; return 0 })
        let expected: Metric = (0 ... 100).contains(level) ? .ok(Double(100 - level)) : .unsupported
        #expect(source.systemMemory().pressurePercent == expected)
    }

    @Test(arguments: [Int32(ENOENT), EIO, EPERM, EACCES])
    func failuresDoNotUseWrittenValues(error: Int32) throws {
        let source = try DarwinProcessSource(readPressure: { $0 = 1; return error }, readSwap: {
            $0.xsu_used = 1024; $0.xsu_total = 2048; return error
        }, readMemoryLevel: { $0 = 61; return error })
        let reading = source.systemMemory()
        #expect(reading.pressure == .unsupported)
        let expected: Metric = error == EPERM || error == EACCES ? .permissionDenied : .unsupported
        #expect(reading.pressurePercent == expected)
        #expect(reading.swapUsed == expected)
        #expect(reading.swapTotal == expected)
    }

    @Test(arguments: [(UInt64(0), UInt64(0)), (0, 2_000_000_000), (10_400_000_000, 12_000_000_000)])
    func swapUsesXswUsageBytes(used: UInt64, total: UInt64) throws {
        let source = try DarwinProcessSource(readPressure: { $0 = 1; return 0 }, readSwap: {
            $0.xsu_used = used; $0.xsu_total = total; $0.xsu_avail = total - used
            $0.xsu_pagesize = 16384; return 0
        })
        let reading = source.systemMemory()
        #expect(reading.swapUsed == .ok(Double(used)))
        #expect(reading.swapTotal == .ok(Double(total)))
    }

    @Test func malformedSwapIsUnavailable() throws {
        let source = try DarwinProcessSource(readSwap: { $0.xsu_used = 2; $0.xsu_total = 1; return 0 })
        #expect(source.systemMemory().swapUsed == .unsupported)
        #expect(source.systemMemory().swapTotal == .unsupported)
    }

    @Test func samplerReadsEachSysctlOncePerCollection() async throws {
        let calls = Mutex((pressure: 0, swap: 0, level: 0))
        let source = try DarwinProcessSource(readPressure: {
            calls.withLock { $0.pressure += 1 }; $0 = 2; return 0
        }, readSwap: {
            calls.withLock { $0.swap += 1 }; $0.xsu_used = 1024; $0.xsu_total = 2048; return 0
        }, readMemoryLevel: {
            calls.withLock { $0.level += 1 }; $0 = 61; return 0
        })
        let sampler = try Sampler(source: source, clock: FakeClock())
        for _ in 0 ..< 2 {
            let snapshot = try await sampler.sample()
            #expect(snapshot.system.memoryPressure == .ok(.warning))
            #expect(snapshot.system.memoryPressurePercent == .ok(39))
            #expect(snapshot.system.swapUsedBytes == .ok(1024))
            #expect(snapshot.system.swapTotalBytes == .ok(2048))
        }
        #expect(calls.withLock { $0.pressure == 2 && $0.swap == 2 && $0.level == 2 })
        let fakeSampler = try Sampler(source: FakeProcessSource(), clock: FakeClock())
        let missing = try await fakeSampler.sample().system
        #expect(missing.memoryPressure == .unsupported)
        #expect(missing.memoryPressurePercent == .unsupported)
        #expect(missing.swapUsedBytes == .unsupported)
        #expect(missing.swapTotalBytes == .unsupported)
    }

    @Test func realReadingsRespectMetricInvariants() throws {
        let reading = try DarwinProcessSource().systemMemory()
        #expect((reading.pressure.value != nil) == (reading.pressure.status == .ok))
        #expect((reading.pressurePercent.value != nil) == (reading.pressurePercent.status == .ok))
        if let percent = reading.pressurePercent.value {
            #expect((0 ... 100).contains(percent))
        }
        #expect((reading.swapUsed.value != nil) == (reading.swapUsed.status == .ok))
        #expect(reading.swapUsed.status == reading.swapTotal.status)
        if let used = reading.swapUsed.value, let total = reading.swapTotal.value {
            #expect(used >= 0 && used <= total)
        }
    }
}
