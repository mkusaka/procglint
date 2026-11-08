import Foundation
@testable import ProcglintCore
import Testing

@Test func sortedQueryCacheReusesOrderingAcrossSearchLimitsAndPages() throws {
    var store = SnapshotStore(clock: FakeClock())
    let rows = try [storeProcess(pid: 2, name: "beta"), storeProcess(pid: 1, name: "alpha")]
    store.insert(storeSnapshot(processes: rows))
    var query = try ProcessQuery(filter: .all, sort: .pid, order: .asc, limit: 1)
    let first = try store.listProcesses(query, scope: AccessScope())
    query.cursor = try #require(first.nextCursor)
    #expect(try store.listProcesses(query, scope: AccessScope()).items.map(\.pid) == [2])
    #expect(try store.listProcesses(ProcessQuery(search: "beta", filter: .all, sort: .pid, order: .asc, limit: 200, fields: [.name]), scope: AccessScope()).items.map(\.pid) == [2])
    #expect(store.querySortCount == 1)
    #expect(store.responseCacheCount == 1)
    store.insert(storeSnapshot(2, processes: rows))
    #expect(store.responseCacheCount == 0)
    // Paging still resolves the retained snapshot after cache invalidation.
    #expect(try store.listProcesses(query, scope: AccessScope()).snapshot.snapshotID == first.snapshot.snapshotID)
    #expect(store.querySortCount == 2)
}

@Test func sortedQueryCacheSeparatesScopeFilterOrderAndPins() throws {
    var store = SnapshotStore(clock: FakeClock())
    let own = try storeProcess(pid: 2, path: "/own")
    let other = try storeProcess(pid: 1, own: false, path: "/other")
    store.insert(storeSnapshot(processes: [own, other]))
    let wide = AccessScope(includeSystem: true, includePaths: true)
    let ascending = try ProcessQuery(filter: .all, sort: .pid, order: .asc)
    #expect(try store.listProcesses(ascending, scope: wide).items.map(\.pid) == [1, 2])
    let restricted = try store.listProcesses(ascending, scope: AccessScope())
    #expect(restricted.items.map(\.pid) == [2])
    #expect(restricted.items.first?.path == nil)
    #expect(try store.listProcesses(ProcessQuery(filter: .mine, sort: .pid, order: .asc), scope: wide).items.map(\.pid) == [2])
    #expect(try store.listProcesses(ProcessQuery(filter: .all, sort: .pid), scope: wide).items.map(\.pid) == [2, 1])
    let pins = try ProcessQuery(filter: .pinned, sort: .pid)
    #expect(try store.listProcesses(pins, scope: wide, pinned: [own.processKey]).items.map(\.pid) == [2])
    #expect(try store.listProcesses(pins, scope: wide, pinned: [other.processKey]).items.map(\.pid) == [1])
    #expect(store.querySortCount == 6)
    for sort in ProcessSort.allCases {
        _ = try store.listProcesses(ProcessQuery(filter: .all, sort: sort), scope: wide)
        #expect(store.responseCacheCount <= 8)
    }
}
