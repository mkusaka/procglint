import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct ProcessDetailIntegrationTests {
    @Test(arguments: [false, true], [false, true])
    func mcpDetailScopesAndSchemas(setting: Bool, flag: Bool) async throws {
        let harness = try AgentHarness()
        harness.settings.setAllowedPermissions(setting ? [.includeCommandLines] : [])
        harness.source.update {
            $0.processes[42]?.bsdInfo.ppid = 43
            $0.commandLines[42] = ProcessCommandLine(arguments: ["node", "server.js", "--token=test-secret"])
            $0.commandLines[43] = ProcessCommandLine(arguments: ["zsh", "-l"])
            $0.workingDirectories[42] = WorkingDirectory(value: "/private/project")
        }
        let flags: PermissionSet = flag ? [.includeCommandLines] : []
        let client = harness.client(flags: flags)
        let server = harness.server(client, flags: flags)
        let key = try harness.key()
        let content = try await integrationCall(server, "get_process", arguments: ["process_key": .string(key.rawValue)])
        try Schema.process.validate(content, at: "detail")
        let ancestorJSON = try #require(content["ancestors"])
        let ancestors = try ancestorJSON.decode([ProcessAncestor].self)
        #expect(ancestors.first?.pid == 43)
        #expect(content["ancestors_incomplete"] == true)
        #expect(content["children_count"] == 0)
        if setting, flag {
            #expect(content["command_line"]?["value"] == ["node", "server.js", "--token=<redacted>"])
            #expect(content["cwd"]?["value"] == "/private/project")
            #expect(ancestors.first?.commandLine?.value == ["zsh", "-l"])
        } else {
            #expect(content["command_line"] == nil && content["cwd"] == nil)
            #expect(ancestors.first?.commandLine == nil)
            #expect(harness.source.state.commandLineReads.isEmpty)
        }
        #expect(try !content.text().contains("test-secret"))
        let bulk = try await integrationCall(server, "get_snapshot")
        try Schema.snapshot.validate(bulk, at: "snapshot")
        #expect(try !bulk.text().contains("command_line"))
        await client.invalidate()
        await harness.close()
    }
}
