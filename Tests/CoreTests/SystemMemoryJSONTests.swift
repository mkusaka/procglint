import Foundation
import ProcglintCore
import Testing

@Test func pressureMetricEncodingAndValidation() throws {
    for pressure in MemoryPressure.allCases {
        let metric = MemoryPressureMetric.ok(pressure)
        #expect(try json(metric) == "{\"status\":\"ok\",\"value\":\"\(pressure.rawValue)\"}")
        try roundTrip(metric)
    }
    #expect(try json(MemoryPressureMetric.unsupported) == #"{"status":"unsupported","value":null}"#)
    try roundTrip(MemoryPressureMetric.unsupported)
    for status in MetricStatus.allCases {
        if status == .ok {
            #expect(throws: AgentError.self) { try MemoryPressureMetric(value: nil, status: status) }
        } else {
            #expect(throws: AgentError.self) { try MemoryPressureMetric(value: .normal, status: status) }
            try roundTrip(MemoryPressureMetric(value: nil, status: status))
        }
    }
    for invalid in [#"{"value":"unknown","status":"ok"}"#, #"{"value":1,"status":"ok"}"#,
                    #"{"value":null,"status":"ok"}"#, #"{"value":"normal","status":"unsupported"}"#,
                    #"{"value":null,"status":"unavailable"}"#]
    {
        #expect(throws: (any Error).self) { try ProcglintJSON.decoder().decode(MemoryPressureMetric.self, from: Data(invalid.utf8)) }
    }
}

@Test func unavailableMemoryFieldsAreExplicitNulls() throws {
    var system = testSystem()
    system.memoryPressure = .unsupported
    system.memoryPressurePercent = .unsupported
    system.swapUsedBytes = .permissionDenied
    system.swapTotalBytes = .permissionDenied
    let text = try json(system)
    #expect(text.contains(#""memory_pressure":{"status":"unsupported","value":null}"#))
    #expect(text.contains(#""memory_pressure_percent":{"status":"unsupported","value":null}"#))
    #expect(text.contains(#""swap_used_bytes":{"status":"permission_denied","value":null}"#))
    #expect(text.contains(#""swap_total_bytes":{"status":"permission_denied","value":null}"#))
    try roundTrip(system)
}

@Test func legacySystemMetricsWithoutMemoryPressureDecode() throws {
    let legacy = #"{"cpu_percent":{"value":null,"status":"warming_up"},"physical_memory_bytes":1,"page_size":1,"memory_used_bytes":1,"wired_bytes":1,"compressed_bytes":1,"active_bytes":1,"inactive_bytes":1,"free_bytes":1}"#
    let system = try ProcglintJSON.decoder().decode(SystemMetrics.self, from: Data(legacy.utf8))
    #expect(system.memoryPressure == .unsupported)
    #expect(system.memoryPressurePercent == .unsupported)
    #expect(system.swapUsedBytes == .unsupported)
}
