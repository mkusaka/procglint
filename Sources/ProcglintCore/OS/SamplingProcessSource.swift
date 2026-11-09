import Foundation

/// The sampling-only OS seam keeps raw Mach identity stamps out of the public/wire model.
protocol SamplingProcessSource: ProcessSource {
    func samplingUsage(pid: Int32, startTimeUS: UInt64) throws -> SamplingUsage
    func processCensus() throws -> [SamplingProcess]
    func systemMemory() -> SystemMemorySample
    func systemBattery() -> BatteryMetrics?
}

extension SamplingProcessSource {
    func systemBattery() -> BatteryMetrics? {
        nil
    }

    func systemMemory() -> SystemMemorySample {
        SystemMemorySample()
    }
}

struct SamplingProcess: Sendable {
    var pid: Int32
    /// Census names are change signals, not replacements for the longer BSD name.
    var bsd: RawBSDInfo?
}

struct SamplingUsage: Sendable {
    var usage: RawRusage
    var startAbstime: UInt64
}
