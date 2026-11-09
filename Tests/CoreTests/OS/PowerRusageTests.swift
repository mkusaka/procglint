import Darwin
import Foundation
@testable import ProcglintCore
import Synchronization
import Testing

struct PowerRusageTests {
    @Test func v6ParsesEnergyAndAllExistingCountersInOneRead() throws {
        let flavors = Mutex<[Int32]>([])
        let source = try DarwinProcessSource(readRusage: { pid, flavor, usage in
            #expect(pid == 42)
            flavors.withLock { $0.append(flavor) }
            usage.ri_proc_start_abstime = 7
            usage.ri_user_time = 3
            usage.ri_system_time = 6
            usage.ri_phys_footprint = 4096
            usage.ri_resident_size = 8192
            usage.ri_diskio_bytesread = 100
            usage.ri_diskio_byteswritten = 200
            usage.ri_energy_nj = 9_007_199_254_740_993
            return 0
        })
        let reading = try source.samplingUsage(pid: 42, startTimeUS: 123)
        #expect(flavors.withLock { $0 } == [RUSAGE_INFO_V6])
        #expect(reading.startAbstime == 7)
        #expect(reading.usage.startTimeUS == 123)
        #expect(try reading.usage.cpuTimeNS == (source.nanoseconds(fromMachTicks: 9)))
        #expect(reading.usage.footprintBytes == 4096)
        #expect(reading.usage.rssBytes == 8192)
        #expect(reading.usage.diskReadBytes == 100)
        #expect(reading.usage.diskWrittenBytes == 200)
        #expect(reading.usage.energyNJ == 9_007_199_254_740_993)
    }

    @Test(arguments: [EINVAL, ENOTSUP]) func fallsBackOnlyForUnsupportedFlavor(error: Int32) throws {
        let flavors = Mutex<[Int32]>([])
        let source = try DarwinProcessSource(readRusage: { _, flavor, usage in
            flavors.withLock { $0.append(flavor) }
            if flavor == RUSAGE_INFO_V6 {
                return error
            }
            usage.ri_proc_start_abstime = 7
            usage.ri_phys_footprint = 4096
            usage.ri_energy_nj = 999
            return 0
        })
        let reading = try source.samplingUsage(pid: 42, startTimeUS: 1)
        #expect(flavors.withLock { $0 } == [RUSAGE_INFO_V6, RUSAGE_INFO_V2])
        #expect(reading.usage.energyNJ == nil)
        #expect(reading.usage.footprintBytes == 4096)
    }

    @Test(arguments: [EPERM, ESRCH, EIO]) func doesNotRetryRealFailures(error: Int32) throws {
        let reads = Mutex(0)
        let source = try DarwinProcessSource(readRusage: { _, _, _ in reads.withLock { $0 += 1 }; return error })
        #expect(throws: ProcessSourceError.self) { try source.samplingUsage(pid: 42, startTimeUS: 1) }
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func fallbackFailureIsNotHidden() throws {
        let source = try DarwinProcessSource(readRusage: { _, flavor, _ in flavor == RUSAGE_INFO_V6 ? EINVAL : EPERM })
        #expect(throws: ProcessSourceError.permissionDenied) { try source.samplingUsage(pid: 42, startTimeUS: 1) }
    }
}
