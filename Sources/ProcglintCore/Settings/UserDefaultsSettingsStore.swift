import Foundation

public enum AppSettingsKeys {
    public static let suite = "io.github.mkusaka.procglint"
    public static let policy = "procglint.sampling_policy"
    public static let permissions = "procglint.allowed_permissions"
    public static let menuBar = "procglint.menu_bar"
    public static let adaptiveRefresh = "procglint.adaptive_refresh"
    public static let columns = "procglint.optional_columns"
}

public struct UserDefaultsSettingsStore: SettingsStore {
    public let suiteName: String?
    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public init(suiteName: String? = AppSettingsKeys.suite) {
        self.suiteName = suiteName
    }

    public func samplingPolicy() throws -> SamplingPolicy {
        guard let data = defaults.data(forKey: AppSettingsKeys.policy) else { return try SamplingPolicy() }
        return try ProcglintJSON.decoder().decode(SamplingPolicy.self, from: data)
    }

    public func setSamplingPolicy(_ policy: SamplingPolicy) throws {
        try policy.validate()
        try defaults.set(ProcglintJSON.encoder().encode(policy), forKey: AppSettingsKeys.policy)
    }

    public func allowedPermissions() throws -> PermissionSet {
        guard let data = defaults.data(forKey: AppSettingsKeys.permissions) else { return [] }
        return try ProcglintJSON.decoder().decode(PermissionSet.self, from: data)
    }

    public func setAllowedPermissions(_ permissions: PermissionSet) throws {
        try defaults.set(ProcglintJSON.encoder().encode(permissions), forKey: AppSettingsKeys.permissions)
    }
}
