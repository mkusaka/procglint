import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

private struct FocusClock: MonotonicClock {
    let base: FakeClock
    let sleeps: AsyncStream<UInt64>.Continuation
    var now: UInt64 {
        base.now
    }

    func sleep(until deadline: UInt64) async throws {
        sleeps.yield(deadline)
        try await base.sleep(until: deadline)
    }
}

@MainActor
@Test(arguments: SamplingInterval.allCases, [(true, false), (false, true), (false, false)])
func adaptiveRefreshUsesNextIntervalAfterDebounce(_ interval: SamplingInterval, _ focus: (Bool, Bool)) async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    #expect(prefs.adaptiveRefresh)
    let base = FakeClock()
    let (events, continuation) = AsyncStream<UInt64>.makeStream()
    let clock = FocusClock(base: base, sleeps: continuation)
    var sleeps = events.makeAsyncIterator()
    let service = try FakeMonitorService()
    service.clock = clock
    service.currentPolicy = try SamplingPolicy(guiIntervalMS: interval)
    let model = try MonitorViewModel(service: service, preferences: prefs, clock: clock)
    await model.setVisibility(window: true, menuBar: false)
    #expect(service.leaseRequests.last?.intervalMS == interval)
    model.setFocus(appActive: focus.0, keyWindow: focus.1)
    let pending = try #require(model.focusUpdate)
    #expect(await sleeps.next() == 1_000_000_000)
    base.advance(by: 999_999_999)
    #expect(service.leaseRequests.last?.intervalMS == interval)
    base.advance(by: 1)
    await pending.value
    let slower: SamplingInterval = switch interval {
    case .oneSecond: .twoSeconds
    case .twoSeconds: .fiveSeconds
    case .fiveSeconds, .tenSeconds: .tenSeconds
    }
    #expect(service.leaseRequests.last?.intervalMS == slower)
    #expect(model.pollingInterval == Double(slower.rawValue) / 1000)
    model.setFocus(appActive: true, keyWindow: true)
    let regained = try #require(model.focusUpdate)
    #expect(await sleeps.next() == 2_000_000_000)
    base.advance(by: 1_000_000_000)
    await regained.value
    #expect(service.leaseRequests.last?.intervalMS == interval)
    prefs.adaptiveRefresh = false
    #expect(!AppPreferences(suiteName: prefs.store.suiteName).adaptiveRefresh)
    model.setFocus(appActive: focus.0, keyWindow: focus.1)
    let disabled = try #require(model.focusUpdate)
    #expect(await sleeps.next() == 3_000_000_000)
    base.advance(by: 1_000_000_000)
    await disabled.value
    #expect(service.leaseRequests.last?.intervalMS == interval)
    await model.setVisibility(window: false, menuBar: true)
    #expect(service.released.contains("gui_window"))
    #expect(service.leaseRequests.last?.kind == .menuBar)
    #expect(service.leaseRequests.last?.intervalMS == .tenSeconds)
    await model.setVisibility(window: false, menuBar: false)
    #expect(model.pollingInterval == nil)
}

@MainActor
@Test func focusFlappingCancelsThePendingLeaseChange() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let base = FakeClock()
    let (events, continuation) = AsyncStream<UInt64>.makeStream()
    let clock = FocusClock(base: base, sleeps: continuation)
    var sleeps = events.makeAsyncIterator()
    let service = try FakeMonitorService()
    service.clock = clock
    let model = try MonitorViewModel(service: service, preferences: prefs, clock: clock)
    await model.setVisibility(window: true, menuBar: false)
    let initial = service.leaseRequests.count
    model.setFocus(appActive: false, keyWindow: false)
    let cancelled = try #require(model.focusUpdate)
    #expect(await sleeps.next() == 1_000_000_000)
    base.advance(by: 500_000_000)
    model.setFocus(appActive: true, keyWindow: true)
    await cancelled.value
    base.advance(by: 2_000_000_000)
    #expect(model.focused)
    #expect(model.focusUpdate == nil)
    #expect(service.leaseRequests.count == initial)
}

@MainActor
@Test func adaptiveRefreshCheckboxPersistsItsDefaultOnPreference() throws {
    _ = NSApplication.shared
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let model = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                      registrationStatus: { "test" }, registerAgent: {})
    let controller = SettingsWindowController(model: model, unregisterAgent: {}, openLoginItems: {})
    defer { controller.window?.close() }
    var changes = 0
    controller.adaptiveRefreshChanged = { changes += 1 }
    #expect(controller.adaptiveRefresh.state == .on)
    controller.adaptiveRefresh.performClick(nil)
    #expect(!prefs.adaptiveRefresh)
    #expect(changes == 1)
    controller.adaptiveRefresh.performClick(nil)
    #expect(prefs.adaptiveRefresh)
    #expect(changes == 2)
}
