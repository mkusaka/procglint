import Darwin
@testable import ProcglintCore
import Testing

struct SystemMonotonicClockTests {
    @Test func usesSleepInclusiveRawClock() {
        let clock = SystemMonotonicClock()
        let before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let now = clock.now
        let after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        #expect(before <= now)
        #expect(now <= after)
    }

    @Test func pastDeadlineReturnsImmediately() async throws {
        try await SystemMonotonicClock().sleep(until: 0)
    }

    @Test func sleepDoesNotReturnBeforeDeadline() async throws {
        let clock = SystemMonotonicClock()
        let deadline = clock.now + 1_000_000
        try await clock.sleep(until: deadline)
        #expect(clock.now >= deadline)
    }

    @Test func cancelledSleepThrowsEvenForPastDeadline() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SystemMonotonicClock().sleep(until: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
