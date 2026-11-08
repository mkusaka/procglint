import Foundation
@testable import ProcglintAgentKit
import Security
import Testing

private func identity(_ path: String, team: String? = nil, requirement: String? = "peer-code") -> SigningIdentity {
    SigningIdentity(teamID: team, executable: URL(fileURLWithPath: path), requirement: requirement)
}

@Test(arguments: [String?.none, "TEAM1"], [String?.none, "TEAM1", "TEAM2"])
func peerAuthorizationDecisionTable(agentTeam: String?, peerTeam: String?) {
    let agent = identity("/Applications/Procglint.app/Contents/Helpers/agent", team: agentTeam, requirement: "agent-code")
    let paths = [
        "/Applications/Procglint.app/Contents/Helpers/client": true,
        "/Applications/Procglint.app/Contents/MacOS/gui": true,
        "/elsewhere/client": false,
        "/Applications/Other.app/Contents/MacOS/gui": false,
    ]
    for (path, isLocal) in paths {
        let peer = identity(path, team: peerTeam)
        for uid: uid_t in [501, 502] {
            let expected = uid == 501 && (agentTeam == nil ? isLocal : agentTeam == peerTeam)
            #expect(PeerAuthorization.allows(agentUID: 501, peerUID: uid, agent: agent, peer: peer) == expected)
            if expected {
                let requirement = PeerAuthorization.connectionRequirement(agent: agent, peer: peer, anonymousSameProcess: false)
                let expectedRequirement = agentTeam.flatMap(PeerAuthorization.teamRequirement) ?? "peer-code"
                #expect(requirement == expectedRequirement)
            }
        }
    }
}

@Test func teamRequirementIsValidAndRejectsUnsafeIdentifiers() throws {
    let text = try #require(PeerAuthorization.teamRequirement("TEAM1"))
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
    #expect(PeerAuthorization.teamRequirement("bad\" or always") == nil)
    #expect(PeerAuthorization.teamRequirement("") == nil)
}

@Test func teamlessTrustIsDirectoryOrContainingAppOnly() {
    let agent = identity("/build/agent")
    let app = identity("/Applications/Procglint.app/Contents/Helpers/agent")
    let cases: [(SigningIdentity, [String: Bool])] = [
        (agent, ["/build/client": true, "/build/subdir/client": false, "/build-other/client": false, "/elsewhere/client": false]),
        (app, ["/Applications/Procglint.app/Contents/MacOS/gui": true,
               "/Applications/Procglint.app/Contents/Helpers/mcp": true,
               "/Applications/Procglint.app.other/Contents/MacOS/gui": false,
               "/Applications/Other.app/Contents/MacOS/gui": false,
               "/Applications/Procglint.app/client": false,
               "/Applications/Procglint.app/Contents/../../../outside": false]),
    ]
    for (own, paths) in cases {
        for (path, expected) in paths {
            #expect(PeerAuthorization.allows(agentUID: 501, peerUID: 501, agent: own, peer: identity(path)) == expected)
        }
    }
    #expect(!PeerAuthorization.allows(agentUID: 501, peerUID: 501, agent: nil, peer: agent))
    #expect(!PeerAuthorization.allows(agentUID: 501, peerUID: 501, agent: agent, peer: nil))
}

@Test func teamlessAgentRequiresPeerCDHashEvenWhenAgentIsUnsigned() {
    let agent = identity("/build/agent", requirement: nil)
    let peer = identity("/build/client")
    #expect(PeerAuthorization.allows(agentUID: 501, peerUID: 501, agent: agent, peer: peer))
    #expect(PeerAuthorization.connectionRequirement(agent: agent, peer: peer, anonymousSameProcess: false) == "peer-code")
    #expect(PeerAuthorization.connectionRequirement(agent: agent, peer: identity("/build/client", requirement: nil), anonymousSameProcess: false) == nil)
    #expect(PeerAuthorization.connectionRequirement(agent: agent, peer: nil, anonymousSameProcess: false) == nil)
}

@Test func teamlessTrustResolvesSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-peer-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appendingPathComponent("client")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
    #expect(!PeerAuthorization.allows(agentUID: 501, peerUID: 501,
                                      agent: identity(directory.appendingPathComponent("agent").path), peer: identity(link.path)))
}

@Test func localTestHostHasUsableCDHashRequirement() throws {
    let current = try #require(SigningIdentity.current())
    let text = try #require(current.requirement)
    #expect(text.hasPrefix("cdhash H\""))
    var requirement: SecRequirement?
    #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
}

@Test func signedTestHostExceptionIsAnonymousSameProcessOnly() {
    let host = identity("/toolchain/testing-helper", team: "TEAM1", requirement: "host-code")
    #expect(PeerAuthorization.connectionRequirement(agent: host, peer: host, anonymousSameProcess: true) == "host-code")
    let teamRequirement = PeerAuthorization.teamRequirement("TEAM1")
    #expect(PeerAuthorization.connectionRequirement(agent: host, peer: host, anonymousSameProcess: false) == teamRequirement)
    #expect(PeerAuthorization.connectionRequirement(agent: host, peer: identity("/other/testing-helper", team: "TEAM1"),
                                                    anonymousSameProcess: true) == teamRequirement)
    #expect(PeerAuthorization.connectionRequirement(agent: host, peer: identity("/toolchain/testing-helper", team: "TEAM1"),
                                                    anonymousSameProcess: true) == teamRequirement)
}
