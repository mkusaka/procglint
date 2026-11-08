import Foundation
import ProcglintCore

actor CountingCollect {
    let clock: FakeClock
    var count = 0
    var hold = false
    var failure: (any Error)?
    var snapshotStatus: SnapshotStatus = .ok
    var durationNS: UInt64 = 0
    var processes: [ProcessSample]
    private var blocked: CheckedContinuation<Void, Never>?

    init(clock: FakeClock, processes: [ProcessSample] = []) {
        self.clock = clock
        self.processes = processes
    }

    func configure(hold: Bool = false, failure: (any Error)? = nil, durationNS: UInt64 = 0, status: SnapshotStatus = .ok) {
        self.hold = hold
        self.failure = failure
        self.durationNS = durationNS
        snapshotStatus = status
    }

    func release() {
        hold = false
        blocked?.resume()
        blocked = nil
    }

    func collect() async throws -> Snapshot {
        count += 1
        let sequence = count
        if hold {
            await withCheckedContinuation { blocked = $0 }
        }
        if durationNS > 0 {
            clock.advance(by: durationNS)
        }
        if let failure {
            throw failure
        }
        var snapshot = storeSnapshot(sequence, tick: clock.now, processes: processes)
        snapshot.status = snapshotStatus
        return snapshot
    }
}

func schedulerWait(_ condition: () async -> Bool) async {
    while await !condition() {
        await Task.yield()
    }
}

func waitForSnapshot(_ scheduler: SamplingScheduler, sequence: Int) async {
    await schedulerWait {
        let query = try? ProcessQuery()
        guard let query else { return false }
        return await (try? scheduler.listProcesses(query, scope: AccessScope()).snapshot.snapshotID) == "agent-a-\(sequence)"
    }
}

func waitForTimer(_ clock: FakeClock) async {
    await schedulerWait { clock.pendingSleepCount > 0 }
}
