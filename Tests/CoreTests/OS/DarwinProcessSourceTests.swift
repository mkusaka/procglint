import Darwin
import Foundation
@testable import ProcglintCore
import Testing

struct DarwinProcessSourceTests {
    @Test func ownProcessAndBootIdentity() throws {
        let source = try DarwinProcessSource()
        #expect(try source.listPIDs().contains(getpid()))
        #expect(try source.listPIDs().contains(getpid()))
        let bsd = try #require(try source.bsdInfo(pid: getpid()))
        let usage = try #require(try source.rusage(pid: getpid()))
        #expect(bsd.uid == getuid())
        #expect(!bsd.name.isEmpty)
        #expect(bsd.startTimeUS == usage.startTimeUS)
        #expect(try source.path(pid: getpid())?.hasPrefix("/") == true)
        #expect(!source.bootSessionID().isEmpty)
        #expect(source.machTimebase.numerator > 0)
        #expect(source.machTimebase.denominator > 0)
        #expect(userName(for: getuid()) == NSUserName())
    }

    @Test func cpuTicksConvertToNanosecondsLikeGetrusage() throws {
        let source = try DarwinProcessSource()
        let beforeLower = try ownCPUTimeNS()
        let start = try #require(try source.rusage(pid: getpid()))
        let beforeUpper = try ownCPUTimeNS()
        let threadStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - threadStart < 200_000_000 {}
        let afterLower = try ownCPUTimeNS()
        let finish = try #require(try source.rusage(pid: getpid()))
        let afterUpper = try ownCPUTimeNS()
        let actual = Double(finish.cpuTimeNS - start.cpuTimeNS)
        let lower = Double(afterLower - beforeUpper)
        let upper = Double(afterUpper - beforeLower)
        // Bracket the reads so parallel test threads or preemption cannot invalidate the comparison.
        #expect(actual >= lower - 2_000_000)
        #expect(actual <= upper + 2_000_000)
        print("rusage CPU delta: \(actual / 1_000_000) ms; getrusage bounds: \(lower / 1_000_000)...\(upper / 1_000_000) ms; timebase \(source.machTimebase.numerator)/\(source.machTimebase.denominator)")
    }

    @Test func machConversionUsesFullWidthArithmetic() throws {
        let source = try DarwinProcessSource()
        let denominator = UInt64(source.machTimebase.denominator)
        let numerator = UInt64(source.machTimebase.numerator)
        #expect(try source.nanoseconds(fromMachTicks: denominator * 123) == numerator * 123)
        // This multiplication overflows 64 bits at the arm64 125/3 timebase, but the quotient fits.
        let ticks = UInt64.max / max(numerator, 1) * denominator
        let converted = try source.nanoseconds(fromMachTicks: ticks)
        #expect(abs(Double(converted) - Double(ticks) * Double(numerator) / Double(denominator)) < 4096)
        if numerator > denominator {
            #expect(throws: ProcessSourceError.self) { try source.nanoseconds(fromMachTicks: UInt64.max) }
        }
    }

    @Test func vmStatisticsHaveSanePageTotals() throws {
        let source = try DarwinProcessSource()
        let vm = try source.vmStatistics()
        let pages = vm.activePages + vm.inactivePages + vm.wiredPages + vm.compressorPages + vm.freePages
        #expect(source.pageSize > 0)
        #expect(source.physicalMemory > 0)
        #expect(pages > 0)
        #expect(pages * source.pageSize <= source.physicalMemory)
    }

    @Test func absentPIDIsReportedAsExited() throws {
        let source = try DarwinProcessSource()
        #expect(throws: ProcessSourceError.exited) { try source.bsdInfo(pid: Int32.max) }
        #expect(throws: ProcessSourceError.exited) { try source.rusage(pid: Int32.max) }
        #expect(throws: ProcessSourceError.exited) { try source.path(pid: Int32.max) }
    }

    @Test func fullMachineSampleCompletesAndReportsDuration() async throws {
        let source = try DarwinProcessSource()
        let clock = SystemMonotonicClock()
        let sampler = try Sampler(source: source, clock: clock)
        let collect: @Sendable () async throws -> Snapshot = { try await sampler.sample() }
        let start = clock.now
        let snapshot = try await collect()
        let duration = Double(clock.now - start) / 1_000_000
        print("Full Darwin sample: \(duration) ms; coverage: \(snapshot.coverage)")
        #expect(snapshot.processes.contains { $0.pid == getpid() && $0.uid == getuid() && $0.isOwn })
        #expect(snapshot.coverage.enumerated >= snapshot.coverage.sampled)
        #expect(snapshot.processes.allSatisfy { $0.path == nil })
    }

    private func ownCPUTimeNS() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ProcessSourceError.unavailable("getrusage failed") }
        return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
            + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000
    }
}
