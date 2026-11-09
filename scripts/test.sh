#!/bin/bash
# Runs `swift test`. On a Command Line Tools-only machine the Swift Testing macro
# plugin is not on the default search path, so point the compiler at it.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
# SwiftUI macros (used by the app) ship only with Xcode; prefer it when installed.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif [[ "$(xcode-select -p)" == */CommandLineTools ]]; then
  args+=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
