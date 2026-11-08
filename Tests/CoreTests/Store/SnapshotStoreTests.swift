import Foundation
import ProcglintCore
import Testing

@Test func snapshotPagingAndCursorValidation() throws {
    let clock = FakeClock()
    var store = SnapshotStore(clock: clock)
    let processes = try [storeProcess(pid: 1), storeProcess(pid: 2), storeProcess(pid: 3)]
    store.insert(storeSnapshot(processes: processes))
    var query = try ProcessQuery(filter: .all, sort: .pid, order: .asc, limit: 1)
    let first = try store.listProcesses(query, scope: AccessScope())
    #expect(first.items.map(\.pid) == [1])
    query.cursor = try #require(first.nextCursor)
    store.insert(storeSnapshot(2, processes: []))
    let second = try store.listProcesses(query, scope: AccessScope())
    #expect(second.items.map(\.pid) == [2])
    #expect(second.snapshot.snapshotID == first.snapshot.snapshotID)
    #expect(second.totalMatched == 3)
    var foreign = SnapshotStore(clock: clock)
    foreign.insert(storeSnapshot(processes: processes))
    #expect(throws: AgentError.self) { try foreign.listProcesses(query, scope: AccessScope()) }
    #expect(throws: AgentError.self) { try store.listProcesses(query, scope: AccessScope(includePaths: true)) }
    store.insert(storeSnapshot(3))
    do {
        _ = try store.listProcesses(query, scope: AccessScope())
        Issue.record("Expired cursor accepted")
    } catch let error as AgentError { #expect(error.code == .invalidCursor) }
    query.cursor = "not-a-cursor"
    #expect(throws: AgentError.self) { try store.listProcesses(query, scope: AccessScope()) }
}

@Test func snapshotScopeSearchPinsAndFields() throws {
    let clock = FakeClock()
    var store = SnapshotStore(clock: clock)
    let own = try storeProcess(pid: 42, name: "Worker")
    let system = try storeProcess(pid: 1, name: "System", own: false, path: "/private/system")
    store.insert(storeSnapshot(processes: [system, own]))
    let all = try ProcessQuery(filter: .all)
    let privileged = AccessScope(includeSystem: true, includePaths: true)
    #expect(try store.listProcesses(all, scope: privileged).items.count == 2)
    let restricted = try store.listProcesses(all, scope: AccessScope())
    #expect(restricted.items.count == 1)
    #expect(restricted.items.first?.path == nil)
    #expect(store.latest()?.processes == restricted.items)
    #expect(try store.listProcesses(ProcessQuery(filter: .mine), scope: privileged).items.map(\.pid) == [42])
    #expect(try store.listProcesses(ProcessQuery(search: "wORk"), scope: privileged).items.map(\.pid) == [42])
    #expect(try store.listProcesses(ProcessQuery(search: "42", filter: .all), scope: privileged).items.map(\.pid) == [42])
    #expect(try store.listProcesses(ProcessQuery(search: "4", filter: .all), scope: privileged).items.isEmpty)
    #expect(try store.listProcesses(ProcessQuery(filter: .pinned), scope: privileged, pinned: [own.processKey]).items.map(\.pid) == [42])
    let data = try store.listProcessesJSON(ProcessQuery(filter: .all, fields: [.name, .path]), scope: AccessScope())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try #require(object["items"] as? [[String: Any]])
    #expect(try Set(#require(items.first).keys) == ["process_key", "name"])
    let minimal = try restricted.jsonData(fields: [])
    let minimalObject = try #require(JSONSerialization.jsonObject(with: minimal) as? [String: Any])
    let minimalItems = try #require(minimalObject["items"] as? [[String: Any]])
    #expect(try Set(#require(minimalItems.first).keys) == ["process_key"])
    // Exercise eviction across all four scopes and multiple snapshot generations.
    for index in 2 ... 10 {
        store.insert(storeSnapshot(index, processes: [system, own]))
        for paths in [false, true] {
            for includeSystem in [false, true] {
                let scope = AccessScope(includeSystem: includeSystem, includePaths: paths)
                let page = try store.listProcesses(all, scope: scope)
                #expect(page.items.count == (includeSystem ? 2 : 1))
                #expect(page.items.allSatisfy { paths || $0.path == nil })
            }
        }
    }
}

@Test func snapshotSortsAndMonotonicAge() throws {
    let clock = FakeClock()
    var store = SnapshotStore(clock: clock)
    var low = try storeProcess(pid: 2, name: "Alpha", cpu: .ok(1))
    var high = try storeProcess(pid: 3, name: "Beta", cpu: .ok(2))
    var missing = try storeProcess(pid: 1, name: "Gamma", cpu: .permissionDenied)
    missing.cpuTimeNS = nil
    missing.diskReadBps = .warmingUp
    missing.diskWriteBps = .unsupported
    low.diskReadBps = .ok(1)
    low.diskWriteBps = .ok(1)
    high.diskReadBps = .ok(2)
    high.diskWriteBps = .ok(2)
    store.insert(storeSnapshot(processes: [missing, high, low]))
    for sort in ProcessSort.allCases {
        let ascending = try store.listProcesses(ProcessQuery(sort: sort, order: .asc), scope: AccessScope())
        let descending = try store.listProcesses(ProcessQuery(sort: sort), scope: AccessScope())
        switch sort {
        case .pid, .footprint, .rss:
            #expect(ascending.items.map(\.pid) == [1, 2, 3])
            #expect(descending.items.map(\.pid) == [3, 2, 1])
        case .name:
            #expect(ascending.items.map(\.pid) == [2, 3, 1])
            #expect(descending.items.map(\.pid) == [1, 3, 2])
        default:
            #expect(ascending.items.map(\.pid) == [2, 3, 1])
            #expect(descending.items.map(\.pid) == [3, 2, 1])
        }
    }
    clock.advance(by: 3_001_000_000)
    #expect(store.latest(effectiveInterval: .oneSecond)?.ageMS == 3001)
    #expect(store.latest(effectiveInterval: .oneSecond)?.status == .stale)
    #expect(store.latest()?.status == .ok)
    clock.advance(by: 12_000_000_000)
    #expect(store.latest()?.status == .stale)
    var unavailable = storeSnapshot(2)
    unavailable.status = .unavailable
    store.insert(unavailable)
    clock.advance(by: 20_000_000_000)
    #expect(store.latest()?.status == .unavailable)
    var invalid = try ProcessQuery()
    invalid.limit = 0
    #expect(throws: AgentError.self) { try store.listProcesses(invalid, scope: AccessScope()) }
}
