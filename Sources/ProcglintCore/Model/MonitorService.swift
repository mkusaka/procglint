public protocol MonitorService: Sendable {
    func snapshot(top: Int, sort: ProcessSort) async throws -> Snapshot
    func listProcesses(_ query: ProcessQuery) async throws -> ProcessPage
    func process(key: ProcessKey) async throws -> ProcessSample
    func history(_ request: HistoryRequest) async throws -> [HistorySeries]
    func status() async throws -> MonitorStatus
    func setLease(_ request: LeaseRequest) async throws -> SamplingLease
    func releaseLease(id: String) async throws
    func startObservation(_ request: ObservationRequest) async throws -> Observation
    func stopObservation(id: String) async throws
    func pin(key: ProcessKey, pinned: Bool) async throws
    func policy() async throws -> SamplingPolicy
    func setPolicy(_ policy: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy
    func prepareTermination(key: ProcessKey, signal: TerminationSignal) async throws -> TerminationTicket
    func terminate(token: String) async throws -> TerminationResult
}
