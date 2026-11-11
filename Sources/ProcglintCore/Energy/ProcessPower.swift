import Foundation

public extension ProcessSample {
    /// Older agents can remain alive across an upgrade; absent power/network metrics are not measured zeros.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            processKey: values.decode(ProcessKey.self, forKey: .processKey),
            pid: values.decode(Int32.self, forKey: .pid),
            ppid: values.decodeIfPresent(Int32.self, forKey: .ppid),
            name: values.decode(String.self, forKey: .name),
            uid: values.decode(UInt32.self, forKey: .uid),
            user: values.decode(String.self, forKey: .user),
            isOwn: values.decode(Bool.self, forKey: .isOwn),
            status: values.decode(ProcessStatus.self, forKey: .status),
            cpuPercent: values.decode(Metric.self, forKey: .cpuPercent),
            cpuTimeNS: values.decode(OptionalJSONString<UInt64>.self, forKey: .cpuTimeNS).wrappedValue,
            footprintBytes: values.decode(Metric.self, forKey: .footprintBytes),
            rssBytes: values.decode(Metric.self, forKey: .rssBytes),
            diskReadBytes: values.decode(Metric.self, forKey: .diskReadBytes),
            diskWrittenBytes: values.decode(Metric.self, forKey: .diskWrittenBytes),
            diskReadBps: values.decode(Metric.self, forKey: .diskReadBps),
            diskWriteBps: values.decode(Metric.self, forKey: .diskWriteBps),
            startTime: values.decode(Date.self, forKey: .startTime),
            path: values.decodeIfPresent(String.self, forKey: .path),
            commandLine: values.decodeIfPresent(ProcessCommandLine.self, forKey: .commandLine),
            cwd: values.decodeIfPresent(WorkingDirectory.self, forKey: .cwd),
            ancestors: values.decodeIfPresent([ProcessAncestor].self, forKey: .ancestors),
            ancestorsIncomplete: values.decodeIfPresent(Bool.self, forKey: .ancestorsIncomplete),
            childrenCount: values.decodeIfPresent(Int.self, forKey: .childrenCount),
            powerMW: values.decodeIfPresent(Metric.self, forKey: .powerMW) ?? .unsupported,
            networkReceiveBps: values.decodeIfPresent(Metric.self, forKey: .networkReceiveBps) ?? .unsupported,
            networkSendBps: values.decodeIfPresent(Metric.self, forKey: .networkSendBps) ?? .unsupported,
            networkReceivedBytes: values.decodeIfPresent(Metric.self, forKey: .networkReceivedBytes) ?? .unsupported,
            networkSentBytes: values.decodeIfPresent(Metric.self, forKey: .networkSentBytes) ?? .unsupported
        )
    }
}

func processPower(_ energy: UInt64?, previous: UInt64?, elapsed: UInt64?) -> Metric {
    guard let energy, energy > 0 else { return .unsupported }
    // nJ / ns = W; unlike disk rates, power needs only a factor of 1000 for mW.
    guard let previous, previous > 0, energy >= previous, let elapsed, elapsed > 0 else { return .warmingUp }
    return .ok(Double(energy - previous) / Double(elapsed) * 1000)
}
