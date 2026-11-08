import Foundation
import Security

struct SigningIdentity: Sendable {
    let teamID: String?
    let executable: URL
    let requirement: String?

    static func current() -> SigningIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return read(code)
    }

    static func peer(pid: pid_t) -> SigningIdentity? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        return read(code)
    }

    private static func read(_ code: SecCode) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let result = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard result == errSecSuccess, let info = information as? [String: Any],
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL else { return nil }
        if info[kSecCodeInfoIdentifier as String] == nil {
            return SigningIdentity(teamID: nil, executable: executable, requirement: nil)
        }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let hash = info[kSecCodeInfoUnique as String] as? Data
        let requirement = hash.map { data in "cdhash H\"\(data.map { String(format: "%02x", $0) }.joined())\"" }
        return SigningIdentity(teamID: team, executable: executable, requirement: requirement)
    }
}

enum PeerAuthorization {
    static func allows(agentUID: uid_t, peerUID: uid_t, agent: SigningIdentity?, peer: SigningIdentity?) -> Bool {
        guard agentUID == peerUID, let agent, let peer else { return false }
        if let team = agent.teamID {
            return team == peer.teamID
        }
        let ownPath = agent.executable.resolvingSymlinksInPath().standardizedFileURL
        let peerPath = peer.executable.resolvingSymlinksInPath().standardizedFileURL
        if ownPath.deletingLastPathComponent() == peerPath.deletingLastPathComponent() {
            return true
        }
        let components = ownPath.pathComponents
        guard let app = components.lastIndex(where: { $0.hasSuffix(".app") }),
              components.dropFirst(app + 1).first == "Contents" else { return false }
        let bundleContents = Array(components.prefix(app + 2))
        return peerPath.pathComponents.starts(with: bundleContents)
    }

    static func connectionRequirement(agent: SigningIdentity, peer: SigningIdentity?, anonymousSameProcess: Bool) -> String? {
        // SwiftPM may host test bundles in Apple's signed helper; only anonymous same-process connections use its cdhash.
        if anonymousSameProcess, let peer,
           agent.executable == peer.executable, agent.requirement == peer.requirement
        {
            return agent.requirement
        }
        if let team = agent.teamID {
            return teamRequirement(team)
        }
        return peer?.requirement
    }

    static func teamRequirement(_ team: String) -> String? {
        guard !team.isEmpty, team.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
