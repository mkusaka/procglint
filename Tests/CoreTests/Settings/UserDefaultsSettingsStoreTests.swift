import Foundation
import ProcglintCore
import Testing

struct UserDefaultsSettingsStoreTests {
    @Test func sharedSuitePreservesExistingKeysAndEncoding() throws {
        let suite = "procglint-settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gui = UserDefaultsSettingsStore(suiteName: suite)
        let agent = UserDefaultsSettingsStore(suiteName: suite)
        #expect(AppSettingsKeys.suite == "io.github.mkusaka.procglint")
        #expect(try agent.samplingPolicy() == SamplingPolicy())
        #expect(try agent.allowedPermissions().isEmpty)
        let policy = try SamplingPolicy(revision: 2, guiIntervalMS: .twoSeconds, historyMinutes: 3)
        try gui.setSamplingPolicy(policy)
        try gui.setAllowedPermissions([.observe, .includePaths])
        #expect(try agent.samplingPolicy() == policy)
        #expect(try agent.allowedPermissions() == [.observe, .includePaths])
        let data = try #require(defaults.data(forKey: "procglint.sampling_policy"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["gui_interval_ms"] as? Int == 2000)
        #expect(object["history_minutes"] as? Int == 3)
        let permissions = try #require(defaults.data(forKey: "procglint.allowed_permissions"))
        #expect(try JSONSerialization.jsonObject(with: permissions) as? [String] == ["include_paths", "observe"])
        try agent.setAllowedPermissions([])
        #expect(try gui.allowedPermissions().isEmpty)
    }

    @Test func invalidStoredValuesFailClosedAndInvalidPolicyDoesNotOverwrite() throws {
        let suite = "procglint-settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(suiteName: suite)
        let policy = try SamplingPolicy()
        try store.setSamplingPolicy(policy)
        var invalid = policy
        invalid.historyMinutes = 11
        #expect(throws: (any Error).self) { try store.setSamplingPolicy(invalid) }
        #expect(try store.samplingPolicy() == policy)
        defaults.set(Data("[\"unknown_permission\"]".utf8), forKey: AppSettingsKeys.permissions)
        #expect(throws: (any Error).self) { try store.allowedPermissions() }
        defaults.set(Data("not-json".utf8), forKey: AppSettingsKeys.policy)
        #expect(throws: (any Error).self) { try store.samplingPolicy() }
    }
}
