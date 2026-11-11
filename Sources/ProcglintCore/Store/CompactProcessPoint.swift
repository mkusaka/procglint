import Foundation

/// Float32 is sufficient for chart history; current snapshot counters remain full precision.
struct CompactProcessPoint: Sendable {
    var tick: UInt64
    var t: Date
    private var cpu: Float
    private var footprint: Float
    private var read: Float
    private var write: Float
    private var power: Float
    private var receive: Float
    private var send: Float
    private var statuses: UInt32 = 0

    init(_ process: ProcessSample, at date: Date, tick: UInt64) {
        self.tick = tick
        t = date
        cpu = Float(process.cpuPercent.value ?? 0)
        footprint = Float(process.footprintBytes.value ?? 0)
        read = Float(process.diskReadBps.value ?? 0)
        write = Float(process.diskWriteBps.value ?? 0)
        power = Float(process.powerMW.value ?? 0)
        receive = Float(process.networkReceiveBps.value ?? 0)
        send = Float(process.networkSendBps.value ?? 0)
        let metrics = [process.cpuPercent, process.footprintBytes, process.diskReadBps, process.diskWriteBps,
                       process.powerMW, process.networkReceiveBps, process.networkSendBps]
        for (index, metric) in metrics.enumerated() {
            let code: UInt32 = switch metric.status {
            case .ok: 0
            case .warmingUp: 1
            case .permissionDenied: 2
            case .exited: 3
            case .stale: 4
            case .unsupported: 5
            }
            statuses |= code << (index * 3)
        }
    }

    var point: HistoryPoint {
        HistoryPoint(t: t, cpuPercent: metric(cpu, at: 0), footprintBytes: metric(footprint, at: 1),
                     diskReadBps: metric(read, at: 2), diskWriteBps: metric(write, at: 3),
                     powerMW: metric(power, at: 4), networkReceiveBps: metric(receive, at: 5),
                     networkSendBps: metric(send, at: 6))
    }

    private func metric(_ value: Float, at index: Int) -> Metric {
        switch (statuses >> (index * 3)) & 7 {
        case 0: .ok(Double(value))
        case 1: .warmingUp
        case 2: .permissionDenied
        case 3: .exited
        case 4: .stale
        default: .unsupported
        }
    }
}
