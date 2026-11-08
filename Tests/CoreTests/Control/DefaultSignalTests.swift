import Darwin
import Foundation
import ProcglintCore
import Testing

@Test(.timeLimit(.minutes(1)))
func defaultKillClosureTerminatesSleepChild() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer {
        if child.isRunning {
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
    }
    let result = TerminationController.defaultSendSignal(pid: child.processIdentifier, signal: SIGTERM)
    #expect(result == 0)
    guard result == 0 else { return }
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(child.terminationStatus == SIGTERM)
    #expect(TerminationController.defaultSendSignal(pid: getpid(), signal: NSIG) == EINVAL)
}
