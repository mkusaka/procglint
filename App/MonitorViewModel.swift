import Foundation
import ProcglintCore

@MainActor
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
    private(set) var pinned = false
    private(set) var nextCursor: String?
    private(set) var totalMatched = 0
    private(set) var windowVisible = false
    private(set) var menuBarVisible = false
    private(set) var isFetching = false
    private(set) var terminating = false
    private var leases: [LeaseKind: SamplingLease] = [:]
    private var agentInstanceID: String?
    private var selectionRevision = 0
    private var displayedQuery: ProcessQuery?
    private var terminationMessage = ""
    private var terminationTarget: ProcessKey?
    var message = ""
    var onChange: (@MainActor () -> Void)?

    init(service: any MonitorService, preferences: AppPreferences) throws {
        self.service = service
        self.preferences = preferences
        policy = try preferences.store.samplingPolicy()
        query = try ProcessQuery(filter: .all, limit: 200, fields: ProcessField.allCases.filter { $0 != .path })
    }

    var pollingInterval: TimeInterval? {
        let intervals = [windowVisible ? policy.guiIntervalMS : nil, menuBarVisible ? policy.menuBarIntervalMS : nil].compactMap(\.self)
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

    func setVisibility(window: Bool, menuBar: Bool) async {
        windowVisible = window
        menuBarVisible = menuBar
        onChange?()
        await tick()
    }

    private func wanted(_ kind: LeaseKind) -> SamplingInterval? {
        switch kind {
        case .guiWindow: windowVisible ? policy.guiIntervalMS : nil
        case .menuBar: menuBarVisible ? policy.menuBarIntervalMS : nil
        case .observation: nil
        }
    }

    private func reconcileLeases(renew: Bool) async throws {
        let kinds: [LeaseKind] = [.guiWindow, .menuBar]
        var renewing = renew
        repeat {
            for kind in kinds {
                if let interval = wanted(kind) {
                    if renewing || leases[kind]?.intervalMS != interval {
                        // Even at the slowest 10 s tick this renews well before the GUI's 30 s TTL.
                        leases[kind] = try await service.setLease(LeaseRequest(kind: kind, intervalMS: interval))
                    }
                } else if let lease = leases[kind] {
                    try await service.releaseLease(id: lease.leaseID)
                    leases.removeValue(forKey: kind)
                }
            }
            renewing = false
        } while kinds.contains {
            leases[$0]?.intervalMS != wanted($0)
        }
    }

    func tick() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false; onChange?() }
        do {
            try await reconcileLeases(renew: true)
            if pollingInterval != nil {
                let snapshot = try await service.snapshot(top: 1, sort: .cpu)
                if agentInstanceID != snapshot.agentInstanceID {
                    if agentInstanceID != nil {
                        leases.removeAll()
                    }
                    policy = try await service.policy()
                    try await reconcileLeases(renew: false)
                }
                agentInstanceID = snapshot.agentInstanceID
                header = snapshot.header
                message = snapshot.status == .unavailable ? "unavailable: the agent could not enumerate processes" : ""
                if windowVisible, snapshot.status != .unavailable {
                    // Discard a response for an obsolete query; only request the latest pending query.
                    var requested: ProcessQuery
                    repeat {
                        requested = query
                        let page = try await refreshedPage(requested)
                        if requested == query {
                            apply(page)
                        }
                    } while requested != query && windowVisible
                    await refreshInspector()
                }
            }
        } catch { report(error) }
        // Visibility can change while an IPC request is suspended.
        do { try await reconcileLeases(renew: false) } catch { report(error) }
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
        guard page.snapshot.status != .unavailable else {
            header = page.snapshot
            return
        }
        header = page.snapshot
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
        if let selectedKey {
            detail = rows.first { $0.processKey == selectedKey }
        }
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
        detail = rows.first { $0.processKey == key }
        history = nil
        pinned = false
        terminationMessage = ""
        onChange?()
    }

    func refreshInspector() async {
        guard windowVisible, let key = selectedKey else { return }
        let revision = selectionRevision
        do {
            if try preferences.store.allowedPermissions().contains(.includePaths) {
                let process = try await service.process(key: key)
                guard selectedKey == key, selectionRevision == revision else { return }
                detail = process
            }
            let pinnedQuery = try ProcessQuery(search: detail.map { String($0.pid) }, filter: .pinned, limit: 200)
            let pins = try await service.listProcesses(pinnedQuery)
            guard selectedKey == key, selectionRevision == revision else { return }
            pinned = pins.items.contains { $0.processKey == key }
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
        selectionRevision += 1
        if (try? preferences.store.allowedPermissions().contains(.includePaths)) != true {
            detail?.path = nil
        }
        onChange?()
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
        message = Display.error(error)
        header = nil
        if let error = error as? AgentError, error.code == .agentUnavailable {
            leases.removeAll()
            agentInstanceID = nil
            message += " — Open Settings and register/enable the procglint agent."
        }
    }
}
