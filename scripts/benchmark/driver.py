#!/usr/bin/env python3
"""Release benchmark driver. No third-party Python packages; stdout is the report."""
import argparse
import json
import math
import os
from pathlib import Path
import select
import signal
import statistics
import subprocess
import sys
import time
import unittest
from unittest.mock import patch


def cpu_seconds(value):
    days, _, clock = value.rpartition("-")
    parts = [float(part) for part in clock.split(":")]
    return (int(days) * 86400 if days else 0) + sum(
        part * 60 ** index for index, part in enumerate(reversed(parts))
    )


def ps_sample(pids):
    text = subprocess.check_output(
        ["ps", "-p", ",".join(map(str, pids)), "-o", "pid=,%cpu=,rss=,time="], text=True
    )
    rows = {}
    for line in text.splitlines():
        pid, cpu, rss, elapsed = line.split()
        rows[int(pid)] = dict(cpu=float(cpu), rss_kib=int(rss), cpu_seconds=cpu_seconds(elapsed))
    if set(rows) != set(pids):
        raise RuntimeError("A measured process exited")
    return rows


def machine_load():
    text = subprocess.check_output(["ps", "-axo", "pid=,pcpu=,comm="], text=True, timeout=10)
    processes = []
    for line in text.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            processes.append(dict(pid=int(fields[0]), cpu=float(fields[1]), name=Path(fields[2]).name))
    return dict(load_average=list(os.getloadavg()),
                busiest_processes=sorted(processes, key=lambda row: row["cpu"], reverse=True)[:10])


def window_cpu(before, after, pids, seconds):
    return 100 * sum(after[pid]["cpu_seconds"] - before[pid]["cpu_seconds"] for pid in pids) / seconds


def shared_collections(counts, seconds):
    # Periodic ticks may use the contractual 10% timer leeway; allow one boundary collection.
    lower = max(1, math.floor(seconds / 5.5) - 1)
    upper = math.ceil(seconds / 5) + 1
    return counts[2] <= counts[1] + 1 and all(lower <= count <= upper for count in counts)


def idle_stopped(row):
    # The >=10 s idle window outlives the 5 s cache; the ending status must account for exactly one collection.
    return (row["idle_new_history_points"] == 0 and row["collections"] == 1
            and row["initial"]["failures"] == row["final"]["failures"])


def read_line(process, timeout=30):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise RuntimeError(f"Timed out reading process {process.pid}")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError(f"Process {process.pid} closed stdout (exit {process.poll()})")
    return line


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    if process.stdout:
        process.stdout.close()
    if process.stdin:
        process.stdin.close()


class Bridge:
    def __init__(self, executable):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.sequence = 0
        try:
            self.rpc("initialize", dict(protocolVersion="2025-11-25", capabilities={},
                                        clientInfo=dict(name="benchmark", version="1")))
            self.send(dict(jsonrpc="2.0", method="notifications/initialized"))
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.sequence += 1
        self.send(dict(jsonrpc="2.0", id=self.sequence, method=method, params=params))
        response = json.loads(read_line(self.process))
        if response.get("id") != self.sequence or "error" in response:
            raise RuntimeError(f"MCP RPC failed: {response}")
        result = response["result"]
        if result.get("isError"):
            raise RuntimeError(f"MCP tool failed: {result}")
        return result

    def tool(self, name, arguments):
        return self.rpc("tools/call", dict(name=name, arguments=arguments))["structuredContent"]

    def close(self):
        stop(self.process)


def status(directory):
    return json.loads(subprocess.check_output([str(directory / "procglint"), "status", "--json"], timeout=30))


def history_points(bridge):
    series = bridge.tool("get_history", dict(series=["system"]))["series"]
    return [point["t"] for point in series[0]["points"]]


def measure(directory, bridges, seconds, idle=False):
    load_before = machine_load()
    initial = status(directory)
    if initial["sampling_active"] == idle:
        raise RuntimeError("Unexpected lease state; close Procglint GUI and other observing clients")
    if not idle and initial["effective_interval_ms"] != 5000:
        raise RuntimeError("Benchmark requires an effective 5000 ms interval")
    points_before = history_points(bridges[0]) if idle else []
    agent = initial["agent_pid"]
    bridge_pids = [bridge.process.pid for bridge in bridges]
    pids = [agent] + bridge_pids
    first = ps_sample(pids)
    samples = [first]
    start = time.monotonic()
    next_read = start
    next_ps = start + 1
    while time.monotonic() < start + seconds:
        now = time.monotonic()
        if not idle and bridges and now >= next_read:
            # Deliberately synchronize clients: their reads should share the same collection/cache.
            for bridge in bridges:
                snapshot = bridge.tool("get_snapshot", dict(top=50, sort="cpu"))
                if len(snapshot["processes"]) > 50:
                    raise RuntimeError("get_snapshot ignored top=50")
            next_read += 5
        if now >= next_ps:
            samples.append(ps_sample(pids))
            next_ps += 1
        time.sleep(min(0.05, max(0, start + seconds - time.monotonic())))
    last = ps_sample(pids)
    elapsed = time.monotonic() - start
    samples.append(last)
    # History reads do not call freshSnapshot. Check BEFORE the ending status read, which may collect.
    points_after = history_points(bridges[0]) if idle else []
    new_idle_points = len(set(points_after) - set(points_before))
    final = status(directory)
    if final["agent_instance_id"] != initial["agent_instance_id"]:
        raise RuntimeError("Agent restarted during measurement")
    count = int(final["collections_total"]) - int(initial["collections_total"])
    footprints = {client["pid"]: client["footprint_bytes"] for client in final["clients"]}
    bridge_footprints = [footprints[pid] / 1048576 for pid in bridge_pids]
    return dict(
        elapsed_s=elapsed, agent_cpu=window_cpu(first, last, [agent], elapsed),
        bridge_cpu=window_cpu(first, last, bridge_pids, elapsed),
        ps_agent_cpu_mean=statistics.mean(sample[agent]["cpu"] for sample in samples),
        agent_rss_mib=statistics.mean(sample[agent]["rss_kib"] for sample in samples) / 1024,
        bridge_rss_mib=sum(statistics.mean(sample[pid]["rss_kib"] for sample in samples) / 1024 for pid in bridge_pids),
        agent_footprint_mib=final["agent_footprint_bytes"] / 1048576,
        bridge_footprint_mib=bridge_footprints, collections=count, idle_new_history_points=new_idle_points,
        initial=initial, final=final, ps_samples=samples,
        load_before=load_before, load_after=machine_load(),
    )


def run(args):
    directory = Path(args.binary_dir).resolve()
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    children = []
    bridges = []
    try:
        workload = subprocess.Popen([args.workload, "spawn", "--count", str(args.count)], stdout=subprocess.PIPE)
        children.append(workload)
        ready = read_line(workload, timeout=120).decode().strip()
        print(ready, file=sys.stderr)
        lease = subprocess.Popen([str(directory / "benchmark-lease")], stdout=subprocess.PIPE)
        children.append(lease)
        read_line(lease)
        results = []
        for clients in (0, 1, 3):
            for bridge in bridges:
                bridge.close()
            bridges = []
            for _ in range(clients):
                bridges.append(Bridge(directory / "procglint-mcp"))
            print(f"Warm-up {args.warmup}s, measuring lease + {clients} MCP for {args.seconds}s", file=sys.stderr)
            time.sleep(args.warmup)
            result = measure(directory, bridges, args.seconds)
            result["condition"] = f"5 s lease + {clients} MCP"
            results.append(result)
        stop(lease)
        print(f"Measuring idle connections, no leases, for {args.seconds}s", file=sys.stderr)
        time.sleep(3)  # Disconnect cleanup and any bounded pending collection are outside the idle window.
        idle = measure(directory, bridges, args.seconds, idle=True)
        idle["condition"] = "No leases, 3 idle MCP"
        results.append(idle)
        (output / "measurements.json").write_text(json.dumps(results, indent=2))
        print("| Condition | Window s | Agent CPU % | MCP CPU % (sum) | Agent RSS MiB (mean) | MCP RSS MiB (sum means) | Agent footprint MiB | MCP footprint MiB (each) | Collections Δ | Collection rolling p95 ms | Readable / enumerated | History MiB |")
        print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- | ---: |")
        for row in results:
            bridges_mib = ", ".join(f"{value:.2f}" for value in row["bridge_footprint_mib"]) or "—"
            print(f"| {row['condition']} | {row['elapsed_s']:.2f} | {row['agent_cpu']:.3f} | {row['bridge_cpu']:.3f} | "
                  f"{row['agent_rss_mib']:.2f} | {row['bridge_rss_mib']:.2f} | {row['agent_footprint_mib']:.2f} | {bridges_mib} | "
                  f"{row['collections']} | {row['final']['collection_p95_ms']:.3f} | "
                  f"{row['final']['last_coverage']['sampled']} / {row['final']['last_coverage']['enumerated']} | "
                  f"{row['final']['history_bytes'] / 1048576:.3f} |")
        print("\nLoad snapshots (1/5/15-minute averages; other-process CPU is a boundary snapshot, not a window average):")
        for row in results:
            before = "/".join(f"{value:.2f}" for value in row["load_before"]["load_average"])
            after = "/".join(f"{value:.2f}" for value in row["load_after"]["load_average"])
            busiest = ", ".join(f"{item['name']} {item['cpu']:.1f}%" for item in row["load_before"]["busiest_processes"][:5])
            print(f"- {row['condition']}: {before} → {after}; busiest before: {busiest}.")
        print(f"\nRaw status, ps and load samples: `{output}/measurements.json`.")
        print("CPU uses window deltas of ps cumulative CPU time (one core = 100%); ps %cpu is also saved, but is a decayed average, not window CPU.")
        print("The lease helper is not a GUI; its CPU/memory are excluded. RSS is not footprint. Status reads can add one boundary collection.")
        counts = [row["collections"] for row in results[:3]]
        shared = shared_collections(counts, args.seconds)
        stopped = idle_stopped(idle)
        print(f"\nShared-collection check: {'PASS' if shared else 'FAIL'} (0/1/3 MCP deltas {counts}).")
        print(f"Idle-periodic check: {'PASS' if stopped else 'FAIL'} ({idle['idle_new_history_points']} new history points BEFORE final status; status-inclusive Δ={idle['collections']}).")
        cpu_ok = all(row['agent_cpu'] <= 0.3 for row in results[:3])
        memory_ok = all(value <= 30 for row in results for value in row['bridge_footprint_mib'])
        collection_ok = all(row['final']['collection_p95_ms'] <= 40 for row in results[:3])
        print(f"Agent CPU ≤0.3% (all active cases): {'PASS' if cpu_ok else 'FAIL'}.")
        print(f"Bridge footprint ≤30 MiB each: {'PASS' if memory_ok else 'FAIL'}.")
        print(f"Agent rolling collection p95 ≤40 ms: {'PASS' if collection_ok else 'FAIL'} (diagnostic includes warm-up; not a per-window percentile).")
        print("GUI combined CPU/footprint and main-thread p95: NOT MEASURED. Compare process population/conditions before claiming budget acceptance.")
        return 0 if shared and stopped and cpu_ok and memory_ok and collection_ok else 1
    finally:
        for bridge in bridges:
            bridge.close()
        for child in reversed(children):
            stop(child)


class SelfTests(unittest.TestCase):
    def test_cpu_time(self):
        self.assertEqual(cpu_seconds("1:02.50"), 62.5)
        self.assertEqual(cpu_seconds("2:03:04.01"), 7384.01)
        self.assertEqual(cpu_seconds("1-00:00:01"), 86401)

    def test_load_snapshot_keeps_names_not_arguments(self):
        text = "12 20.5 /Applications/OrbStack Helper\n8 99.1 /bin/compiler\n3 0.0\n"
        with patch(__name__ + ".subprocess.check_output", return_value=text), patch(__name__ + ".os.getloadavg", return_value=(3, 4, 5)):
            load = machine_load()
        self.assertEqual(load["load_average"], [3, 4, 5])
        self.assertEqual([row["name"] for row in load["busiest_processes"]], ["compiler", "OrbStack Helper"])

    def test_window_not_decayed_cpu(self):
        before = {1: dict(cpu_seconds=5), 2: dict(cpu_seconds=10)}
        after = {1: dict(cpu_seconds=5.2), 2: dict(cpu_seconds=10.1)}
        self.assertAlmostEqual(window_cpu(before, after, [1, 2], 100), 0.3)

    def test_collection_budget(self):
        self.assertTrue(shared_collections([24, 24, 25], 120))
        self.assertTrue(shared_collections([21, 23, 24], 120))
        self.assertFalse(shared_collections([24, 24, 72], 120))
        self.assertFalse(shared_collections([1, 1, 1], 120))

    def test_idle_excludes_only_the_ending_read(self):
        row = dict(idle_new_history_points=0, collections=1,
                   initial=dict(failures={}), final=dict(failures={}))
        self.assertTrue(idle_stopped(row))
        self.assertFalse(idle_stopped(dict(row, collections=2)))
        self.assertFalse(idle_stopped(dict(row, idle_new_history_points=1)))
        self.assertFalse(idle_stopped(dict(row, final=dict(failures=dict(enumeration=1)))))

    def test_rpc_validation(self):
        for response, succeeds in [
            (dict(id=1, result=dict(value=1)), True),
            (dict(id=2, result={}), False),
            (dict(id=1, error=dict(code=-1)), False),
            (dict(id=1, result=dict(isError=True)), False),
        ]:
            bridge = Bridge.__new__(Bridge)
            bridge.sequence = 0
            bridge.process = None
            bridge.send = lambda value: None
            with self.subTest(response=response), patch(__name__ + ".read_line", return_value=json.dumps(response)):
                if succeeds:
                    self.assertEqual(bridge.rpc("test", {}), dict(value=1))
                else:
                    with self.assertRaises(RuntimeError):
                        bridge.rpc("test", {})

    def test_tool_projection(self):
        class FakeBridge(Bridge):
            def __init__(self):
                self.response = dict(structuredContent=dict(processes=[]))

            def rpc(self, method, params):
                self.assertion = (method, params)
                return self.response
        bridge = FakeBridge()
        self.assertEqual(bridge.tool("get_snapshot", dict(top=50)), dict(processes=[]))
        self.assertEqual(bridge.assertion, ("tools/call", dict(name="get_snapshot", arguments=dict(top=50))))


def main():
    if sys.argv[1:] == ["--self-test"]:
        unittest.main(argv=[sys.argv[0]])
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary-dir", required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--warmup", type=int, default=15)
    parser.add_argument("--count", type=int, default=500)
    args = parser.parse_args()
    if not 10 <= args.seconds <= 3600 or not 1 <= args.count <= 10000 or not 2 <= args.warmup <= 120:
        parser.error("seconds must be 10...3600, count 1...10000, warmup 2...120")
    def interrupted(number, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return run(args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
