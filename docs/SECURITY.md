# Security and privacy

procglint runs as the logged-in user. It has **no root helper and no network listener**: GUI, CLI and MCP use local XPC; MCP hosts use stdio. The agent alone samples the OS and enforces access to its data and operations. No client falls back to an independent sampler when the agent is unavailable.

Default MCP access is read-only, own processes, without executable paths. Enable additional access only for a trusted host, and require human approval for termination. The MCP host may send results to an external model even though procglint itself provides no network service.

## Threat model

| Threat | Boundary / mitigation |
| --- | --- |
| Unauthorized local XPC client | Same effective UID plus signing/path checks and a connection signing requirement, described below |
| MCP host requesting more access than intended | Agent-enforced permission intersection; scopes on reads; explicit opt-in mutation flags |
| Prompt injection in process metadata | Names, user strings and paths are data, never instructions. Tool descriptions and the bundled skill say not to follow them. |
| PID reuse, process exit or executable replacement | Opaque identity includes boot session, PID and start time; termination additionally revalidates owner and executable metadata |
| Accidental/destructive termination | Own-process restriction, protected PIDs, two-step short-lived ticket, confirmation, audit log, no automatic escalation |
| Excessive monitoring or output | Shared single-flight sampler, bounded observations/history, request/response/concurrency limits, per-bridge and aggregate agent rate limits ([constants](MCP.md#protocol-and-limits)) |

This is not a sandbox against malware already running as you, a compromised MCP host, or a compromised signing identity. A same-user attacker may modify user-writable settings or replace binaries in a development installation. Teamless path checks are a development/ad-hoc trust boundary, not equivalent to Developer ID distribution. Read access can reveal sensitive application names; executable paths may include account or project names.

## XPC peer authorization

The Mach service is `io.github.mkusaka.procglint.agent`, registered as a per-user LaunchAgent through `SMAppService`. The bundled plist is in `Procglint.app/Contents/Library/LaunchAgents/io.github.mkusaka.procglint.agent.plist`; it is limited to an Aqua login session. Registration and macOS Login Items approval are distinct from peer authorization.

The production listener uses `PeerAuthorization` in [`Sources/ProcglintAgentKit/Transport/PeerAuthorization.swift`](../Sources/ProcglintAgentKit/Transport/PeerAuthorization.swift) and installs its requirement with `NSXPCConnection.setCodeSigningRequirement`:

1. Require the peer's **effective UID** to equal the agent's effective UID. Read the agent's and peer's executable/signing metadata using Security.framework; missing identities fail closed. Peers with signing identifiers must pass `SecCodeCheckValidity`.
2. Apply the following branch based on the **agent's** signing identity:

   | Agent signing | Accepted peer location/identity | Connection requirement |
   | --- | --- | --- |
   | Has a Team ID | Peer has the same Team ID; no same-directory restriction | Apple-generic signing anchor and certificate leaf `subject.OU` equal to that Team ID |
   | No Team ID (ad-hoc/teamless) | Peer executable is in the agent executable's directory, **or** under the same enclosing `.app/Contents` | The peer's exact cdhash |

3. For the teamless location check, resolve symlinks and standardize both executable URLs. Merely using a procglint-like name or claiming a client kind is insufficient.
4. Require a usable signing requirement. A truly unsigned **peer** without a cdhash is rejected even if its path passes the location check; ad-hoc clients must supply a cdhash. A teamless agent need not have its own cdhash if its executable identity can be read. Team IDs used in a requirement must be nonempty uppercase ASCII letters/digits.

NSXPC checks the actual message sender against the requirement, rather than trusting only the PID used for the initial metadata lookup. Anonymous same-process transport tests have a narrow exception that pins the hosting executable's cdhash; it is not a production Mach-service bypass. Client-supplied names are never authentication evidence. After acceptance, `hello` must be the first request, and the listener assigns the connection's `client_id` from authenticated transport context.

Keep all ad-hoc helpers inside the same complete app bundle (or the same build output directory). Copying only `procglint-mcp` elsewhere can make authorization fail. Diagnose with `procglint doctor`; do not relax directory/signing checks or run the agent as root.

## Permissions and data exposure

**Effective MCP permissions = OS-allowed ∩ app settings ∩ launch flags.** App settings use the defaults suite `io.github.mkusaka.procglint`. Flags request `observe`, `configure`, `terminate`, `force_kill`, `include_system`, `include_paths`; none overrides the other layers. Stored permissions default to empty (read-only, own processes, no paths). GUI access is capped by app settings too, with its own termination confirmation dialog; CLI process/path scope also follows those settings.

The shared defaults keys are:

| Key | Stored value |
| --- | --- |
| `procglint.sampling_policy` | JSON Data: policy revision, intervals and history limits |
| `procglint.allowed_permissions` | JSON Data: allowed permission set |
| `procglint.menu_bar` | Boolean; absent means disabled |
| `procglint.optional_columns` | Array of enabled optional GUI column names; absent means none |

Use Settings to change permissions and policy rather than writing malformed serialized values. Removing this defaults suite deletes all four settings.

The bridge's tool list reflects launch flags only; the agent is the final authority on reads and mutations. `--include-system` allows reading other users' processes only where the OS permits it, never terminating them. `--include-paths` allows lazy executable-path retrieval, not arbitrary file reads. Filtered response caches are keyed by `(snapshot_id, scope)` so different process/path scopes do not share filtered results.

Never exposed through procglint: **environment variables or process memory contents**. Command-line arguments and working directories are opt-in (`include_command_lines`, default off), limited to the user's own processes by the OS, capped, and redacted best-effort by the agent before leaving it (see `docs/SPEC.md`). There is no shell execution, arbitrary signal API, process-group operation, negative-PID signaling or name-based termination. It does not collect GPU, temperature or a replacement for Apple's Energy Impact.

History is in memory and bounded by the configured window (default 10 minutes) and 600 points per series. Every sampled process gets history, regardless of selection or pinning; memory therefore scales with sampled and recently exited identities. `max_process_series` limits explicit pin/lease/observation ownership, not automatic recording. Unowned series expire when their newest point leaves the window; explicitly owned keys may retain an empty series until released. Existing process scopes apply to live and exited history, including `include_system` for other users’ processes. A disconnected client loses its leases and observations. Settings and the bounded termination audit log are persistent. CLI exports or data copied to an MCP host are outside that in-memory retention policy.

## Network privacy

System network rates use public 64-bit interface counters. Per-process TCP/UDP byte counts use the private NetworkStatistics.framework, loaded only at runtime by the agent. Only PID and receive/send byte counters are extracted from source dictionaries; process start time is read separately to guard against PID reuse.

Addresses, ports, interface names and hostnames from source descriptions are never copied into procglint aggregation state, snapshots, history, logs, IPC responses, CLI exports or MCP output. Closed-source state retains only process identity and cumulative bytes and is dropped when the process identity exits.

Existing process scopes still apply. Unreported other-user processes are `permission_denied`, not zero. Missing private framework symbols disable only per-process network metrics (`unsupported`); query timeouts produce `stale`. Private API behavior can change between macOS releases.

## Termination safeguards

1. **Human confirmation first.** Show the exact target and potential data loss. Prefer `term` (SIGTERM); `kill` (SIGKILL) needs an explicit request plus both `terminate` and `force_kill` permission. A ticket is not evidence of human consent.
2. **Prepare by opaque identity.** `prepare_termination` validates the target and issues a 128-bit random hex token. The ticket carries target key, PID, name, signal and a display expiry. Its actual 30-second deadline uses monotonic time. It is bound to the issuing `client_id`, client kind and client PID, is single-use and is invalid after an agent restart.
3. **Reject unsafe targets.** Only processes owned by the agent's user are eligible. PID 0 and 1 are protected. So are the agent, app, MCP bridge, requesting client's PID and its parent chain up to launchd. The agent supplies protected PIDs from authenticated context, never from caller-supplied names.
4. **Revalidate before signaling.** The controller verifies boot session and start time, reads BSD/resource metadata and path, then verifies stable start time, UID and name. Before `kill(2)`, it compares UID, name, path and executable UUID to the prepared target and checks the deadline again. The agent contract requires final permission enforcement on the operation as well.
5. **Consume before the attempt.** A valid owned ticket is marked used before any suspension or OS signal operation; a failed signal attempt does not make it reusable. Tokens are memory-only and bounded to 64 records; expired/evicted/unknown tokens cannot authorize a signal. Unknown or forgotten tokens report `token_used`.
6. **Report what happened.** `signal_sent` is not proof of exit. The controller checks once about 500 ms later; an unreadable process is not counted as exited. It never escalates TERM to KILL or repeatedly retries. A cancellation after the signal can leave exit unconfirmed.

**Revalidation and `kill(2)` are not atomic.** A process can exit, exec or have its PID reused between the final check and the signal syscall. The checks reduce this race but cannot eliminate it with a PID-based Darwin signal API. Do not present termination as race-free.

Rejections: `not_own_process`, `protected_pid`, `self`, `process_changed`, `exited`, `token_expired`, `token_used`, `token_foreign`, `permission_denied`. Treat a rejection as a reason to inspect again, not to switch targets or escalate. See [MCP](MCP.md) for the two-call interface.

## Audit log

The agent writes its log at:

```text
~/Library/Application Support/Procglint/audit.jsonl
```

One JSON Lines entry is written for each preparation/termination outcome. Keys are `timestamp` (fractional ISO 8601 UTC), `client_kind`, `client_pid`, `process_key`, `pid`, `name`, `signal`, `outcome` (`issued`, `signal_sent`, `rejected`) and optional `rejection`. An unrecognized token has no known target: `process_key`, `pid`, `name` and `signal` are logged as null. Tokens themselves are not logged.

The writer creates/restricts the directory to mode `0700` and the log file to `0600`, refuses a symlink at the log/directory open boundary, and requires a regular log file. Before an append would exceed **1 MiB**, it rotates to `audit.1.jsonl`, replacing the previous generation; there is one backup. An oversized single entry is refused.

A failed prepare audit issues no usable token. If the signal has already been sent and the audit write fails, the controller reports an error explicitly saying the signal was sent; do not retry blindly. The log is local, user-writable and not tamper-evident or a permanent record. Process names remain untrusted data even in the audit log.
