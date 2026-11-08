import Foundation

public protocol MonotonicClock: Sendable {
    var now: UInt64 { get }
    func sleep(until deadline: UInt64) async throws
}

public enum ProcessSourceError: Error, Sendable, Equatable {
    case permissionDenied
    case exited
    case enumerationFailed
    case unavailable(String)
}

public struct RawRusage: Sendable, Equatable {
    public var cpuTimeNS: UInt64
    public var footprintBytes: UInt64
    public var rssBytes: UInt64
    public var diskReadBytes: UInt64
    public var diskWrittenBytes: UInt64
    public var startTimeUS: UInt64
    public var executableUUID: UUID?

    public init(cpuTimeNS: UInt64 = 0, footprintBytes: UInt64 = 0, rssBytes: UInt64 = 0,
                diskReadBytes: UInt64 = 0, diskWrittenBytes: UInt64 = 0, startTimeUS: UInt64,
                executableUUID: UUID? = nil)
    {
        self.cpuTimeNS = cpuTimeNS
        self.footprintBytes = footprintBytes
        self.rssBytes = rssBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.startTimeUS = startTimeUS
        self.executableUUID = executableUUID
    }
}

public struct RawBSDInfo: Sendable, Equatable {
    public var name: String
    public var uid: UInt32
    public var ppid: Int32
    public var startTimeUS: UInt64

    public init(name: String, uid: UInt32, ppid: Int32, startTimeUS: UInt64) {
        self.name = name
        self.uid = uid
        self.ppid = ppid
        self.startTimeUS = startTimeUS
    }
}

public struct RawCPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct RawVMStatistics: Sendable, Equatable {
    public var activePages: UInt64
    public var inactivePages: UInt64
    public var wiredPages: UInt64
    public var compressorPages: UInt64
    public var freePages: UInt64

    public init(activePages: UInt64 = 0, inactivePages: UInt64 = 0, wiredPages: UInt64 = 0,
                compressorPages: UInt64 = 0, freePages: UInt64 = 0)
    {
        self.activePages = activePages
        self.inactivePages = inactivePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.freePages = freePages
    }
}

public struct MachTimebase: Sendable, Equatable {
    public var numerator: UInt32
    public var denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

public protocol ProcessSource: Sendable {
    func listPIDs() throws -> [Int32]
    func rusage(pid: Int32) throws -> RawRusage?
    func bsdInfo(pid: Int32) throws -> RawBSDInfo?
    func path(pid: Int32) throws -> String?
    func hostCPUTicks() throws -> RawCPUTicks
    func vmStatistics() throws -> RawVMStatistics
    func bootSessionID() throws -> String
    var physicalMemory: UInt64 { get }
    var pageSize: UInt64 { get }
    var machTimebase: MachTimebase { get }
}

public protocol SettingsStore: Sendable {
    func samplingPolicy() throws -> SamplingPolicy
    func setSamplingPolicy(_ policy: SamplingPolicy) throws
    func allowedPermissions() throws -> PermissionSet
    func setAllowedPermissions(_ permissions: PermissionSet) throws
}
