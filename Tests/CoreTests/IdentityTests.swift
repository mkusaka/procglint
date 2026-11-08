import Foundation
import ProcglintCore
import Testing

@Test func processKeyRoundTrip() throws {
    let identity = try ProcessIdentity(bootSessionID: "boot-session-a", pid: Int32.max, startTimeUS: UInt64.max)
    let key = ProcessKey(identity: identity)
    #expect(key.rawValue == "p1.boot-session-a.2147483647.18446744073709551615")
    #expect(key.description == key.rawValue)
    #expect(try ProcessKey(key.rawValue).identity == identity)
    try roundTrip(key)
    try roundTrip(identity)
    #expect(try json(identity).contains(#""start_time_us":"18446744073709551615""#))
    #expect(try ProcessKey("p1.boot.0.0").identity.pid == 0)
    #expect(try ProcessKey("p1.boot.0001.0002").rawValue == "p1.boot.1.2")
}

@Test(arguments: ["", "p1", "p2.boot.1.2", "p1..1.2", "p1.boot..2", "p1.boot.1.", "p1.boot.1.2.extra",
                  "p1.boot.-1.2", "p1.boot.1.-2", "p1.boot.2147483648.2", "p1.boot.1.18446744073709551616",
                  "p1.boot.+1.2", "p1.boot.1.+2", "p1.boot. 1.2", "p1.boot.1.2\n", "p1.boot.1.2.3",
                  "p1.bo ot.1.2", "p1.boot.１.2", "p1.boot.1.1e3", "p1.boot.1.0x10"])
func malformedProcessKey(value: String) {
    do {
        _ = try ProcessKey(value)
        Issue.record("Accepted malformed key: \(value)")
    } catch let error as AgentError {
        #expect(error.code == .invalidProcessKey)
    } catch { Issue.record("Unexpected error: \(error)") }
}

@Test func invalidIdentityDecode() throws {
    #expect(throws: AgentError.self) { try ProcessIdentity(bootSessionID: "", pid: 1, startTimeUS: 0) }
    #expect(throws: AgentError.self) { try ProcessIdentity(bootSessionID: "boot", pid: -1, startTimeUS: 0) }
    let invalid = #"{"boot_session_id":"boot","pid":-1,"start_time_us":"0"}"#
    #expect(throws: AgentError.self) { try ProcglintJSON.decoder().decode(ProcessIdentity.self, from: Data(invalid.utf8)) }
}
