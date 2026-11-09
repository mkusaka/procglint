import Foundation
import Testing

private let repositoryURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = repositoryURL
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return try (process.terminationStatus, #require(String(data: data, encoding: .utf8)))
}

private func plist(at url: URL) throws -> [String: Any] {
    let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    return try #require(value as? [String: Any])
}

@Test(arguments: [
    ["--configuration"], ["--configuration", "invalid"],
    ["--sign"], ["--sign", ""], ["--unknown"],
])
func bundleBuildRejectsInvalidArguments(arguments: [String]) throws {
    let result = try run("/bin/bash", ["scripts/build-app.sh"] + arguments)
    #expect(result.status == 2)
    #expect(result.output.contains("Usage:"))
}

@Test(arguments: ["MARKETING_VERSION", "BUILD_VERSION"], ["", "invalid"])
func bundleBuildRejectsInvalidVersions(key: String, value: String) throws {
    var environment = ProcessInfo.processInfo.environment
    environment[key] = value
    let result = try run("/bin/bash", ["scripts/build-app.sh"], environment: environment)
    #expect(result.status == 2)
    #expect(result.output.contains("numeric components"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROCGLINT_BUNDLE_TEST"] == "1"))
func builtAppHasExpectedLayoutMetadataAndSignatures() throws {
    var environment = ProcessInfo.processInfo.environment
    environment["MARKETING_VERSION"] = "2.3.4"
    environment["BUILD_VERSION"] = "42"
    let build = try run("/bin/bash", ["scripts/build-app.sh", "--configuration", "debug"], environment: environment)
    try #require(build.status == 0, "\(build.output)")

    let app = repositoryURL.appendingPathComponent("build/Procglint.app")
    let contents = app.appendingPathComponent("Contents")
    let binaries = ["MacOS/procglint-gui", "Helpers/procglint-agent", "Helpers/procglint-mcp", "Helpers/procglint"]
    for binary in binaries {
        let url = contents.appendingPathComponent(binary)
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        let architecture = try run("/usr/bin/lipo", ["-archs", url.path])
        #expect(architecture.status == 0, "\(architecture.output)")
        #expect(architecture.output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64")
        let signature = try run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        #expect(signature.status == 0, "\(signature.output)")
    }
    #expect(build.output.contains("MCP helper: " + contents.appendingPathComponent("Helpers/procglint-mcp").path))

    let info = try plist(at: contents.appendingPathComponent("Info.plist"))
    let expected = [
        "CFBundleIdentifier": "io.github.mkusaka.procglint",
        "CFBundleName": "Procglint",
        "CFBundleExecutable": "procglint-gui",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": "2.3.4",
        "CFBundleVersion": "42",
        "LSMinimumSystemVersion": "15.0",
        "NSPrincipalClass": "NSApplication",
        "LSApplicationCategoryType": "public.app-category.utilities",
    ]
    for (key, value) in expected {
        #expect(info[key] as? String == value)
    }
    #expect(info["NSHighResolutionCapable"] as? Bool == true)
    let revision = try run("/usr/bin/git", ["rev-parse", "--short", "HEAD"])
    let dirty = try run("/usr/bin/git", ["status", "--porcelain"])
    let expectedCommit = revision.output.trimmingCharacters(in: .whitespacesAndNewlines) + (dirty.output.isEmpty ? "" : "-dirty")
    #expect(info["ProcglintGitCommit"] as? String == expectedCommit)
    let version = try run(contents.appendingPathComponent("Helpers/procglint").path, ["--version"])
    #expect(version.status == 0)
    #expect(version.output == "procglint 2.3.4 (\(expectedCommit))\n")

    let plistName = "io.github.mkusaka.procglint.agent.plist"
    let agent = try plist(at: contents.appendingPathComponent("Library/LaunchAgents/" + plistName))
    let source = try plist(at: repositoryURL.appendingPathComponent("Config/" + plistName))
    #expect(NSDictionary(dictionary: agent).isEqual(to: source))
    #expect(agent["Label"] as? String == "io.github.mkusaka.procglint.agent")
    #expect(agent["BundleProgram"] as? String == "Contents/Helpers/procglint-agent")
    #expect(agent["MachServices"] as? [String: Bool] == ["io.github.mkusaka.procglint.agent": true])
    #expect(agent["ProcessType"] as? String == "Adaptive")
    #expect(agent["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(agent["RunAtLoad"] == nil)
    #expect(agent["KeepAlive"] == nil)

    let signature = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    #expect(signature.status == 0, "\(signature.output)")
    let details = try run("/usr/bin/codesign", ["--display", "--verbose=4", app.path])
    #expect(details.status == 0, "\(details.output)")
    #expect(details.output.contains("Signature=adhoc"))
    #expect(details.output.contains("runtime"))
    #expect(!details.output.contains("Timestamp="))
}
