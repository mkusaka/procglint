import Foundation
import Synchronization

public final class FakeClock: MonotonicClock {
    private struct Sleeper {
        var deadline: UInt64
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: UInt64
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state: Mutex<State>

    public init(now: UInt64 = 0) {
        state = Mutex(State(now: now))
    }

    public var now: UInt64 {
        state.withLock { $0.now }
    }

    public var pendingSleepCount: Int {
        state.withLock { $0.sleepers.count }
    }

    public func advance(by nanoseconds: UInt64) {
        let ready = state.withLock { state in
            state.now += nanoseconds
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in ready.keys {
                state.sleepers.removeValue(forKey: id)
            }
            return Array(ready.values)
        }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    public func sleep(until deadline: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { state -> Bool in
                    if Task.isCancelled || deadline <= state.now {
                        return true
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if immediate {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
