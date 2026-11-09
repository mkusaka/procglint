import Foundation
import Testing

@Test func versionFlagParsesWithoutAcceptingExtraArguments() throws {
    #expect(try CLICommand.parse(["--version"]) == .version)
    #expect(throws: CLIUsageError.self) { try CLICommand.parse(["--version", "extra"]) }
    #expect(throws: CLIUsageError.self) { try CLICommand.parse(["status", "--version"]) }
    #expect(versionOutput(executable: URL(fileURLWithPath: "/tmp/procglint")) == "procglint unknown (unknown)\n")
}

@Test func cliVersionReadsEnclosingBundleThroughSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-version-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Procglint.app/Contents")
    let helper = contents.appendingPathComponent("Helpers/procglint")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: helper)
    let info: [String: String] = ["CFBundleIdentifier": "test.procglint.version", "CFBundleName": "Procglint",
                                  "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0.0",
                                  "ProcglintGitCommit": "abc1234-dirty"]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    let link = root.appendingPathComponent("procglint")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
    #expect(versionOutput(executable: helper) == "procglint 1.0.0 (abc1234-dirty)\n")
    #expect(versionOutput(executable: link) == "procglint 1.0.0 (abc1234-dirty)\n")
}
