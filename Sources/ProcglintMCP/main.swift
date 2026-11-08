import Darwin
import Foundation
import ProcglintIPC
import ProcglintMCPKit

let flags: MCPFlags
do {
    flags = try MCPFlags.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
    exit(64)
}

if flags.help {
    try? FileHandle.standardError.write(contentsOf: Data((MCPFlags.usage + "\n").utf8))
    exit(0)
}

// Let the stdio writer handle a closed pipe as an error rather than a signal.
signal(SIGPIPE, SIG_IGN)
let client = AgentClient(clientKind: .mcp, mcpFlags: flags.permissions)
let server = MCPServer(service: client, flags: flags)
await server.run(input: .standardInput, output: .standardOutput)
await client.invalidate()
