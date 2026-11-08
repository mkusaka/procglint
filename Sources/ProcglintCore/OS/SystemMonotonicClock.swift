import Darwin

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public var now: UInt64 {
        // Unlike UPTIME_RAW, MONOTONIC_RAW includes sleep, so leases expire while the Mac sleeps.
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    public func sleep(until deadline: UInt64) async throws {
        try Task.checkCancellation()
        while now < deadline {
            let remaining = deadline - min(now, deadline)
            try await Task.sleep(for: .nanoseconds(Int64(clamping: remaining)),
                                 tolerance: .nanoseconds(Int64(clamping: remaining / 10)), clock: .continuous)
        }
    }
}
