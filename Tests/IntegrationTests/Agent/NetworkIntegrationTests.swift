import Darwin
import Foundation
@testable import ProcglintCore
import Testing

struct NetworkIntegrationTests {
    @Test func privateManagerStartsAndQueriesAcrossLocalTrafficWithoutCrashing() async throws {
        let library = NStatLibrary()
        if let library, ProcessInfo.processInfo.environment["PROCGLINT_PERF"] == "1" {
            let queue = DispatchQueue(label: "network-probe")
            queue.sync {
                if let manager = library.create(nil, queue, { _ in }) {
                    print("PERF nstat_create=true tcp_result=\(library.addTCP(manager, 0, 0)) udp_result=\(library.addUDP(manager, 0, 0))")
                    library.destroy(manager)
                } else {
                    print("PERF nstat_create=false")
                }
            }
        }
        let source = DarwinNetworkSource(library: library)
        let first = await source.counters()
        #expect(first.interfaces != nil)
        if library == nil {
            #expect(first.processStatus == .unsupported)
            return
        }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        guard listener >= 0 else { return }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        guard bound == 0 else { return }
        let listening = listen(listener, 1)
        #expect(listening == 0)
        guard listening == 0 else { return }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #expect(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        } == 0)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        #expect(client >= 0)
        guard client >= 0 else { return }
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        }
        #expect(connected == 0)
        guard connected == 0 else { return }
        let server = accept(listener, nil, nil)
        #expect(server >= 0)
        guard server >= 0 else { return }
        defer { close(server) }
        let payload = [UInt8](repeating: 1, count: 4096)
        let sent = payload.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        #expect(sent == payload.count)
        guard sent == payload.count else { return }
        var received = [UInt8](repeating: 0, count: payload.count)
        #expect(received.withUnsafeMutableBytes { recv(server, $0.baseAddress, $0.count, MSG_WAITALL) } == payload.count)
        let second = await source.counters()
        // NStat's inclusion of loopback traffic varies by OS; an unbounded timing-based traffic assertion would be flaky.
        #expect([MetricStatus.ok, .unsupported, .stale].contains(second.processStatus))
        #expect(second.processes.keys.allSatisfy { $0.pid > 0 && $0.startTimeUS > 0 })
        if ProcessInfo.processInfo.environment["PROCGLINT_PERF"] == "1" {
            let own = second.processes.filter { $0.key.pid == getpid() }.values
            let processes = try DarwinProcessSource()
            let foreign = second.processes.keys.filter { (try? processes.bsdInfo(pid: $0.pid)?.uid).map { $0 != getuid() } == true }
            print("PERF nstat_status=\(second.processStatus.rawValue) process_count=\(second.processes.count) own_rx=\(own.reduce(0) { $0 + $1.received }) own_tx=\(own.reduce(0) { $0 + $1.sent }) other_uid_processes=\(foreign.count) uid=\(getuid())")
        }
    }
}
