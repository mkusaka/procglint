#!/bin/bash
# Format check + lint, same as CI. Pass --fix to apply SwiftFormat.
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftLint needs sourcekitd; on Command Line Tools it is not found without this.
if [[ "$(xcode-select -p)" == */CommandLineTools ]]; then export TOOLCHAIN_DIR=/Library/Developer/CommandLineTools; fi
if [[ "${1:-}" == "--fix" ]]; then
  mise exec -- swiftformat .
else
  mise exec -- swiftformat --lint .
fi
mise exec -- swiftlint lint --quiet --strict
