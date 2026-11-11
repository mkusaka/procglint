import ProcglintCore

enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }

    static func string(_ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "string", "minLength": 1]
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }

    static func strings(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string))]
    }

    static func integer(_ minimum: Int, _ maximum: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "integer", "minimum": .number(.init(minimum))]
        if let maximum {
            fields["maximum"] = .number(.init(maximum))
        }
        return .object(fields)
    }

    static func array(_ items: JSONValue, minimum: Int = 0, maximum: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "array", "items": items, "minItems": .number(.init(minimum))]
        if let maximum {
            fields["maxItems"] = .number(.init(maximum))
        }
        return .object(fields)
    }

    static func nullable(_ schema: JSONValue) -> JSONValue {
        ["anyOf": [schema, ["type": "null"]]]
    }

    static let number: JSONValue = ["type": "number"]
    static let boolean: JSONValue = ["type": "boolean"]
    static let text: JSONValue = ["type": "string"]
    static let date: JSONValue = ["type": "string", "format": "date-time"]
    static let interval: JSONValue = ["type": "integer", "enum": [1000, 2000, 5000, 10000]]
    static let metric = object(["value": nullable(number), "status": strings(MetricStatus.allCases.map(\.rawValue))], required: ["value", "status"])
    static let coverage = object(["enumerated": integer(0), "sampled": integer(0), "permission_denied": integer(0),
                                  "exited_during_sample": integer(0)], required: ["enumerated", "sampled", "permission_denied", "exited_during_sample"])
    static let battery: JSONValue = {
        var fields = Dictionary(uniqueKeysWithValues: ["percent", "time_remaining_minutes", "cycle_count", "health_percent",
                                                       "design_capacity_mah", "full_charge_capacity_mah", "system_power_mw",
                                                       "adapter_power_mw", "battery_power_mw"].map { ($0, metric) })
        let required = fields.keys.sorted()
        fields["is_charging"] = boolean
        fields["external_power"] = boolean
        return object(fields, required: required)
    }()

    static let system: JSONValue = {
        var fields = Dictionary(uniqueKeysWithValues: ["physical_memory_bytes", "page_size", "memory_used_bytes", "wired_bytes",
                                                       "compressed_bytes", "active_bytes", "inactive_bytes", "free_bytes"].map { ($0, integer(0)) })
        fields["cpu_percent"] = metric
        fields["memory_pressure"] = object(["value": nullable(strings(MemoryPressure.allCases.map(\.rawValue))),
                                            "status": strings(MetricStatus.allCases.map(\.rawValue))], required: ["value", "status"])
        fields["memory_pressure_percent"] = metric
        fields["swap_used_bytes"] = metric
        fields["swap_total_bytes"] = metric
        fields["network_receive_bps"] = metric
        fields["network_send_bps"] = metric
        fields["battery"] = nullable(battery)
        return object(fields, required: fields.keys.filter { $0 != "battery" }.sorted())
    }()

    private static let processFields: [String: JSONValue] = {
        var fields = Dictionary(uniqueKeysWithValues: ["cpu_percent", "footprint_bytes", "rss_bytes", "disk_read_bytes",
                                                       "disk_written_bytes", "disk_read_bps", "disk_write_bps", "power_mw",
                                                       "network_receive_bps", "network_send_bps", "network_received_bytes", "network_sent_bytes"].map { ($0, metric) })
        fields.merge(["process_key": string(), "pid": integer(0), "ppid": nullable(integer(0)), "name": text,
                      "uid": integer(0), "user": text, "is_own": boolean, "status": strings(ProcessStatus.allCases.map(\.rawValue)),
                      "cpu_time_ns": nullable(string()), "start_time": date, "path": nullable(text)]) { _, value in value }
        return fields
    }()

    static let commandLine = object(["value": nullable(array(text, maximum: 64)),
                                     "status": strings(MetricStatus.allCases.map(\.rawValue)), "truncated": boolean],
                                    required: ["value", "status", "truncated"])
    static let cwd = object(["value": nullable(text), "status": strings(MetricStatus.allCases.map(\.rawValue))], required: ["value", "status"])
    static let ancestor = object(["pid": integer(0), "name": text, "process_key": string(), "command_line": commandLine], required: ["pid", "name"])
    static let process: JSONValue = {
        var fields = processFields
        fields["command_line"] = commandLine
        fields["cwd"] = cwd
        fields["ancestors"] = array(ancestor, maximum: 64)
        fields["ancestors_incomplete"] = boolean
        fields["children_count"] = integer(0)
        return object(fields, required: processFields.keys.filter { $0 != "ppid" && $0 != "path" }.sorted())
    }()

    static let bulkProcess = object(processFields, required: processFields.keys.filter { $0 != "ppid" && $0 != "path" }.sorted())
    /// Field projection can omit any process property except its opaque key.
    static let pageItem = object(processFields, required: ["process_key"])

    static let headerFields: [String: JSONValue] = [
        "agent_instance_id": string(), "snapshot_id": string(), "sampled_at": date, "interval_ms": nullable(integer(0)),
        "age_ms": integer(0), "status": strings(SnapshotStatus.allCases.map(\.rawValue)), "coverage": coverage, "system": system,
    ]
    static let header = object(headerFields, required: headerFields.keys.sorted())
    static let snapshot: JSONValue = {
        var fields = headerFields
        fields["processes"] = array(bulkProcess)
        return object(fields, required: fields.keys.sorted())
    }()

    static let page = object(["snapshot": header, "items": array(pageItem), "next_cursor": nullable(string()), "total_matched": integer(0)],
                             required: ["snapshot", "items", "total_matched"])
    static let history = object([
        "series": string(),
        "points": array(object(["t": date, "cpu_percent": metric, "footprint_bytes": metric, "disk_read_bps": metric,
                                "disk_write_bps": metric, "memory_used_bytes": metric, "memory_pressure_percent": metric,
                                "memory_pressure": strings(MemoryPressure.allCases.map(\.rawValue)),
                                "system_power_mw": metric, "battery_percent": metric, "power_mw": metric,
                                "network_receive_bps": metric, "network_send_bps": metric], required: ["t", "cpu_percent"])),
        "gaps": array(object(["from": date, "to": date], required: ["from", "to"])),
    ], required: ["series", "points", "gaps"])
    static let policy = object(["revision": integer(0), "gui_interval_ms": interval, "menu_bar_interval_ms": interval,
                                "history_minutes": integer(1, 10), "max_process_series": integer(1, 16)],
                               required: ["revision", "gui_interval_ms", "menu_bar_interval_ms", "history_minutes", "max_process_series"])
    static let observation = object(["observation_id": string(), "interval_ms": interval, "started_at": date, "expires_at": date,
                                     "process_keys": array(string(), maximum: 16), "state": strings(ObservationState.allCases.map(\.rawValue))],
                                    required: ["observation_id", "interval_ms", "started_at", "expires_at", "process_keys", "state"])
    static let ticket = object(["token": string(), "process_key": string(), "pid": integer(0), "name": text,
                                "signal": strings(TerminationSignal.allCases.map(\.rawValue)), "expires_at": date],
                               required: ["token", "process_key", "pid", "name", "signal", "expires_at"])
    static let termination = object(["outcome": strings(TerminationOutcome.allCases.map(\.rawValue)),
                                     "rejection": nullable(strings(TerminationRejection.allCases.map(\.rawValue))), "exited_confirmed": boolean],
                                    required: ["outcome", "exited_confirmed"])
    static let error = object(["error": object(["code": strings(AgentError.Code.allCases.map(\.rawValue)), "message": text,
                                                "rejection": strings(TerminationRejection.allCases.map(\.rawValue))], required: ["code", "message"])], required: ["error"])
    static let monitorStatus: JSONValue = {
        let fields: [String: JSONValue] = [
            "agent_instance_id": string(), "agent_pid": integer(0), "agent_cpu_percent": metric, "agent_footprint_bytes": integer(0),
            "sampling_active": boolean, "effective_interval_ms": nullable(interval), "collections_total": string(),
            "last_collection_ms": number, "collection_p95_ms": number, "last_coverage": coverage,
            "failures": ["type": "object", "additionalProperties": string()],
            "leases": array(object(["kind": strings(LeaseKind.allCases.map(\.rawValue)), "interval_ms": interval,
                                    "remaining_ms": integer(0)], required: ["kind", "interval_ms", "remaining_ms"])),
            "clients": array(object(["client_id": string(), "kind": strings(ClientKind.allCases.map(\.rawValue)), "pid": integer(0),
                                     "footprint_bytes": integer(0), "cpu_percent": metric], required: ["client_id", "kind", "pid", "footprint_bytes", "cpu_percent"])),
            "history_bytes": integer(0), "policy": policy, "system": nullable(system),
        ]
        return object(fields, required: fields.keys.filter { $0 != "effective_interval_ms" }.sorted())
    }()
}
