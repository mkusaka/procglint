#!/bin/bash
# Runs `swift test`. On a Command Line Tools-only machine the Swift Testing macro
# plugin is not on the default search path, so point the compiler at it.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
if [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
  args+=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)
fi
exec swift test "${args[@]}" "$@"
