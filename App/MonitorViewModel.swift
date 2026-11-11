import Foundation
import Observation

// Selective imports avoid the wire Observation type shadowing the Observation framework in macro expansion.
import enum ProcglintCore.AgentError
import struct ProcglintCore.HistoryRequest
import struct ProcglintCore.HistorySeries
import enum ProcglintCore.LeaseKind
import struct ProcglintCore.LeaseRequest
import protocol ProcglintCore.MonitorService
import protocol ProcglintCore.MonotonicClock
import struct ProcglintCore.PermissionSet
import enum ProcglintCore.ProcessField
import enum ProcglintCore.ProcessFilter
import struct ProcglintCore.ProcessKey
import struct ProcglintCore.ProcessPage
import struct ProcglintCore.ProcessQuery
import struct ProcglintCore.ProcessSample
import enum ProcglintCore.SamplingInterval
import struct ProcglintCore.SamplingLease
import struct ProcglintCore.SamplingPolicy
import struct ProcglintCore.SnapshotHeader
import struct ProcglintCore.SystemMonotonicClock
import enum ProcglintCore.TerminationSignal
import ProcglintIPC

@MainActor
@Observable
final class MonitorViewModel {
    let service: any MonitorService
    let preferences: AppPreferences
    private(set) var policy: SamplingPolicy
    private(set) var query: ProcessQuery
    private(set) var header: SnapshotHeader?
    private(set) var rows: [ProcessSample] = []
    private(set) var selectedKey: ProcessKey?
    private(set) var detail: ProcessSample?
    private(set) var history: HistorySeries?
    private(set) var systemHistory: HistorySeries?
    private(set) var memorySummaryHistory: [MemorySummaryPoint] = []
    private(set) var permissions: PermissionSet
    let chartSelection = ChartSelection()
    private var memoryHistoryInterrupted = true
    private var memoryHistorySnapshotID: String?
    private(set) var selectionUpdate: Task<Void, Never>?
    private(set) var pinned = false
    private(set) var nextCursor: String?
    private(set) var totalMatched = 0
    private(set) var windowVisible = false
    private(set) var menuBarVisible = false
    private(set) var isFetching = false
    private(set) var focused = true
    @ObservationIgnored private(set) var focusUpdate: Task<Void, Never>?
    private(set) var terminating = false
    private(set) var agentReachable = false
    let registrationStatus: @MainActor () -> AgentRegistration.Status

    var showsAgentBanner: Bool {
        AgentSetup(status: registrationStatus(), reachable: agentReachable).showsBanner
    }

    private let clock: any MonotonicClock
    private var historySnapshotID: String?
    private var historySelectedKey: ProcessKey?
    private var historyCursor: String?
    private var leases: [LeaseKind: SamplingLease] = [:]
    private var leaseUpdate: Task<Void, any Error>?
    private var leaseProcessKeys: [ProcessKey] = []
    private var historyLeaseMessage = ""
    private var agentInstanceID: String?
    private var selectionRevision = 0
    private(set) var displayedQuery: ProcessQuery?
    private var terminationMessage = ""
    private var terminationTarget: ProcessKey?
    var message = ""
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(service: any MonitorService, preferences: AppPreferences, clock: any MonotonicClock = SystemMonotonicClock(),
         registrationStatus: @escaping @MainActor () -> AgentRegistration.Status = { .enabled }) throws
    {
        self.service = service
        self.preferences = preferences
        self.clock = clock
        self.registrationStatus = registrationStatus
        policy = try preferences.store.samplingPolicy()
        permissions = try preferences.store.allowedPermissions()
        query = try ProcessQuery(filter: .all, limit: 200, fields: ProcessField.allCases.filter { $0 != .path })
    }

    deinit { focusUpdate?.cancel() }

    private var windowInterval: SamplingInterval {
        guard preferences.adaptiveRefresh, !focused else { return policy.guiIntervalMS }
        switch policy.guiIntervalMS {
        case .oneSecond: return .twoSeconds
        case .twoSeconds: return .fiveSeconds
        case .fiveSeconds, .tenSeconds: return .tenSeconds
        }
    }

    func setFocus(appActive: Bool, keyWindow: Bool) {
        let focused = appActive && keyWindow
        focusUpdate?.cancel()
        focusUpdate = nil
        guard self.focused != focused else { return }
        let deadline = clock.now + 1_000_000_000
        let clock = clock
        focusUpdate = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                guard let self else { return }
                focusUpdate = nil
                self.focused = focused
                await tick()
            } catch { /* A newer focus event replaces the pending change. */ }
        }
    }

    var pollingInterval: TimeInterval? {
        let intervals = [windowVisible ? windowInterval : nil, menuBarVisible ? policy.menuBarIntervalMS : nil].compactMap(\.self)
        return intervals.map { Double($0.rawValue) / 1000 }.min()
    }

    var summary: String {
        Display.summary(header)
    }

    var inspectorMessage: String {
        terminationMessage.isEmpty || terminationTarget != selectedKey ? message : terminationMessage
    }

    func setSearch(_ search: String) {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        query.search = trimmed.isEmpty ? nil : trimmed
        query.cursor = nil
    }

    func setFilter(_ filter: ProcessFilter) {
        query.filter = filter; query.cursor = nil
    }

    func setSort(column: ProcessColumn, ascending: Bool) {
        guard let sort = column.sort else { return }
        query.sort = sort
        query.order = ascending ? .asc : .desc
        query.cursor = nil
    }

    func setPolicy(_ policy: SamplingPolicy) {
        self.policy = policy
        onChange?()
    }

    func agentDidReconnect() async {
        // A replacement connection has new lease ownership even if the agent instance is unchanged.
        leases.removeAll()
        await tick()
    }

    func setVisibility(window: Bool, menuBar: Bool) async {
        if !window {
            memoryHistoryInterrupted = true; chartSelection.clear()
        }
        windowVisible = window
        menuBarVisible = menuBar
        onChange?()
        await tick()
    }

    private func wanted(_ kind: LeaseKind) -> SamplingInterval? {
        switch kind {
        case .guiWindow: windowVisible ? windowInterval : nil
        case .menuBar: menuBarVisible ? policy.menuBarIntervalMS : nil
        case .observation: nil
        }
    }

    private func reconcileLeases(renew: Bool) async throws {
        while let leaseUpdate {
            try await leaseUpdate.value
        }
        // Selection and visibility can change while IPC is suspended; only one writer installs leases.
        let update = Task {
            defer { self.leaseUpdate = nil }
            try await self.updateLeases(renew: renew)
        }
        leaseUpdate = update
        try await update.value
    }

    private var selectedProcessKeys: [ProcessKey] {
        selectedKey.map { [$0] } ?? []
    }

    private func updateLeases(renew: Bool) async throws {
        let kinds: [LeaseKind] = [.guiWindow, .menuBar]
        var renewing = renew
        repeat {
            for kind in kinds {
                if let interval = wanted(kind) {
                    let keys = kind == .guiWindow ? selectedProcessKeys : []
                    let renewalDue = renewing && (leases[kind]?.expiresAt ?? 0) < clock.now + 2 * interval.nanoseconds
                    let retryHistory = renewing && kind == .guiWindow && !historyLeaseMessage.isEmpty
                    if renewalDue || retryHistory || leases[kind]?.intervalMS != interval || (kind == .guiWindow && leaseProcessKeys != keys) {
                        do {
                            leases[kind] = try await service.setLease(LeaseRequest(kind: kind, intervalMS: interval, processKeys: keys))
                            if kind == .guiWindow {
                                if !historyLeaseMessage.isEmpty {
                                    historySnapshotID = nil
                                }
                                historyLeaseMessage = ""
                            }
                        } catch let error as AgentError where !keys.isEmpty && (error.code == .historyLimitReached || error.code == .notFound) {
                            // Explicit ownership can be full; automatic history is still available.
                            leases[kind] = try await service.setLease(LeaseRequest(kind: kind, intervalMS: interval))
                            historyLeaseMessage = error.code == .notFound ? Display.error(error) : ""
                            message = historyLeaseMessage
                        }
                        if kind == .guiWindow {
                            leaseProcessKeys = keys
                        }
                    }
                } else if let lease = leases[kind] {
                    try await service.releaseLease(id: lease.leaseID)
                    leases.removeValue(forKey: kind)
                }
            }
            renewing = false
        } while kinds.contains {
            leases[$0]?.intervalMS != wanted($0)
        } || (windowVisible && leaseProcessKeys != selectedProcessKeys)
    }

    func tick() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false; onChange?() }
        do {
            try await reconcileLeases(renew: true)
            if pollingInterval != nil {
                if windowVisible {
                    // ProcessPage already carries the complete system header.
                    var requested: ProcessQuery
                    repeat {
                        requested = query
                        let page = try await refreshedPage(requested)
                        if requested == query, windowVisible {
                            apply(page)
                        }
                    } while requested != query && windowVisible
                } else {
                    try await updateHeader(service.snapshot(top: 1, sort: .cpu).header)
                    agentReachable = true
                }
                if let header {
                    if agentInstanceID != header.agentInstanceID {
                        systemHistory = nil
                        history = nil
                        historySnapshotID = nil
                        historyCursor = nil
                        if agentInstanceID != nil {
                            leases.removeAll()
                        }
                        policy = try await service.policy()
                        try await reconcileLeases(renew: false)
                    }
                    agentInstanceID = header.agentInstanceID
                    message = header.status == .unavailable ? "unavailable: the agent could not enumerate processes" : historyLeaseMessage
                    if windowVisible, header.status != .unavailable,
                       historySnapshotID != header.snapshotID || historySelectedKey != selectedKey
                    {
                        await refreshInspector(refreshHistory: false)
                        let key = selectedKey
                        let revision = selectionRevision
                        let selectors = ["system"] + (historyLeaseMessage.isEmpty ? selectedProcessKeys.map(\.rawValue) : [])
                        let request = HistoryRequest(series: selectors, cursor: historyCursor ?? "")
                        let series: [HistorySeries]
                        do {
                            series = try await service.history(request)
                        } catch let error as AgentError where selectors.count > 1 && error.code == .notFound {
                            // A selection can exit after the page arrives; keep the independent system chart live.
                            message = Display.error(error)
                            series = try await service.history(HistoryRequest(series: ["system"], cursor: request.cursor))
                        }
                        if windowVisible, selectionRevision == revision {
                            systemHistory = Self.appending(series.first { $0.series == "system" }, to: systemHistory)
                            history = Self.appending(series.first { $0.series == key?.rawValue }, to: history)
                            historyCursor = series.compactMap(\.nextCursor).first
                            historySnapshotID = header.snapshotID
                            historySelectedKey = key
                        }
                    }
                }
            }
        } catch { report(error) }
        // Visibility can change while an IPC request is suspended.
        do { try await reconcileLeases(renew: false) } catch { report(error) }
    }

    private static func appending(_ incoming: HistorySeries?, to previous: HistorySeries?) -> HistorySeries? {
        guard var incoming else { return nil }
        if incoming.isDelta, let previous, previous.series == incoming.series, let count = incoming.retainedPointCount {
            incoming.points = Array((previous.points + incoming.points).suffix(count))
            incoming.isDelta = false
        }
        return incoming
    }

    private func refreshedPage(_ requested: ProcessQuery) async throws -> ProcessPage {
        let visibleCount = displayedQuery == requested ? rows.count : 0
        var page = try await service.listProcesses(requested)
        // Refresh only pages the user has already loaded; query changes start with one page.
        while page.items.count < visibleCount, let cursor = page.nextCursor,
              page.snapshot.status != .unavailable, requested == query, windowVisible
        {
            var next = requested
            next.cursor = cursor
            let more = try await service.listProcesses(next)
            guard more.snapshot.snapshotID == page.snapshot.snapshotID,
                  more.snapshot.agentInstanceID == page.snapshot.agentInstanceID,
                  !more.items.isEmpty, more.nextCursor != cursor
            else {
                throw AgentError.invalidCursor("Paging changed or made no progress; refresh the list")
            }
            page.items += more.items
            page.nextCursor = more.nextCursor
        }
        return page
    }

    func apply(_ page: ProcessPage, append: Bool = false) {
        agentReachable = true
        let sameSnapshot = header?.snapshotID == page.snapshot.snapshotID && header?.agentInstanceID == page.snapshot.agentInstanceID
        guard page.snapshot.status != .unavailable else {
            updateHeader(page.snapshot)
            return
        }
        updateHeader(page.snapshot)
        if append {
            let existing = Set(rows.map(\.processKey))
            rows += page.items.filter { !existing.contains($0.processKey) }
        } else {
            rows = page.items
            displayedQuery = query
        }
        totalMatched = page.totalMatched
        nextCursor = page.nextCursor
        if let selectedKey, !rows.contains(where: { $0.processKey == selectedKey }) {
            select(nil)
        }
        if let selectedKey, !sameSnapshot || detail?.processKey != selectedKey {
            detail = rows.first { $0.processKey == selectedKey }
        }
    }

    private func updateHeader(_ header: SnapshotHeader) {
        let restarted = self.header?.agentInstanceID != header.agentInstanceID
        if self.header != header {
            self.header = header
        }
        if header.status == .unavailable {
            memoryHistoryInterrupted = true
        }
        guard windowVisible, header.status != .unavailable,
              restarted || memoryHistorySnapshotID != header.snapshotID else { return }
        if memorySummaryHistory.last.map({ $0.time >= header.sampledAt }) == true || restarted {
            memorySummaryHistory.removeAll()
        }
        memorySummaryHistory.append(MemorySummaryPoint(time: header.sampledAt, swap: header.system.swapUsedBytes,
                                                       compressed: .ok(Double(header.system.compressedBytes)), startsSegment: memoryHistoryInterrupted))
        let cutoff = header.sampledAt.addingTimeInterval(-Double(policy.historyMinutes * 60))
        memorySummaryHistory = Array(memorySummaryHistory.filter { $0.time >= cutoff }.suffix(600))
        memoryHistoryInterrupted = false
        memoryHistorySnapshotID = header.snapshotID
    }

    func loadMore() async {
        guard !isFetching, windowVisible, let nextCursor, let header else { return }
        isFetching = true
        defer { isFetching = false; onChange?() }
        var requested = query
        requested.cursor = nextCursor
        do {
            let page = try await service.listProcesses(requested)
            var original = requested
            original.cursor = nil
            if original == query {
                guard page.snapshot.snapshotID == header.snapshotID, page.snapshot.agentInstanceID == header.agentInstanceID else {
                    throw AgentError.invalidCursor("Snapshot changed; refresh the list")
                }
                apply(page, append: true)
            }
        } catch { message = Display.error(error) }
        do { try await reconcileLeases(renew: false) } catch { report(error) }
    }

    func select(_ key: ProcessKey?) {
        guard selectedKey != key else { return }
        selectionRevision += 1
        selectedKey = key
        chartSelection.clear()
        detail = rows.first { $0.processKey == key }
        history = nil
        historyCursor = nil
        historySnapshotID = nil
        pinned = false
        terminationMessage = ""
        onChange?()
        selectionUpdate = Task { [weak self] in
            guard let self else { return }
            do { try await reconcileLeases(renew: false) } catch { report(error) }
            onChange?()
        }
    }

    func refreshInspector(refreshHistory: Bool = true) async {
        guard windowVisible, let key = selectedKey else { return }
        let revision = selectionRevision
        do {
            try await reconcileLeases(renew: false)
            guard windowVisible, selectedKey == key, selectionRevision == revision else { return }
            var process = try await service.process(key: key)
            guard selectedKey == key, selectionRevision == revision else { return }
            permissions = try preferences.store.allowedPermissions()
            if !permissions.contains(.includeCommandLines) {
                process.hideCommandLines()
            }
            if !permissions.contains(.includePaths) {
                process.path = nil
            }
            if detail != process {
                detail = process
            }
            if query.filter == .pinned {
                pinned = rows.contains { $0.processKey == key }
            } else {
                let pinnedQuery = try ProcessQuery(search: detail.map { String($0.pid) }, filter: .pinned, limit: 200)
                let pins = try await service.listProcesses(pinnedQuery)
                guard selectedKey == key, selectionRevision == revision else { return }
                pinned = pins.items.contains { $0.processKey == key }
            }
            guard refreshHistory, historyLeaseMessage.isEmpty else { return }
            historyCursor = nil
            historySnapshotID = nil
            let series = try await service.history(HistoryRequest(series: [key.rawValue], since: Date().addingTimeInterval(-Double(policy.historyMinutes * 60))))
            guard selectedKey == key, selectionRevision == revision else { return }
            history = series.first { $0.series == key.rawValue }
        } catch {
            guard selectedKey == key, selectionRevision == revision else { return }
            message = Display.error(error)
        }
        onChange?()
    }

    func permissionsChanged() {
        permissions = (try? preferences.store.allowedPermissions()) ?? []
        selectionRevision += 1
        if (try? preferences.store.allowedPermissions().contains(.includePaths)) != true {
            detail?.path = nil
        }
        if (try? preferences.store.allowedPermissions().contains(.includeCommandLines)) != true {
            detail?.hideCommandLines()
        }
        historySnapshotID = nil
        onChange?()
        selectionUpdate = Task { await refreshInspector(refreshHistory: false) }
    }

    func togglePin() async {
        guard let key = selectedKey else { return }
        let desired = !pinned
        do {
            try await service.pin(key: key, pinned: desired)
            if selectedKey == key {
                pinned = desired
            }
            await refreshInspector()
        } catch { message = Display.error(error) }
        onChange?()
    }

    func terminate(signal: TerminationSignal, confirm: @MainActor (ProcessSample, TerminationSignal) async -> Bool) async {
        guard !terminating, let target = detail, selectedKey == target.processKey else { return }
        terminating = true
        onChange?()
        defer { terminating = false; onChange?() }
        guard await confirm(target, signal) else { return }
        terminationTarget = target.processKey
        // The confirmation authorizes this identity, never whichever row is selected later.
        do {
            let ticket = try await service.prepareTermination(key: target.processKey, signal: signal)
            let result = try await service.terminate(token: ticket.token)
            if result.outcome == .rejected {
                terminationMessage = "Rejected: \(result.rejection?.rawValue ?? "unknown")"
            } else {
                terminationMessage = result.exitedConfirmed ? "Exited (confirmed)" : "Signal sent; exit not confirmed"
            }
        } catch { terminationMessage = Display.error(error) }
    }

    private func report(_ error: any Error) {
        memoryHistoryInterrupted = true
        message = Display.error(error)
        header = nil
        if let error = error as? AgentError, error.code == .agentUnavailable {
            agentReachable = false
            leases.removeAll()
            agentInstanceID = nil
            message += " — Open Settings and register/enable the procglint agent."
        }
    }
}
