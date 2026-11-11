import Darwin
import Foundation
@testable import ProcglintCore
import Testing

struct NetworkTests {
    @Test func interfaceDeltasHandleFirstResetWrapAndDisappearance() {
        var rates = InterfaceNetworkRates()
        let first: [UInt32: NetworkBytes] = [1: NetworkBytes(received: 100, sent: 200), 2: NetworkBytes(received: 500, sent: 500)]
        #expect(rates.read(first, now: 0).receive == .warmingUp)
        let second: [UInt32: NetworkBytes] = [1: NetworkBytes(received: 300, sent: 800), 3: NetworkBytes(received: 9000, sent: 9000)]
        let delta = rates.read(second, now: 2_000_000_000)
        #expect(delta.receive == .ok(100))
        #expect(delta.send == .ok(300))
        #expect(rates.read([1: NetworkBytes(received: 1, sent: 1)], now: 3_000_000_000).receive == .warmingUp)
        _ = rates.read([1: NetworkBytes(received: UInt64.max, sent: UInt64.max)], now: 4_000_000_000)
        #expect(rates.read([1: NetworkBytes(received: 0, sent: 0)], now: 5_000_000_000).receive == .warmingUp)
        #expect(rates.read(nil, now: 6_000_000_000).receive == .unsupported)
        #expect(rates.read(first, now: 7_000_000_000).receive == .warmingUp)
        #expect(rates.read(first, now: 7_000_000_000).receive == .warmingUp)
    }

    @Test func interfaceParserUses64BitUpNonLoopbackCountersAndRejectsMalformedData() throws {
        func message(index: UInt16, flags: Int32, bytes: UInt64) -> Data {
            var header = if_msghdr2()
            header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
            header.ifm_type = UInt8(RTM_IFINFO2)
            header.ifm_flags = flags
            header.ifm_index = index
            header.ifm_data.ifi_ibytes = bytes
            header.ifm_data.ifi_obytes = bytes + 1
            return withUnsafeBytes(of: header) { Data($0) }
        }
        let data = message(index: 1, flags: IFF_UP, bytes: 9_000_000_000)
            + message(index: 2, flags: IFF_UP | IFF_LOOPBACK, bytes: 100)
            + message(index: 3, flags: 0, bytes: 100)
        #expect(interfaceCounters(data) == [1: NetworkBytes(received: 9_000_000_000, sent: 9_000_000_001)])
        #expect(interfaceCounters(Data([0, 0, 0, 0])) == nil)
        #expect(interfaceCounters(data.dropLast()) == nil)
        #expect(interfaceCounters(Data([1])) == nil)
        #expect(try #require(readInterfaceCounters()).values.allSatisfy { $0.received <= UInt64.max })
    }

    @Test func closedSourcesRemainCumulativeAndExitedOrReusedPIDsAreDropped() {
        let process = NetworkProcess(pid: 42, startTimeUS: 1)
        var totals = NetworkSourceTotals()
        totals.sources[1] = .init(process: process)
        totals.sources[2] = .init(process: process)
        totals.update(1, bytes: NetworkBytes(received: 100, sent: 200))
        totals.update(2, bytes: NetworkBytes(received: 300, sent: 400))
        #expect(totals.totals { _ in 1 }[process] == NetworkBytes(received: 400, sent: 600))
        totals.remove(1)
        totals.remove(1)
        totals.update(2, bytes: NetworkBytes(received: 350, sent: 450))
        #expect(totals.totals { _ in 1 }[process] == NetworkBytes(received: 450, sent: 650))
        totals.update(2, bytes: NetworkBytes(received: 10, sent: 20))
        #expect(totals.totals { _ in 1 }[process] == NetworkBytes(received: 460, sent: 670))
        #expect(totals.totals { _ in 2 }.isEmpty)
        #expect(totals.sources.isEmpty)
        totals.sources[3] = .init(process: process)
        totals.update(3, bytes: NetworkBytes(received: 1, sent: 1))
        #expect(totals.totals { _ in nil }.isEmpty)
    }

    @Test func missingLibraryOrAnySymbolFallsBackWithoutAffectingSystemCounters() async {
        #expect(NStatLibrary(open: { nil }) == nil)
        #expect(NStatLibrary(symbol: { _, _ in nil }) == nil)
        let source = DarwinNetworkSource(library: NStatLibrary(open: { nil }))
        let result = await source.counters()
        #expect(result.processStatus == .unsupported)
        #expect(result.processes.isEmpty)
        #expect(result.interfaces != nil)
    }

    @Test(arguments: ["NStatManagerCreate", "NStatManagerDestroy", "NStatManagerAddAllTCPWithFilter",
                      "NStatManagerAddAllUDPWithFilter", "NStatSourceSetCountsBlock", "NStatSourceSetDescriptionBlock",
                      "NStatSourceSetRemovedBlock", "NStatManagerQueryAllSources", "NStatManagerQueryAllSourcesDescriptions",
                      "NStatSourceQueryDescription", "kNStatSrcKeyPID", "kNStatSrcKeyRxBytes", "kNStatSrcKeyTxBytes"])
    func everyRequiredSymbolHasAnUnsupportedFallback(missing: String) async {
        let library = NStatLibrary(symbol: { handle, name in name == missing ? nil : dlsym(handle, name) })
        #expect(library == nil)
        let result = await DarwinNetworkSource(library: library).counters()
        #expect(result.processStatus == .unsupported)
    }

    @Test func unresponsivePrivateQueryReturnsStaleInsteadOfBlockingTheSampler() async throws {
        let noCompletion: NStatLibrary.Query = { _, _ in }
        let library = try #require(fakeLibrary(queryCounts: noCompletion))
        let result = await DarwinNetworkSource(library: library).counters()
        #expect(result.processStatus == .stale)
        #expect(result.interfaces != nil)
    }

    @Test func synchronousQueryCompletionsReturnOnceWithoutWaitingForTheDeadline() async throws {
        let complete: NStatLibrary.Query = { _, done in done() }
        let library = try #require(fakeLibrary(queryCounts: complete))
        let source = DarwinNetworkSource(library: library)
        #expect(await source.counters().processStatus == .ok)
        #expect(await source.counters().processStatus == .ok)
    }

    @Test func aSingleDirectionResetDoesNotDoubleCountTheOtherDirection() {
        let process = NetworkProcess(pid: 42, startTimeUS: 1)
        var totals = NetworkSourceTotals()
        totals.sources[1] = .init(process: process)
        totals.update(1, bytes: NetworkBytes(received: 100, sent: 200))
        totals.update(1, bytes: NetworkBytes(received: 10, sent: 250))
        #expect(totals.totals { _ in 1 }[process] == NetworkBytes(received: 110, sent: 250))
        totals.remove(1)
        #expect(totals.totals { _ in 1 }[process] == NetworkBytes(received: 110, sent: 250))
    }

    @Test func processRatesHaveIndependentIdentityAndAvailabilityBaselines() throws {
        var processes = try [sample(pid: 42), sample(pid: 43, own: false), sample(pid: 44, own: false)]
        let identity = NetworkProcess(pid: 42, startTimeUS: 1)
        let foreign = NetworkProcess(pid: 44, startTimeUS: 1)
        var rates = ProcessNetworkRates()
        var counters = NetworkCounters(processes: [identity: NetworkBytes(received: 100, sent: 200), foreign: NetworkBytes()], processStatus: .ok)
        rates.read(counters, processes: &processes, now: 0)
        #expect(processes[0].networkReceiveBps == .warmingUp)
        #expect(processes[1].networkReceiveBps == .permissionDenied)
        #expect(processes[2].networkReceiveBps == .warmingUp)
        counters.processes[identity] = NetworkBytes(received: 300, sent: 800)
        rates.read(counters, processes: &processes, now: 2_000_000_000)
        #expect(processes[0].networkReceiveBps == .ok(100))
        #expect(processes[0].networkSendBps == .ok(300))
        #expect(processes[0].networkSentBytes == .ok(800))
        #expect(processes[2].networkReceiveBps == .ok(0))
        processes[0] = try sample(pid: 42, start: 2)
        rates.read(counters, processes: &processes, now: 3_000_000_000)
        #expect(processes[0].networkReceiveBps == .warmingUp)
        rates.read(NetworkCounters(processStatus: .stale), processes: &processes, now: 4_000_000_000)
        #expect(processes[0].networkReceiveBps == .stale)
        rates.read(NetworkCounters(), processes: &processes, now: 5_000_000_000)
        #expect(processes.allSatisfy { $0.networkReceiveBps == .unsupported })
    }

    private func fakeLibrary(queryCounts: @escaping NStatLibrary.Query) -> NStatLibrary? {
        let create: NStatLibrary.Create = { _, _, _ in OpaquePointer(bitPattern: 1) }
        let destroy: NStatLibrary.Destroy = { _ in }
        let add: NStatLibrary.Add = { _, _, _ in 1 }
        let setDictionary: NStatLibrary.SetDictionary = { _, _ in }
        let setRemoved: NStatLibrary.SetRemoved = { _, _ in }
        let complete: NStatLibrary.Query = { _, done in done() }
        let functions = [
            "NStatManagerCreate": unsafeBitCast(create, to: UnsafeMutableRawPointer.self),
            "NStatManagerDestroy": unsafeBitCast(destroy, to: UnsafeMutableRawPointer.self),
            "NStatManagerAddAllTCPWithFilter": unsafeBitCast(add, to: UnsafeMutableRawPointer.self),
            "NStatManagerAddAllUDPWithFilter": unsafeBitCast(add, to: UnsafeMutableRawPointer.self),
            "NStatSourceSetCountsBlock": unsafeBitCast(setDictionary, to: UnsafeMutableRawPointer.self),
            "NStatSourceSetDescriptionBlock": unsafeBitCast(setDictionary, to: UnsafeMutableRawPointer.self),
            "NStatSourceSetRemovedBlock": unsafeBitCast(setRemoved, to: UnsafeMutableRawPointer.self),
            "NStatManagerQueryAllSources": unsafeBitCast(queryCounts, to: UnsafeMutableRawPointer.self),
            "NStatManagerQueryAllSourcesDescriptions": unsafeBitCast(complete, to: UnsafeMutableRawPointer.self),
            "NStatSourceQueryDescription": unsafeBitCast(destroy, to: UnsafeMutableRawPointer.self),
        ]
        var key = "counter" as CFString
        return withUnsafeMutablePointer(to: &key) { keyAddress in
            NStatLibrary(open: { dlopen(nil, RTLD_NOW) }, symbol: { _, name in
                name.hasPrefix("kNStatSrcKey") ? UnsafeMutableRawPointer(keyAddress) : functions[name]
            })
        }
    }

    private func sample(pid: Int32, start: UInt64 = 1, own: Bool = true) throws -> ProcessSample {
        try ProcessSample(processKey: ProcessKey("p1.boot-a.\(pid).\(start)"), pid: pid, name: "worker", uid: own ? 501 : 0, user: "test",
                          isOwn: own, status: .ok, cpuPercent: .warmingUp, cpuTimeNS: nil,
                          footprintBytes: .unsupported, rssBytes: .unsupported, diskReadBytes: .unsupported,
                          diskWrittenBytes: .unsupported, diskReadBps: .unsupported, diskWriteBps: .unsupported, startTime: Date(timeIntervalSince1970: 1))
    }
}
