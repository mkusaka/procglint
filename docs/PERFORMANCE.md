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

**Adaptive removed the dominant Background-policy delay, but this busy-machine run is still not a complete budget pass.** Agent-only collection p95 fell from **337.536 to 23.462 ms at the same 0.183% CPU**. The final all-collection aggregate fell from **408.143 to 40.656 ms**—a large improvement, but still **0.656 ms above** the 40 ms target. CPU with MCP reads also remains above the 0.3% agent-only reference. Sharing, idle and bridge-memory checks pass.

The deployed policy is **Adaptive** in both the bundled and dev plists. No scheduler timing boundary, Task priority, sampling coverage or permission check was changed.

### Adaptive follow-up: uninstrumented Release benchmark

Invocation: `scripts/benchmark.sh --seconds 120 --count 500 --warmup 15`, on 2026-11-09 JST / 2026-11-08 UTC. Same Mac/OS/toolchain and 5-second policy as the initial baseline below; one 120-second window per case, 15-second warm-ups. Both the built app's plist and generated dev plist contained `Adaptive`; `launchctl print` confirmed the live job's spawn type was adaptive. This was the normal Release build, **without diagnostic compiler flags, trace output, activity assertions or priority overrides**.

The workload added **500 idle children**, not 500 total processes. Across eight status boundaries: **1499–1555 enumerated, 1253–1300 readable**, 244–254 denied and 1–2 exited during collection. No collection failures were recorded. CPU is window CPU time / elapsed time × 100 (one core = 100%); RSS is not footprint. No real GUI was launched: the separate Swift client held a GUI-equivalent lease.

| Condition | Window s | Agent CPU % | MCP CPU % (sum) | Agent RSS MiB (mean) | MCP RSS MiB (sum means) | Agent footprint MiB | Bridge footprints MiB (each) | Collections Δ | Rolling collection p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 5 s lease, no MCP | 120.22 | 0.183 | 0 | 9.18 | 0 | 5.42 | — | 23 | **23.462** |
| 5 s lease + 1 MCP | 120.06 | 0.325 | 0.217 | 12.06 | 8.12 | 6.94 | 4.69 | 23 | **53.922** |
| 5 s lease + 3 MCP | 120.08 | 0.575 | 0.633 | 13.59 | 25.43 | 12.30 | 5.45, 5.41, 5.39 | 24 | **40.656** |
| No leases, 3 idle MCP | 120.09 | 0.008 | 0 | 7.28 | 15.83 | 8.27 | 5.09, 4.63, 4.61 | 1* | 40.656 |

- **Sharing passed:** 23 / 23 / 24 collections, not three independent loops. The cadence check permits the contract's 10% timer leeway and one boundary collection; it does not require exactly 24 ticks.
- **Idle passed:** zero new system-history points before the ending diagnostic read, exactly one status-inclusive collection, and no new collection failures. The marked one collection was the final read, not periodic work.
- The final **84 collections** fit inside the 128-duration ring, so 40.656 ms represents the aggregate of the entire agent run, including cold start/warm-up and boundary reads. Row percentiles are cumulative, **not per-window percentiles**. The 53.922 ms and final 40.656 ms breaches are reported as failures, not rounded down or replaced with standalone test timings.
- The harness exited **1**, correctly reporting CPU and latency failures while passing sharing, idle and bridge footprint. Cleanup removed the registration, workload, bridges and lease helper; `codesign --verify --deep --strict` passed again afterwards.
- Raw measurements: `.build/benchmark/20261109-023551/measurements.json`. The stdlib-only driver now saves 1/5/15-minute load averages and busiest process **names**/CPU at both boundaries of each case (not command-line arguments).

This Mac remained busy with other work; no applications, builds or VMs were stopped. Load snapshots and top consumers below are boundary observations, not time-averaged CPU attributable to the whole window:

| Condition | Load averages before → after (1 / 5 / 15 min) | Observed other work before the window |
| --- | --- | --- |
| No MCP | 55.18 / 55.24 / 55.63 → 52.90 / 56.38 / 56.16 | OrbStack Helper 320.3%, tsrs 68.0%, fseventsd 62.9%, Bun 46.2%, dotnet 39.9% |
| 1 MCP | 47.36 / 55.01 / 55.68 → 45.34 / 51.83 / 54.33 | OrbStack Helper 515.1%, fseventsd 96.4%, Bun workers 84.4% / 83.5%, git 60.1% |
| 3 MCP | 39.50 / 50.08 / 53.64 → 47.22 / 47.87 / 52.21 | OrbStack Helper 853.6%, fseventsd 53.4%, Bun workers 47.2% / 35.4%, Chrome Helper 28.4% |
| Idle | 44.72 / 47.34 / 52.00 → 59.24 / 51.50 / 53.01 | OrbStack Helper 739.3%, fseventsd 64.4%, Bun workers 63.9% / 51.9%, WindowServer 37.4% |

Parallel-build/browser/VM activity was also visible during diagnosis, including Roslyn `VBCSCompiler`, Node/Bun/git workers and headless Chromium. Our build and ordinary test run finished before these timed benchmark windows. The remaining stalls were not isolated to a new code defect; this is **not** a claim that changing ProcessType guarantees real-time scheduling or proves acceptance at the specified approximately 500-readable-process population.

### Review investigation: wall time was resource-policy waiting, not 400 ms of CPU work

Temporary Release-only instrumentation recorded scheduler task admission, throttle wait, entry/return around the sampler actor, sampler wall/thread-CPU time, and post-measurement store/history/fan-out. A second pass traced slow BSD/rusage and username calls; its final version buffered trace records until after the sweep timestamp to avoid logging I/O inside the sweep. All instrumentation, environment switches and activity/priority experiments were removed from production sources after measurement. Logs and the temporary patch are retained under `.build/perf-review*/`.

**Timing boundary, unchanged:** `SamplingScheduler.performCollection` starts timing **after** the minimum-one-second throttle sleep, immediately before `await collect()`, and records duration after that await resumes. It includes sampler entry/return actor hops and the full synchronous sweep. It excludes admission of the collection task before that start, and the subsequent snapshot store, history update and subscriber delivery. The fix does not relocate either timestamp.

A representative delayed collection from the first trace had:

| Component | Observed time |
| --- | ---: |
| Reported collection | 501.026 ms |
| Inside `Sampler.sample()` | **498.962 ms wall, 9.314 ms thread CPU** |
| Collection start → sampler entry | 0.002 ms |
| Sampler end → scheduler resume (upper bound on return-hop cost; includes return construction and trace output) | 2.062 ms |
| Initial collection-task admission, outside the metric | 2.826 ms |
| Throttle check/wait in that collection, outside the metric | 0.0004 ms |
| Store/history/fan-out after the duration was recorded | 23.470 ms; no subscribers |

This rules out the throttle sleep, store/fan-out and actor contention as the source of that 501 ms diagnostic. Slow calls were seen against ordinary idle workload children too (e.g. BSD **45.586 ms wall / 0.021 ms CPU**), not just busy third-party processes. No username lookup exceeding 5 ms was observed in the instrumented app runs. The sampler has no suspension point within a sweep, so the large wall/CPU gap is OS scheduling/resource waiting, not a chain of Swift actor awaits.

**Process-type controls:** the first same-binary, 500-child comparison, with 12 s warm-up and 50 s measured windows, produced Background p95 **100.712 ms**, Adaptive **501.026 ms**, Standard **570.834 ms**, Adaptive + three active MCP readers **9.500 ms**, and a repeated Background **359.390 ms**. Thus changing a plist once on this varying-load machine was not sufficient evidence by itself; Standard was not a reliable escape from throttling either.

The hardened-runtime, app-layout controls then isolated priority/activity from process classification:

| Process type | Treatment | Job's final collection p95 | Conclusion |
| --- | --- | ---: | --- |
| Adaptive | Ordinary priority, no activity assertion | 57.634 ms; repeat **28.790 ms** | Can service leased work promptly without a priority override; occasional load-related stalls remain possible |
| Adaptive | Scoped user-initiated activity only during a sweep | 237.616 ms | Not a consistent improvement; discarded |
| Background | Same scoped activity | 1538.862 ms | An App Nap assertion does not remove forced Background resource limits |
| Adaptive | Sampler explicitly at Swift priority/QoS 25 | **27.330 ms** | Essentially the ordinary Adaptive repeat; no priority change justified |
| Background | Identical priority/QoS 25 sampler | **869.278 ms** | Higher Swift priority does not rescue forced Background classification |
| Adaptive | User-initiated activity held for the entire diagnostic job | 29.854 ms | No useful advantage over plain Adaptive; not shipped |
| Interactive | Ordinary priority, no activity assertion | 34.670 ms | No advantage justifying permanently unthrottled classification |

Each control job had approximately 13–14 collections including startup/warm-up; the final p95 is not a separate 50-second-window percentile and is sensitive to individual stalls at this sample count. Five hundred children were held across each comparison sequence, but other desktop jobs/population/load varied. These are mechanism controls, not a claim of a quiet, statistically controlled throughput speedup. The final uninstrumented 120-second benchmark is the acceptance check.

Normal timer, scheduler and sampler tasks all reported **Swift priority 21 / QoS 21**. Housekeeping alone reported **priority 9**, as intended; it neither called the sampler nor donated that background priority to collection tasks. In the explicit-priority control the sampler really reported **25 / 25**, yet Background remained slow. No housekeeping or collection Task-priority tuning is shipped.

**Why Adaptive:** local `launchd.plist(5)` documents Background as work not directly requested by the user, Standard as light CPU/I/O resource limits, and Adaptive as switching Background/Interactive classification based on XPC activity. `xpc_main(3)` documents the lifetime of message/reply priority boosts. This agent works on behalf of GUI/MCP clients, not as an unconditional maintenance daemon. Adaptive permits those boosts while allowing idle work to return to Background; it is deliberately **not always Interactive**. The trade-off is potentially more prompt competition for resources while serving a client, in exchange for timely UI/XPC results. No never-ending transaction, power assertion, raised nice value, fixed high-priority Task, or disabled system sleep was introduced. The on-demand launch, no-lease stop and idle exit policy are unchanged.

### Initial Background baseline conditions (2026-11-08 UTC / 2026-11-09 JST)

| Condition | Recorded value |
| --- | --- |
| Date / commit | 2026-11-08 UTC; `6ca8ab4` plus uncommitted E2 changes |
| Mac model / chip / CPU cores / RAM | `Mac17,6`; Apple M5 Max; 18 logical cores; 64 GiB |
| macOS version / build | macOS 27.2 / `26B123`, arm64 |
| Swift / Xcode or Command Line Tools version | Apple Swift 6.4 (`swiftlang-6.4.0.34.1`); CLT `27.0.0.0.1788430756` |
| Release build command / signing mode | `scripts/benchmark.sh --seconds 120 --count 500 --warmup 15`; calls `scripts/build-app.sh --configuration release`; ad-hoc, hardened-runtime helpers, dev LaunchAgent `ProcessType=Background` |
| Power source / thermal state / other load | AC, charging; `pmset -g therm` reported no recorded thermal/performance warning. Shared, heavily loaded desktop: load averages **54.27 / 69.07 / 71.51** during the run. Other applications/jobs were not stopped. |
| Policy / effective interval / history limits | Revision 0; GUI/effective 5000 ms, menu bar 10000 ms; 10 minutes, 600 points/series, 16 process series |
| Warm-up / measurement duration / repetitions | 15 s before each active case; one approximately 120 s window per case; idle after lease-holder disconnect and 3 s settling. No repeated steady-state runs. |
| Process count / range / coverage | At eight status boundaries: **1497–1574 enumerated, 1264–1314 sampled/readable**, 208–269 denied, 1–4 exited during collection. These are boundary observations, not continuous population extrema. No agent collection failures were recorded. |
| Workload invocation / CPU-memory-disk-churn profile | `procglint-workload spawn --count 500`: **500 additional idle children**, not 500 total processes. CPU/memory/disk/churn stress was not mixed into the budget windows. Separate functional checks exercise those modes. |
| GUI window / menu-bar state | No GUI or menu bar launched. A tiny authenticated XPC client holds a `gui_window` lease at 5000 ms, renewed every 10 s; its overhead is excluded. **This is not a GUI performance measurement.** |
| MCP client count / flags / call rates / observations | 0, 1, then 3 stdio bridges; no flags (own processes, read-only); each active bridge calls `get_snapshot(top: 50, sort: cpu)` every 5 s, synchronized. No observations or preference changes needed. Idle case retains the 3 connections without tool polling. |
| Sleep-wake events / other deviations | No sleep/wake was deliberately induced; power events were not independently logged. Population already exceeded 500 before fixture spawning. Exact 500-process, quiet-machine acceptance remains unverified. |

The harness is implemented in `scripts/benchmark.sh` and the visible `scripts/benchmark/` directory. The small Swift lease holder is compiled separately, so no shipping target needs a debug command. The Python driver remains stdlib-only and every harness/test invocation uses `python3 -I` to ignore ambient Python paths and environment customizations. A Swift port of the subprocess/framing/statistics code would not simplify this helper. `scripts/dev-agent.sh start --binary /absolute/path` selects the already-built Release agent. Existing registered agents are refused rather than overwritten; children, bridges, lease holder and dev registration are removed on exit.

### Initial Background LaunchAgent, fixed windows

CPU below is **window CPU time / elapsed time × 100**, from `ps -o time` deltas; 100% is one core. The driver also saves `ps -o %cpu,rss` samples once a second, but does not mistake the decayed `%cpu` column for window-average CPU. Footprints come from `procglint status --json`; RSS is reported separately. Initial/final status reads bracket, rather than pollute, the timed CPU window.

| Condition | Window s | Agent CPU % | MCP CPU % (sum) | Agent RSS MiB (mean) | MCP RSS MiB (sum means) | Agent footprint MiB | Bridge footprints MiB (each) | Collections Δ | Agent rolling p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 5 s lease, no MCP | 120.02 | 0.183 | 0 | 12.10 | 0 | 5.48 | — | 23 | 337.536 |
| 5 s lease + 1 MCP | 120.45 | 0.398 | 0.224 | 11.84 | 8.03 | 7.77 | 4.92 | 23 | 440.980 |
| 5 s lease + 3 MCP | 120.15 | 0.624 | 0.608 | 13.28 | 25.44 | 9.19 | 5.31, 5.19, 5.34 | 23 | 408.143 |
| No leases, 3 idle MCP | 120.11 | 0.008 | 0.008 | 7.75 | 17.41 | 7.53 | 5.14, 4.66, 4.67 | 1* | 408.143 |

- **Sharing passed:** collection deltas were **23 / 23 / 23**, not 23 / 46 / 69. Starts are not an exact 24-per-window promise: leeway, late ticks and boundary reads apply.
- **Idle passed:** `get_history(system)` before/after the idle window showed **zero new history points** before the ending status request. `status` itself calls `freshSnapshot`, so the final diagnostic read accounts for the marked **one collection**, not an idle periodic loop. Using only two status counters would conflate these.
- Rolling p95 is cumulative across earlier cases and warm-up, **not a separate percentile for each 120 s window**. The final status counted 82 total collections, below the 128-duration retention cap; its **408.143 ms** is therefore the aggregate all-collection p95 for this agent run, including warm-up/boundary work. Per-window agent p95 was not instrumented. All three active-case diagnostic percentiles exceed 40 ms.
- Raw status endpoints and `ps` samples are retained locally at `.build/benchmark/20261109-012107/measurements.json` (ignored build artifact). The script prints the Markdown table to stdout and reports failed CPU/latency checks, not just successful sharing/idle checks.

### Standalone sampler, store, encoding and full-cap history

Run with 500 fixture children alive:

```sh
PROCGLINT_PERF=1 scripts/test.sh -c release --skip-build --filter PerformanceMeasurements
PROCGLINT_PERF=1 scripts/test.sh --skip-build --filter PerformanceMeasurements
```

Build the corresponding test configuration first (omit `--skip-build` on a fresh checkout). Each sweep test discards one warm-up sweep and measures 50 consecutive full real-OS `Sampler.sample()` calls; it does not sleep five seconds between calls or run inside the background LaunchAgent. Store/encoding tests use an exactly 500-row fake-source dataset and a fake sampling clock, with real monotonic elapsed-time measurements; history uses a deterministic fake clock to reach the full caps without waiting ten minutes.

| Measurement | Release | Debug (report only) |
| --- | ---: | ---: |
| Full real-OS sweep, n=50, p95 | **7.281 ms** | 46.742 ms |
| Full sweep mean | 6.421 ms | 19.884 ms |
| Readable processes during sweep test | 1189–1191 | 1197–1198 |
| Enumerated processes during sweep test | 1392–1398 | 1396–1398 |
| Store query, 500 rows → 200-row page, n=50, p95 | 0.498 ms | 15.378 ms |
| JSON encoding of that page, n=50, p95 | 13.614 ms | 83.381 ms |
| Encoded page size | 102,115 bytes | 102,115 bytes |
| History estimate: system + 16 processes, 600 points each, including provision for capped gaps | **1,391,552 bytes (1.327 MiB)** | Same |

The real-OS test asserts only own-PID presence plus the explicitly opted-in **Release** 40 ms limit. Debug prints the observed 46.742 ms without asserting a Release budget. Query/page counts, JSON round-trip and full-cap history counts are checked as well. No timing assertion is applied to store/encoding or ordinary fast regression tests.

### Optimization measured first

The initial production code optimization removed the duplicate pre-rusage BSD read in `Sources/ProcglintCore/OS/DarwinProcessSource.swift`.

| Successful readable PID / sweep | Before | After |
| --- | ---: | ---: |
| `proc_pidinfo` BSD reads | 3 | **2** |
| `proc_pid_rusage` | 1 | 1 |
| Combined per-PID calls (not including enumeration/host calls) | 4 | **3 (25% fewer)** |
| First comparison, 50-sweep mean | 8.407 ms | 7.382 ms |
| First comparison, 50-sweep p95 | 9.185 ms | 9.174 ms |
| Readable population in that comparison | 1261–1284 | 1230–1240 |

These initial before/after timings are not a controlled A/B: population and desktop load varied. Mean improved in the observation; **p95 was effectively unchanged**, so no tail-latency improvement is claimed. The later 7.281 ms result above is a separate measurement, not a claimed like-for-like speedup.

Identity safety remains bracketed: sampler, lazy-path validation and termination already obtain BSD identity before the counter read, and compare it with the adapter's post-counter BSD identity. A mismatched start time is rejected; permission-denied rows retain their verified pre-read identity. No identity contract/model changes or rusage-abstime/wall-time mixing were introduced. The non-gated counting-fake test locks the sampler-facing budget to one BSD call plus one rusage call per PID, no eager paths, one enumeration/host/VM read per sweep. The Darwin adapter supplies the second BSD check internally; that internal check is not itself counted by the fake wrapper.

Metadata/user caches and lazy paths were already present; the regression verifies bounded cache counts and the shared UID cache. PID/path buffers were already reused by the adapter. Store-query cost did not justify another cache or allocation abstraction, and no task-per-PID, reduced process coverage, permission bypass, explicit high-priority Task or always-Interactive daemon was added to force a pass.

The workload fixture also replaced sequential Foundation spawn/wait in churn with `posix_spawn`/`waitpid`: a requested 100/s produced only **14 exits in 1.048 s** before, versus **100 exits in 1.026 s** after; a separate final Release check produced **200 exits in 2.010 s** at requested 100/s. The fixture reports actual counts/elapsed time rather than promising an unachievable rate under scheduler pressure. Separate disk validation wrote/fsynced/read 8 MiB and removed its temporary file; CPU/memory, PATH-based re-exec and parent-death cleanup are covered by subprocess tests.

Separate fixture calibration: `cpu --threads 2 --seconds 2` uses two dedicated worker threads and completed in **2.08 s wall / 0.95 s user / 0.02 s system** on this contended host. That is about 47% of one core averaged over the run, **not evidence of a sustained 200% load**; requested worker count does not guarantee CPU admission. `memory --mib 64` touched/held the allocation and showed **71,408 KiB RSS**, then exited cleanly on SIGTERM. This is an RSS sanity check, not a footprint measurement. These stress checks were outside the agent budget windows.

### Current Adaptive budget verdicts and remaining work

| Budget / acceptance condition | Verdict on the uninstrumented follow-up |
| --- | --- |
| Agent alone CPU ≤0.3% | **Within threshold: 0.183%**; larger, uncontrolled population caveat applies |
| Agent CPU with MCP traffic against the same 0.3% reference | **Above threshold: 0.325% / 0.575%** for 1 / 3 MCP |
| GUI + agent CPU ≤1.0% | **Unverified** — no real GUI |
| GUI + agent + 1 MCP CPU ≤1.3% | **Unverified** — agent + bridge alone was 0.542%; no GUI cost may be inferred |
| Collection p95 ≤40 ms | Agent-only diagnostic **23.462 ms**, but **aggregate 40.656 ms fails**; 1-MCP cumulative diagnostic was 53.922 ms |
| Main-thread update p95 ≤8 ms | **Unverified** — needs GUI profiling |
| GUI + agent footprint ≤120 MiB | **Unverified** — no real GUI; agent active-case endpoints 5.42–12.30 MiB |
| Additional bridge footprint ≤30 MiB | **Within threshold:** active bridges 4.69–5.45 MiB each |
| History ≤8 MiB | **Within estimate:** full caps 1.327 MiB; system-only follow-up estimate 0.078 MiB |
| No active leases → zero periodic collections | **Passed**, independently of the final read-triggered collection |
| Three MCP clients do not triple collection loops | **Passed**, equal-window deltas 23 / 23 / 24 |

Reducing redundant BSD calls alone did **not** fix the initial Background agent's latency or all-active-case CPU result. The subsequent instrumented controls above isolated the resource-policy wait and justified Adaptive instead of priority/activity tuning. RSS is not used as a substitute for footprint. Repeat on a quiet machine at approximately 500 readable processes, then profile the real GUI, before declaring the 1.0 budgets accepted. macOS 15 / Swift 6.1, signed/notarized deployment, sleep/wake and a 24-hour soak were not verified by this run.
