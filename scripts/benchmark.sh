#!/bin/bash
# Release agent benchmark; stdout is Markdown, setup/build logs go to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help ]]; then
  echo "Usage: $0 [--seconds 120] [--count 500] [--warmup 15]" >&2
  echo "Four equal windows; adds COUNT idle children to the existing process population." >&2
  exit 0
fi
# Validate arguments before building or touching launchd.
python3 -I - "$@" <<'PY'
import argparse
p = argparse.ArgumentParser()
p.add_argument('--seconds', type=int, default=120)
p.add_argument('--count', type=int, default=500)
p.add_argument('--warmup', type=int, default=15)
a = p.parse_args()
if not 10 <= a.seconds <= 3600 or not 1 <= a.count <= 10000 or not 2 <= a.warmup <= 120:
    p.error('seconds must be 10...3600, count 1...10000, warmup 2...120')
PY

require_unregistered_agent() {
  for label in io.github.mkusaka.procglint.agent io.github.mkusaka.procglint.agent.dev; do
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      echo "Stop/unregister the existing $label before benchmarking; it will not be replaced." >&2
      exit 1
    fi
  done
}
require_unregistered_agent
scripts/build-app.sh --configuration release >&2
swift build --scratch-path .build/app-bundle -c release --arch arm64 --product procglint-workload >&2
bin="$(swift build --scratch-path .build/app-bundle -c release --arch arm64 --show-bin-path)"
helpers="$PWD/build/Procglint.app/Contents/Helpers"
output="$PWD/.build/benchmark/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"

# SPM 6.1 emits per-file objects; 6.4's build engine emits merged target objects.
map="$(find .build/app-bundle -type f \( -name CProcglintDarwin.modulemap -o -path '*/CProcglintDarwin.build/module.modulemap' \) -print -quit)"
if [[ -z "$map" ]]; then echo "Cannot locate the CProcglintDarwin module map" >&2; exit 1; fi
if [[ -f "$bin/ProcglintCore.o" ]]; then
  objects=("$bin/ProcglintIPC.o" "$bin/ProcglintCore.o" "$bin/CProcglintDarwin.o")
else
  objects=("$bin"/ProcglintIPC.build/*.o "$bin"/ProcglintCore.build/*.o "$bin"/CProcglintDarwin.build/*.o)
fi
swiftc -O -swift-version 6 -target arm64-apple-macosx15.0 -parse-as-library \
  -I "$bin" -I "$bin/Modules" -Xcc "-fmodule-map-file=$PWD/$map" \
  scripts/benchmark/LeaseClient.swift "${objects[@]}" -o "$helpers/benchmark-lease" >&2
codesign --force --sign - "$helpers/benchmark-lease" >&2
python3 -I scripts/benchmark/driver.py --self-test >&2

started=false
worker=
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$worker" ]]; then
    kill -TERM "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
  fi
  if $started; then scripts/dev-agent.sh stop >&2; fi
  rm -f "$helpers/benchmark-lease"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A build can take minutes; do not replace an agent registered by another session in the meantime.
require_unregistered_agent
started=true
scripts/dev-agent.sh start --binary "$helpers/procglint-agent" >&2
python3 -I scripts/benchmark/driver.py --binary-dir "$helpers" \
  --workload "$bin/procglint-workload" --output-dir "$output" "$@" &
worker=$!
result=0
wait "$worker" || result=$?
worker=
exit "$result"
