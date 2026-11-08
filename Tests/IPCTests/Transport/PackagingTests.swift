import Foundation
import ProcglintIPC
import Testing

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

@Test func launchAgentTemplateIsOnDemand() throws {
    let data = try Data(contentsOf: repository.appendingPathComponent("Config/io.github.mkusaka.procglint.agent.plist"))
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == procglintAgentMachServiceName)
    #expect(plist["BundleProgram"] as? String == "Contents/Helpers/procglint-agent")
    #expect(plist["MachServices"] as? [String: Bool] == [procglintAgentMachServiceName: true])
    #expect(plist["ProcessType"] as? String == "Adaptive")
    #expect(plist["KeepAlive"] == nil)
    #expect(plist["RunAtLoad"] == nil)
}

@Test func devScriptUsesPlistEscapingAndOnlyStubbedLaunchctl() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-dev-\(ProcessInfo.processInfo.globallyUniqueString)")
    let bin = home.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let swift = #"""
    #!/bin/bash
    printf 'swift %s\n' "$*" >> "$HOME/commands"
    if [[ "$*" == "build --show-bin-path" ]]; then printf '%s/build & dev\n' "$HOME"; fi
    """#
    let launchctl = #"""
    #!/bin/bash
    printf 'launchctl %s\n' "$*" >> "$HOME/commands"
    case "$1" in
      print)
        case "$2" in
          */io.github.mkusaka.procglint.agent.dev) test -f "$HOME/loaded" ;;
          *) test -f "$HOME/bundled" ;;
        esac ;;
      bootstrap) test -f "$3" && touch "$HOME/loaded" ;;
      bootout) rm "$HOME/loaded" ;;
      *) exit 2 ;;
    esac
    """#
    for (name, script) in [("swift", swift), ("launchctl", launchctl)] {
        let file = bin.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    func run(_ command: String, expectingFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("scripts/dev-agent.sh").path, command]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0, !expectingFailure {
            Issue.record("\(String(data: data, encoding: .utf8) ?? "Invalid script output")")
        }
        return process.terminationStatus
    }
    #expect(try run("start") == 0)
    let path = home.appendingPathComponent("Library/LaunchAgents/io.github.mkusaka.procglint.agent.dev.plist")
    let data = try Data(contentsOf: path)
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Program"] as? String == home.appendingPathComponent("build & dev/procglint-agent").path)
    #expect(plist["ProcessType"] as? String == "Adaptive")
    #expect(plist["MachServices"] as? [String: Bool] == [procglintAgentMachServiceName: true])
    #expect(plist["KeepAlive"] == nil)
    #expect(plist["RunAtLoad"] == nil)
    #expect(try run("status") == 0)
    #expect(try run("start") == 0)
    #expect(try run("stop") == 0)
    #expect(try run("stop") == 0)
    #expect(!FileManager.default.fileExists(atPath: path.path))
    #expect(try run("invalid", expectingFailure: true) == 2)
    try Data().write(to: home.appendingPathComponent("bundled"))
    #expect(try run("start", expectingFailure: true) == 1)
    #expect(!FileManager.default.fileExists(atPath: path.path))
    let commands = try String(contentsOf: home.appendingPathComponent("commands"), encoding: .utf8)
    #expect(commands.contains("swift build --product procglint-agent"))
    #expect(commands.contains("launchctl bootstrap gui/\(getuid()) \(path.path)"))
    #expect(commands.contains("launchctl bootout gui/\(getuid())/io.github.mkusaka.procglint.agent.dev"))
}
