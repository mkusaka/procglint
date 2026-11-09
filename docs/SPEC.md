# procglint 1.0 contract

This file is the source of truth for data types, units, and component boundaries.
Code must match it; change this file first when a contract changes.

## Components

| Executable | Target | Role |
|---|---|---|
| `procglint-agent` | `ProcglintAgent` (+ `ProcglintAgentKit`) | Per-user LaunchAgent. Only process that samples the OS. Owns history, leases, permission checks, termination. |
| `Procglint.app` (binary `procglint-gui`) | `ProcglintAppMain` (+ `ProcglintApp` in `App/`) | AppKit GUI and menu bar. Talks to the agent over XPC. |
| `procglint-mcp` | `ProcglintMCP` (+ `ProcglintMCPKit`) | stdio MCP server. Relays to the agent over XPC. |
| `procglint` | `ProcglintCLI` | `status`, `doctor`, `export`. |
| `procglint-workload` | `WorkloadGenerator` | Test fixture: CPU/memory/disk load, spawn/exit churn. |

GUI, CLI and MCP never sample the OS on a timer. They hold leases on the agent.

Library layering (no upward imports):

```
CProcglintDarwin  <-  ProcglintCore  <-  ProcglintIPC  <-  ProcglintAgentKit
                                     <-  ProcglintMCPKit (Core only; talks to MonitorService)
                                     <-  ProcglintApp    (Core + IPC; UI talks to MonitorService)
```

`ProcglintCore` must not import AppKit, XPC, or MCP code. OS calls, clock, and settings storage are injected (`ProcessSource`, `MonotonicClock`, `SettingsStore`).

## Identifiers and JSON rules

- JSON keys are `snake_case`. Use `ProcglintJSON.encoder()` / `ProcglintJSON.decoder()` (Core) everywhere; dates are ISO 8601 with fractional seconds, UTC.
- 64-bit times, identifiers and counters that can exceed 2^53 are JSON **strings** (`cpu_time_ns`, `start_time_us`, ids). Byte counts are JSON numbers.
- Unknown enum values from the wire decode to an error, never to a default.

### ProcessIdentity / process_key

```
ProcessIdentity = boot_session_id + pid + start_time_us
process_key     = "p1." + boot_session_id + "." + pid + "." + start_time_us   (opaque to clients)
```

- `boot_session_id`: `kern.bootsessionuuid` sysctl (string). Changes on reboot.
- `start_time_us`: process start (`ri_proc_start_abstime` converted, or `pbi_start_tvsec/usec`) in microseconds.
- Clients treat `process_key` as opaque. The agent parses it and rejects malformed keys with `invalid_process_key`.
- A cached name/path is invalidated when the identity changes or the executable (`p_comm` / uuid) changes.

## Metric value

Every measured value that can be missing is a `Metric`:

```json
{ "value": 12.5, "status": "ok" }
{ "value": null, "status": "warming_up" }
```

`MetricStatus`: `ok | warming_up | permission_denied | exited | stale | unsupported`.
`value` is non-null iff `status == ok`. A missing value is never substituted with 0 or with another metric.

## Units

| Field | Unit / meaning |
|---|---|
| `cpu_percent` (process) | `100 × Δcpu_time / Δwall` over the actual interval. 1 core = 100, may exceed 100. |
| `cpu_percent` (system) | 0–100 across all cores (host CPU ticks). Different scale from process CPU. |
| `cpu_time_ns` | Cumulative user+system CPU time, nanoseconds (string). Mach time is converted inside the OS adapter. |
| `footprint_bytes` | `ri_phys_footprint`. Primary memory column. |
| `rss_bytes` | `ri_resident_size`. Separate column. |
| `disk_read_bytes` / `disk_written_bytes` | Cumulative disk I/O *attributed to the process* (`ri_diskio_bytesread/written`). Not device transfer. |
| `disk_read_bps` / `disk_write_bps` | Δbytes / Δwall seconds. `warming_up` on the first sample of a process. |
| `interval_ms` | Actual elapsed monotonic time since the previous sample (null on the first). |

## Snapshot

| Field | Type | Meaning |
|---|---|---|
| `agent_instance_id` | string (UUID) | Changes on every agent start. |
| `snapshot_id` | string | `"<agent_instance_id prefix 8>-<sequence>"`, unique per agent instance. |
| `sampled_at` | date | Wall time of the sample (display only). |
| `interval_ms` | int? | Actual interval. |
| `age_ms` | int | Filled at response time: now − sample (monotonic). |
| `status` | `SnapshotStatus` | `ok | warming_up | stale | unavailable` |
| `coverage` | `Coverage` | `enumerated`, `sampled`, `permission_denied`, `exited_during_sample` (ints) |
| `system` | `SystemMetrics` | see below |
| `processes` | `[ProcessSample]` | Filtered to the caller's scope. |

`SnapshotStatus`: `warming_up` until the second sample exists (CPU needs two points); `stale` when `age_ms > 3 × effective interval`; `unavailable` when PID enumeration failed (never interpreted as "all processes exited").

`SystemMetrics`: `cpu_percent: Metric`, `physical_memory_bytes`, `page_size`, `memory_used_bytes`, `wired_bytes`, `compressed_bytes`, `active_bytes`, `inactive_bytes`, `free_bytes` (all from `host_statistics64(HOST_VM_INFO64)`; `memory_used_bytes = (active + wired + compressor pages) × page_size`, documented in `docs/PERFORMANCE.md`).
- `memory_pressure`: `{value: "normal" | "warning" | "critical" | null, status}` from `kern.memorystatus_vm_pressure_level` (1/2/4); other values or read failure → `unsupported`.
- `swap_used_bytes`, `swap_total_bytes`: `Metric` from one `vm.swapusage` read (`xsw_usage`; total is currently allocated swap). Access failure → `permission_denied`; other failures, malformed size or used > total → `unsupported`.
- `memory_pressure_percent`: `Metric`, 0–100, `100 − kern.memorystatus_level` (available-memory percent), one read per collection. `EACCES`/`EPERM` → `permission_denied`; out-of-range level, malformed size or other failure → `unsupported`. Decoders treat absent `memory_pressure`, `memory_pressure_percent`, `swap_used_bytes`, `swap_total_bytes` as `unsupported`.
- `battery: BatteryMetrics?` (nil when no battery is reported): Metrics `percent` (0–100), `time_remaining_minutes` (65535/unknown → `unsupported`), `cycle_count`, `health_percent` (= full-charge ÷ design capacity × 100, unclamped; full-charge falls back to `AppleRawMaxCapacity`), `design_capacity_mah`, `full_charge_capacity_mah`, `system_power_mw` (`SystemLoad`), `adapter_power_mw` (`SystemPowerIn`), signed `battery_power_mw` (negative while discharging; unsigned/missing telemetry uses signed `InstantAmperage × Voltage / 1000`); optional booleans `is_charging`, `external_power` (omitted when unknown). Read from IORegistry `AppleSmartBattery` at most once per 10 s (absence cached too); capacity/health/cycle fields cached for the source lifetime.
- Decoders treat the three fields as `unsupported` when absent (snapshots from a 1.0.0 agent still running across an upgrade).
- MCP `get_monitor_status` and `procglint status --json` add `system: SystemMetrics | null` from a shared snapshot read (`null` if that read fails). IPC `MonitorStatus` is unchanged.
- The GUI labels `footprint_bytes` as **Memory** (same value as Activity Monitor's Memory column); field names, sort names and defaults are unchanged.

`ProcessSample`:

| Field | Type |
|---|---|
| `process_key` | string |
| `pid` | int |
| `ppid` | int? |
| `name` | string |
| `uid` | int |
| `user` | string |
| `is_own` | bool (uid == agent uid) |
| `status` | `ProcessStatus`: `ok | permission_denied | exited` |
| `cpu_percent` | Metric |
| `cpu_time_ns` | string? (null when not readable) |
| `footprint_bytes`, `rss_bytes` | Metric |
| `disk_read_bytes`, `disk_written_bytes` | Metric |
| `disk_read_bps`, `disk_write_bps` | Metric |
| `power_mw` | Metric: OS-attributed average power, `1000 × Δri_energy_nj / Δmonotonic_ns`, same identity/interval baselines as CPU; first reading/reset → `warming_up`; missing or zero counters → `unsupported`; access denial → `permission_denied`. From `RUSAGE_INFO_V6` in the existing rusage call (V2 retry on `EINVAL`/`ENOTSUP` leaves it unsupported). Not battery-drain attribution or Energy Impact. Sort key `power`. Absent decodes as `unsupported`. |
| `start_time` | date |
| `path` | string? Only when the caller's scope includes paths. Loaded lazily. |

Never exposed: environment variables or process memory.

Command-line arguments and working directories are exposed only in lazy per-process detail responses when the caller's effective scope includes `include_command_lines` (default off). Bulk snapshot and process-list rows never include command lines, working directories or lineage. Lazy process detail adds:
- `ancestors`: immediate parent → … → launchd (pid 1), each `pid`, `name`, optional `process_key`, optional `command_line`; `ancestors_incomplete: true` when the census walk stops early (cycle, missing parent, 64 hops).
- `children_count`: direct children in the latest census.
- `command_line`: `{value: [string]?, status, truncated}` and `cwd`: `{value: string?, status}`, only with `include_command_lines`.

Ancestors and child counts are not permission-gated and are computed only on detail requests from the current census. Command lines come from `KERN_PROCARGS2` argc/argv only (the environment block is never returned); cwd from `PROC_PIDVNODEPATHINFO`. Other users' processes / access denial → `permission_denied`; vanished or reused identity → `exited`; malformed → `unsupported`; values are non-null iff status is ok. Caps: 64 arguments, 4 KiB UTF-8 per argument, 16 KiB total, on character boundaries (`truncated: true`). Agent-side redaction (before truncation and transmission) replaces secret-like values with `<redacted>`: flag/`KEY=value` values whose name matches (case-insensitive) token|secret|password|passwd|pwd|apikey|api-key|api_key|auth|credential|key (ignoring keyboard, keymap, monkey), separate-value flags, URL userinfo/passwords and Bearer credentials. Redaction is best-effort. Decoders treat absent detail fields as nil.

## Queries

`ProcessQuery`:

| Field | Default | Rule |
|---|---|---|
| `search` | null | Case-insensitive name substring, or exact PID if numeric. |
| `filter` | `mine` for MCP, `all` for GUI | `all | mine | pinned` (`all` limited by scope) |
| `sort` | `cpu` | `cpu | footprint | rss | disk_read_bps | disk_write_bps | cpu_time | pid | name` |
| `order` | `desc` | `asc | desc` |
| `limit` | 50 | 1…200 |
| `cursor` | null | Opaque, bound to one `snapshot_id`. Paging never mixes snapshots. Expired/foreign cursor → `invalid_cursor`. |
| `fields` | all | Optional subset of `ProcessSample` field names (`process_key` always included). |

`ProcessPage`: `snapshot` header fields (all snapshot fields except `processes`), `items`, `next_cursor?`, `total_matched`.

## History

- Retained: system series always while sampling; process series only for pinned, observed, or GUI-selected processes.
- Limits (defaults): 10 minutes window, 600 points per series, 16 process series per agent. To reserve slots, evict ownerless process series oldest-last-tracked first; active ownership exceeding the limit → `history_limit_reached`.
- `HistoryPoint`: `t` (date), `cpu_percent`, `footprint_bytes`, `disk_read_bps`, `disk_write_bps` (Metric each; system uses `cpu_percent`, `memory_used_bytes`, and optional `memory_pressure_percent: Metric` and `memory_pressure: "normal" | "warning" | "critical"`; absent decodes as nil, process points omit them). System points also optionally carry `system_power_mw` and `battery_percent`; process points optionally `power_mw` (all Metrics; absent → nil).
- `HistorySeries`: `series` (`"system"` or a process_key), `points`, `gaps: [{from, to}]` — intervals where sampling was stopped or the process was not tracked. Charts draw no line across a gap. History never backfills unobserved time.
- Cursor responses add `next_cursor?`, `is_delta` (default false) and `retained_point_count?` (0…600). A delta carries only new points and replaces the cached gap list; the client appends and keeps the last `retained_point_count` points. A full response replaces the cached series. Cursors bind to the store/buffer generation, series, query bounds and gap revision; agent restart, eviction of unseen points, buffer recreation, gap changes, overlapping or noncontiguous selections fall back to full data. Cursors are not authorization. MCP `get_history` is unchanged.

## Leases and the scheduler

`SamplingLease` (agent-internal, one per client purpose):

| Field | Type |
|---|---|
| `lease_id` | string |
| `client_id` | string (agent-assigned per XPC connection) |
| `kind` | `gui_window | menu_bar | observation` |
| `interval_ms` | 1000 / 2000 / 5000 / 10000 |
| `expires_at` | monotonic deadline, required for `observation`; GUI leases are renewed by the GUI while visible (TTL 30 s). |

`LeaseRequest` accepts optional `process_keys` (0…16, missing defaults to empty), only for `gui_window`: the lease owns tracking of those keys, within `max_process_series` (`history_limit_reached` on overflow), without backfill.
Renewal replaces the tracked key set; release, expiry, or disconnect removes that ownership.

Rules:

1. Effective interval = min over active leases. No active lease → no periodic sampling.
2. At most one collection runs at a time. Concurrent "need fresh data" requests join the in-flight collection.
3. Read requests return the cached snapshot if `age_ms ≤ effective interval` (or ≤ 5000 ms when idle). Otherwise they trigger one shared collection, never more often than once per 1000 ms.
4. Cold start: collect now and again after ~1 s, both shared; CPU is `warming_up` until then.
5. Timer leeway = 10 % of the interval. Missed ticks are not replayed; only the latest pending result is delivered to UI.
6. Lease expiry uses a monotonic clock; on wake from sleep expired leases are dropped and a gap is recorded in history.
7. A disconnected client's leases and observations are removed immediately.
8. With no clients, the agent exits after a 60 s grace period (launchd restarts it on demand).

Policy defaults: GUI window 5000 ms (choices 1/2/5/10 s), menu bar 10000 ms.

`SamplingPolicy`: `revision` (int), `gui_interval_ms`, `menu_bar_interval_ms`, `history_minutes` (1…10), `max_process_series` (1…16). `set_sampling_policy` requires `expected_revision`; mismatch → `revision_conflict`. `gui_interval_ms` is the foreground interval; the GUI's local adaptive-refresh preference (default on) requests the next slower allowed interval (cap 10 s) while the main window is visible but unfocused, after a 1 s debounce. Hidden, occluded or minimised windows hold no window lease.

## Observations (MCP)

`start_observation` input: `interval_ms` (1000/2000/5000/10000), `duration_ms` (1000…60000, required), `process_keys` (0…16). Returns `Observation` immediately: `observation_id`, `interval_ms`, `started_at`, `expires_at`, `process_keys`, `state` (`active | expired | stopped`). Results are read with `get_history`. No auto-renewal.

## Permissions

`Permission`: `observe`, `configure`, `terminate`, `force_kill`, `include_system`, `include_paths`, `include_command_lines`. MCP command-line access requires both the app setting and `--include-command-lines`; CLI requires the app setting and `procglint show --include-command-lines`; the GUI follows app settings. Nothing overrides OS restrictions.

Effective permissions = OS-allowed ∩ app settings (`SettingsStore`, written by the GUI) ∩ MCP launch flags (`--allow-observe`, `--allow-configure`, `--allow-terminate`, `--allow-force-kill`, `--include-system`, `--include-paths`). The agent computes and enforces the final set; MCP-side filtering is only for tool listing. Default (no flags): read-only, own processes, no paths.

GUI clients get all permissions the app settings allow (terminate still requires a confirmation dialog in the UI).

XPC peers are accepted only if same UID and: when the agent is Team-signed, the peer has the same Team ID; when the agent is ad-hoc/unsigned (dev or ad-hoc release builds), the peer executable is in the agent's directory or the same `.app/Contents`, and the connection is pinned to the peer's cdhash. Documented in `docs/SECURITY.md`. Client-supplied names are never used for auth.

Response caches are keyed by `(snapshot_id, scope)`, so clients with different scopes never share filtered results.

## Termination

`prepare_termination(process_key, signal)` → `TerminationTicket`: `token` (128-bit random, hex), `process_key`, `pid`, `name`, `signal` (`term | kill`), `expires_at` (30 s), bound to the issuing `client_id`, single-use.

Rejected targets (`TerminationRejection`): `not_own_process`, `protected_pid` (0, 1), `self` (agent, the app, the MCP bridge, the requesting client's own pid and its parent chain up to launchd), `process_changed` (start time / uid / executable changed), `exited`, `token_expired`, `token_used`, `token_foreign`, `permission_denied` (`kill` without `force_kill`).

`terminate_process(token)` re-validates identity immediately before `kill(2)` and returns `TerminationResult`: `outcome` (`signal_sent | rejected`), `rejection?`, `exited_confirmed` (bool, checked once ~500 ms later). Never escalates TERM → KILL. No process groups, negative pids, name matching, arbitrary signals, or shell execution.

Audit log: JSON Lines at `~/Library/Application Support/Procglint/audit.jsonl`, one entry per prepare/terminate (`timestamp`, `client_kind`, `client_pid`, `process_key`, `pid`, `name`, `signal`, `outcome`: `issued | signal_sent | rejected`, `rejection`). Capped at 1 MiB; rotates to `audit.1.jsonl` (one generation).

## Monitor status (self-diagnostics)

`MonitorStatus`: `agent_instance_id`, `agent_pid`, `agent_cpu_percent` (Metric), `agent_footprint_bytes`, `sampling_active` (bool), `effective_interval_ms?`, `collections_total`, `last_collection_ms`, `collection_p95_ms`, `last_coverage`, `failures` (`{reason: count}`), `leases` (kind, interval, remaining_ms), `clients` (`client_id`, `kind`: `gui | mcp | cli`, `pid`, `footprint_bytes`, `cpu_percent` Metric), `history_bytes` (estimate), `policy`.

## Errors

`AgentError`: `code` + `message`. Codes: `invalid_argument`, `invalid_process_key`, `invalid_cursor`, `not_found`, `permission_denied`, `rate_limited`, `revision_conflict`, `history_limit_reached`, `termination_rejected` (with `rejection`), `agent_unavailable`, `internal`.

## MonitorService (Core protocol)

The single API used by MCPKit and the GUI; implemented by the IPC client (and by in-memory fakes in tests).

```swift
public protocol MonitorService: Sendable {
    func snapshot(top: Int, sort: ProcessSort) async throws -> Snapshot
    func listProcesses(_ query: ProcessQuery) async throws -> ProcessPage
    func process(key: ProcessKey) async throws -> ProcessSample
    func history(_ request: HistoryRequest) async throws -> [HistorySeries]
    func status() async throws -> MonitorStatus
    func setLease(_ request: LeaseRequest) async throws -> SamplingLease   // GUI / menu bar
    func releaseLease(id: String) async throws
    func startObservation(_ request: ObservationRequest) async throws -> Observation
    func stopObservation(id: String) async throws
    func pin(key: ProcessKey, pinned: Bool) async throws
    func policy() async throws -> SamplingPolicy
    func setPolicy(_ policy: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy
    func prepareTermination(key: ProcessKey, signal: TerminationSignal) async throws -> TerminationTicket
    func terminate(token: String) async throws -> TerminationResult
}
```

`HistoryRequest`: `series` (`system`, process keys, or `observation_id`), `since?` (date), `cursor?` (opaque string, ≤64 KiB, else `invalid_argument`). Omitted cursor → the legacy full response with no cursor fields. Empty or unknown cursor → full response with checkpoints. One cursor covers the whole selector batch.

## XPC

- Mach service: `io.github.mkusaka.procglint.agent`. LaunchAgent plist `io.github.mkusaka.procglint.agent.plist` in `Procglint.app/Contents/Library/LaunchAgents/`, registered with `SMAppService.agent(plistName:)` from the GUI's first-run setup. `procglint doctor` reports registration state and recovery steps.
- `@objc protocol ProcglintAgentXPC { func send(_ request: Data, reply: @escaping (Data) -> Void) }`. Payloads are JSON-encoded `AgentRequest` / `AgentResponse` envelopes (Codable, `ProcglintJSON`). The first request on a connection is `hello(client_kind, version, mcp_flags?)`.
- Dev mode: `scripts/dev-agent.sh` bootstraps a LaunchAgent plist pointing at the `.build` binary so integration tests can run without the app bundle.
- If the agent is unreachable, clients report `agent_unavailable` with recovery steps. They never start their own sampler.
