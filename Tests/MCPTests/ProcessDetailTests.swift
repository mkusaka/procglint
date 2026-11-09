import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct MCPProcessDetailTests {
    @Test(arguments: [false, true])
    func bridgeAlsoFiltersArgumentsWithoutLaunchFlag(enabled: Bool) async throws {
        let service = TestMonitor()
        var process = try sample()
        process.commandLine = ProcessCommandLine(arguments: ["node", "--token=test-secret"])
        process.cwd = WorkingDirectory(value: "/private/project")
        process.ancestors = [ProcessAncestor(pid: 1, name: "launchd", commandLine: ProcessCommandLine(unavailable: .permissionDenied))]
        process.ancestorsIncomplete = false
        process.childrenCount = 0
        await service.configure(detail: process)
        let flags = try MCPFlags.parse(enabled ? ["--include-command-lines"] : [])
        #expect(flags.permissions.contains(.includeCommandLines) == enabled)
        let server = MCPServer(service: service, flags: flags)
        let response = try await call(server, "get_process", ["process_key": .string(process.processKey.rawValue)])
        let content = try #require(response["result"]?["structuredContent"])
        try Schema.process.validate(content, at: "detail")
        #expect(content["ancestors"] != nil && content["children_count"] == 0)
        #expect((content["command_line"] != nil) == enabled)
        #expect((content["cwd"] != nil) == enabled)
        #expect((content["ancestors"]?.elements?.first?["command_line"] != nil) == enabled)
        #expect(try !content.text().contains("test-secret"))
    }
}
