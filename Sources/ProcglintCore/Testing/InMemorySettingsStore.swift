import Synchronization

public final class InMemorySettingsStore: SettingsStore {
    private struct State {
        var policy: SamplingPolicy
        var permissions: PermissionSet
    }

    private let state: Mutex<State>

    public init(policy: SamplingPolicy, allowedPermissions: PermissionSet = []) throws {
        try policy.validate()
        state = Mutex(State(policy: policy, permissions: allowedPermissions))
    }

    public func samplingPolicy() -> SamplingPolicy {
        state.withLock { $0.policy }
    }

    public func allowedPermissions() -> PermissionSet {
        state.withLock { $0.permissions }
    }

    public func setSamplingPolicy(_ policy: SamplingPolicy) throws {
        try policy.validate()
        state.withLock { $0.policy = policy }
    }

    public func setAllowedPermissions(_ permissions: PermissionSet) {
        state.withLock { $0.permissions = permissions }
    }
}
