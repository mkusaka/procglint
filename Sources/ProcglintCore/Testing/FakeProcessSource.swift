import Foundation
import Synchronization

public final class FakeProcessSource: ProcessSource {
    public struct Process: Sendable, Equatable {
        public var rusage: RawRusage
        public var bsdInfo: RawBSDInfo
        public var path: String?

        public init(rusage: RawRusage, bsdInfo: RawBSDInfo, path: String? = nil) {
            self.rusage = rusage
            self.bsdInfo = bsdInfo
            self.path = path
        }
    }

    public struct State: Sendable {
        public var processes: [Int32: Process] = [:]
        public var enumerationError: ProcessSourceError?
        public var processErrors: [Int32: ProcessSourceError] = [:]
        public var exitDuringSample: Set<Int32> = []
        public var cpuTicks = RawCPUTicks()
        public var vm = RawVMStatistics()
        public var bootSessionID = "fake-boot"
        public var physicalMemory: UInt64 = 8 * 1024 * 1024 * 1024
        public var pageSize: UInt64 = 16384
        public var machTimebase = MachTimebase(numerator: 1, denominator: 1)

        public init() {}
    }

    private let storage: Mutex<State>

    public init(state: State = State()) {
        storage = Mutex(state)
    }

    public var state: State {
        storage.withLock { $0 }
    }

    public func update(_ body: (inout State) -> Void) {
        storage.withLock { body(&$0) }
    }

    public func addProcess(pid: Int32, process: Process) {
        storage.withLock { $0.processes[pid] = process }
    }

    public func removeProcess(pid: Int32) {
        storage.withLock { state in
            state.processes.removeValue(forKey: pid)
            state.processErrors.removeValue(forKey: pid)
            state.exitDuringSample.remove(pid)
        }
    }

    public func setRusage(pid: Int32, rusage: RawRusage) {
        storage.withLock { $0.processes[pid]?.rusage = rusage }
    }

    public func listPIDs() throws -> [Int32] {
        try storage.withLock { state in
            if let error = state.enumerationError {
                throw error
            }
            return state.processes.keys.sorted()
        }
    }

    public func rusage(pid: Int32) throws -> RawRusage? {
        try storage.withLock { state in
            if state.exitDuringSample.remove(pid) != nil {
                state.processes.removeValue(forKey: pid)
                throw ProcessSourceError.exited
            }
            if let error = state.processErrors[pid] {
                throw error
            }
            return state.processes[pid]?.rusage
        }
    }

    public func bsdInfo(pid: Int32) throws -> RawBSDInfo? {
        try storage.withLock { state in
            if let error = state.processErrors[pid] {
                throw error
            }
            return state.processes[pid]?.bsdInfo
        }
    }

    public func path(pid: Int32) throws -> String? {
        try storage.withLock { state in
            if let error = state.processErrors[pid] {
                throw error
            }
            return state.processes[pid]?.path
        }
    }

    public func hostCPUTicks() -> RawCPUTicks {
        storage.withLock { $0.cpuTicks }
    }

    public func vmStatistics() -> RawVMStatistics {
        storage.withLock { $0.vm }
    }

    public func bootSessionID() -> String {
        storage.withLock { $0.bootSessionID }
    }

    public var physicalMemory: UInt64 {
        storage.withLock { $0.physicalMemory }
    }

    public var pageSize: UInt64 {
        storage.withLock { $0.pageSize }
    }

    public var machTimebase: MachTimebase {
        storage.withLock { $0.machTimebase }
    }
}
