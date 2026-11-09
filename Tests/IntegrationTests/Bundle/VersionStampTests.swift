import Foundation
import Testing

@Test(arguments: ["clean", "dirty", "missing"])
func bundleCommitStampHandlesGitStates(state: String) throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-stamp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for directory in ["scripts", "Config", "bin"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for path in ["scripts/build-app.sh", "Config/Info.plist", "Config/io.github.mkusaka.procglint.agent.plist"] {
        try FileManager.default.copyItem(at: repository.appendingPathComponent(path), to: root.appendingPathComponent(path))
    }
    let stubs = [
        "swift": "#!/bin/bash\nif [[ \"$*\" == *--show-bin-path* ]]; then printf '%s/bin\\n' \"$PWD\"; fi\n",
        "git": """
        #!/bin/bash
        if [[ "$PROCGLINT_TEST_GIT" == missing ]]; then exit 1; fi
        case "$1" in
          rev-parse) echo abc1234 ;;
          status) if [[ "$PROCGLINT_TEST_GIT" == dirty ]]; then echo ' M App/Display.swift'; fi ;;
          *) exit 1 ;;
        esac
        """,
        "codesign": "#!/bin/bash\nexit 0\n",
    ]
    for (name, script) in stubs {
        let file = root.appendingPathComponent("bin/" + name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    for binary in ["procglint-gui", "procglint-agent", "procglint-mcp", "procglint"] {
        try Data().write(to: root.appendingPathComponent("bin/" + binary))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [root.appendingPathComponent("scripts/build-app.sh").path, "--configuration", "debug"]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = root.appendingPathComponent("bin").path + ":/usr/bin:/bin"
    environment["PROCGLINT_TEST_GIT"] = state
    environment.removeValue(forKey: "MARKETING_VERSION")
    environment.removeValue(forKey: "BUILD_VERSION")
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "\(String(data: data, encoding: .utf8) ?? "Invalid script output")")
    let infoData = try Data(contentsOf: root.appendingPathComponent("build/Procglint.app/Contents/Info.plist"))
    let info = try #require(PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
    #expect(info["CFBundleShortVersionString"] as? String == "1.0.0")
    let expected = state == "missing" ? "unknown" : "abc1234" + (state == "dirty" ? "-dirty" : "")
    #expect(info["ProcglintGitCommit"] as? String == expected)
}
