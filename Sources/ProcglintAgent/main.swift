import Darwin
import Dispatch
import Foundation
import ProcglintAgentKit
import ProcglintCore

let listener: AgentListener

do {
    let clock = SystemMonotonicClock()
    let source = try DarwinProcessSource()
    let settings = UserDefaultsSettingsStore()
    let policy = try settings.samplingPolicy()
    let sampler = try Sampler(source: source, clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: policy, collect: { try await sampler.sample() })
    let observations = ObservationManager(scheduler: scheduler, clock: clock)
    let auditURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Procglint/audit.jsonl")
    let termination = TerminationController(source: source, clock: clock, auditLog: AuditLog(url: auditURL), ownUID: geteuid())
    let service = try AgentService(sampler: sampler, scheduler: scheduler, observations: observations,
                                   termination: termination, source: source, clock: clock, settings: settings)
    listener = AgentListener(handler: service)
    listener.activate()
    Task { await service.start() }
} catch {
    FileHandle.standardError.write(Data("procglint-agent: startup failed: \(error)\n".utf8))
    exit(1)
}

dispatchMain()
