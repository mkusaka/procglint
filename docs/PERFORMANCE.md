# Performance and metric definitions

procglint shares one sampler per user, regardless of how many GUI/MCP/CLI clients connect. Monitoring stops when no sampling lease is active, apart from bounded cold-start/read-triggered collection. The budgets below are **acceptance targets, not measured results**.

## What the metrics mean

| Metric | Definition / interpretation |
| --- | --- |
| Process `cpu_percent` | `100 × Δ(user + system CPU time) / Δwall time`, over the actual monotonic interval. One fully occupied core is 100%; multi-core processes can exceed 100%. |
| System `cpu_percent` | `100 × Δ(user + system + nice ticks) / Δ(all CPU ticks)`, from Mach host statistics; 0–100% across all cores. Do not compare it directly with a single process's per-core percentage. |
| `cpu_time_ns` | Cumulative user + system CPU time, converted from Mach time to nanoseconds in the OS adapter; a JSON string. |
| `footprint_bytes` | `ri_phys_footprint`, the primary process memory column: the OS-accounted physical memory footprint. |
| `rss_bytes` | `ri_resident_size`, resident memory reported separately. RSS and footprint are different measures, not fallbacks for one another, and summing process values is not the system used-memory formula. |
| `disk_read_bytes`, `disk_written_bytes` | Cumulative `ri_diskio_bytesread/written` attributed to a process by the OS. Not a measurement of physical device transfers or device bandwidth. |
| `disk_read_bps`, `disk_write_bps` | `Δattributed bytes / Δwall seconds`. Disk rates and process CPU need two readings of the same process identity. |
| `interval_ms` | Actual monotonic elapsed time since the previous sample, not the requested interval; null on the first sample. |
| `sampled_at`, `age_ms` | Wall timestamp for display, and monotonic sample age calculated at response time. Use age/status to assess freshness, not the wall clock. |

System memory comes from `host_statistics64(HOST_VM_INFO64)`:

```text
memory_used_bytes = (active pages + wired pages + compressor pages) × page_size
active_bytes     = active pages × page_size
inactive_bytes   = inactive pages × page_size
wired_bytes      = wired pages × page_size
compressed_bytes = compressor pages × page_size
free_bytes       = free pages × page_size
```

`physical_memory_bytes` and `page_size` are read at OS-adapter initialization. `compressed_bytes` measures pages occupied by the compressor, not the uncompressed size of their contents. Used memory excludes inactive/free pages by definition; it is not `physical_memory_bytes - free_bytes`, a memory-pressure score, or a promise to match Activity Monitor's display.

A `Metric` has `{ "value": ..., "status": ... }`. Only `ok` has a non-null value. `warming_up`, `permission_denied`, `exited`, `stale` and `unsupported` are not zero and must not be replaced with another metric. Cold start and newly discovered processes initially have `warming_up` rates. Counter resets or unusable intervals also require a new baseline.

Snapshot status is `warming_up` until the second sample, `stale` when age exceeds three effective intervals (idle fallback 5000 ms), or `unavailable` when PID enumeration failed. Failed enumeration does not mean every process exited. Check `coverage` (`enumerated`, `sampled`, `permission_denied`, `exited_during_sample`) when interpreting a partial process list.

## Sampling lifecycle

The agent owns collection, history and leases; clients only request/read data. The 1.0 scheduling contract is:

| Situation | Behavior |
| --- | --- |
| Main window visible | GUI lease, default 5000 ms; choices 1000/2000/5000/10000 ms |
| Menu bar enabled | Separate menu-bar lease, default 10000 ms |
| Several leases | Use their shortest interval, not a separate loop per lease/client |
| GUI lease renewal | 30-second TTL, renewed while the relevant UI is visible |
| MCP connected but idle | No periodic sampling just for staying connected |
| Bounded observation | Required duration 1000–60000 ms; no auto-renewal |
| Read request | Use cache if age ≤ effective interval, or ≤ 5000 ms while idle; otherwise join/trigger one shared collection |
| Cold start | Shared immediate collection and another about 1 second later; rates warm up between them |
| No active lease | No periodic sampling after any pending cold-start work; reads may still trigger collection |
| Disconnect | Immediately remove that client's leases and observations |
| No connected clients | Agent exits after a 60-second grace period; launchd starts it on demand |

Collection is **single-flight**, with starts no more frequent than once per 1000 ms. Requests waiting for the next allowed start also share that collection. The contract allows timer leeway of **10% of the interval**: tolerance, not an added delay or an exact-deadline guarantee. Missed ticks are not replayed. The GUI keeps only the latest undelivered snapshot and does not drive an independent OS sampler.

Lease expiry and history retention use monotonic time, including sleep. On wake, expired leases are dropped and history records a gap. System history is retained while sampling; process history only while pinned or observed. Defaults are 10 minutes, at most 600 points per series and 16 retained process series shared across clients. History never backfills unobserved time or draws continuity across a gap. The `history_bytes` diagnostic is an estimate of history storage, not the whole agent footprint.

## Acceptance budgets

From [PLAN §8](PLAN.md#8-最適化と性能予算), under **Release build, 5-second updates and 500 processes**. CPU budgets use the process convention (100% = one core); combined budgets sum the named processes.

| Metric | Acceptance target |
| --- | ---: |
| Agent average CPU | ≤ 0.3% |
| GUI + agent average CPU | ≤ 1.0% |
| GUI + agent + one MCP connection average CPU | ≤ 1.3% |
| One collection duration | p95 ≤ 40 ms |
| Main-thread update work | p95 ≤ 8 ms |
| GUI + agent steady-state footprint | ≤ 120 MiB |
| Additional footprint per MCP bridge | ≤ 30 MiB |
| History data | ≤ 8 MiB |
| Periodic collections with no active monitoring request | 0 |

An independent acceptance condition is that **three MCP clients do not triple collection loops**. Count collections, not just low CPU readings. Read-triggered work and cold-start work must be separated from the idle-periodic-collection check. `1 MiB = 1,048,576 bytes`.

## How to measure

The commands here describe the **intended 1.0 benchmark harness interface** from PLAN, not completed measurements. `scripts/benchmark.sh` is the benchmark entry point; `procglint-workload` is the controlled CPU/memory/disk and spawn/exit-churn fixture. No workload-specific flags are prescribed by the contract.

```sh
swift build -c release
# Build the fixture explicitly when measuring it separately:
swift build -c release --product procglint-workload
scripts/benchmark.sh
```

1. Use Release binaries, a registered agent, a 5000 ms policy and a controlled population of 500 total processes. Record the observed process count/range: do not confuse 500 workload children with 500 total processes. Use `procglint-workload` to exercise CPU, memory, disk I/O and churn; record the exact invocation/load profile for reproducibility.
2. Record hardware, OS/toolchain, commit, signing/build mode, power/thermal conditions, other load, warm-up and measurement duration. Wait for the second sample and a stable footprint before measuring steady state; report cold start separately. Keep system sleep/wake out of a steady-state run, or report it explicitly.
3. Measure agent alone, GUI + agent, then GUI + agent + one MCP bridge with the same sampling demands. Repeat with three MCP bridges; record tool-call rates, flags and observation intervals/durations. Use `collections_total` deltas over equal windows to verify shared collection. Do not introduce a 1-second observation into a 5-second-budget run.
4. Use `get_monitor_status` or `procglint status` for collection/coverage diagnostics and agent/client overhead. The scheduler's `collection_p95_ms` is a rolling diagnostic over at most 128 collections, not a whole-run percentile. Report a whole-run p95 when evaluating the budget. Main-thread update time needs separate GUI profiling (for example Instruments); a collection duration is not a UI timing measurement.
5. Report footprint (not RSS), the history estimate and each bridge's incremental cost. Test idle connections after releasing GUI/menu-bar/observation leases and allowing cold-start work to finish: periodic collections must stop. Test the no-client exit separately, since diagnostic polling itself keeps a client connected.

Do not infer a pass from a short unit-test run or a different process population. Keep measurements and their conditions together. The results table below is intentionally blank.

## Results

| Condition | Recorded value |
| --- | --- |
| Date / commit | |
| Mac model / chip / CPU cores / RAM | |
| macOS version / build | |
| Swift / Xcode or Command Line Tools version | |
| Release build command / signing mode | |
| Power source / thermal state / other load | |
| Policy / effective interval / history limits | |
| Warm-up / measurement duration / repetitions | |
| Process count / range / coverage | |
| Workload invocation / CPU-memory-disk-churn profile | |
| GUI window / menu-bar state | |
| MCP client count / flags / call rates / observations | |
| Sleep-wake events / other deviations | |
