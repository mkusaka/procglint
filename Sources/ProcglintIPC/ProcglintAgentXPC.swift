import Foundation

public let procglintAgentMachServiceName = "io.github.mkusaka.procglint.agent"

@objc public protocol ProcglintAgentXPC {
    func send(_ request: Data, reply: @escaping (Data) -> Void)
}
