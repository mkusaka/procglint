#!/bin/bash
# Development only: do not run alongside the SMAppService agent (they share a Mach service).
set -euo pipefail
cd "$(dirname "$0")/.."
label=io.github.mkusaka.procglint.agent.dev
domain="gui/$(id -u)"
plist="$HOME/Library/LaunchAgents/$label.plist"

case "${1:-}" in
  start)
    if launchctl print "$domain/io.github.mkusaka.procglint.agent" >/dev/null 2>&1; then
      echo "Unregister the bundled agent before starting the dev agent." >&2
      exit 1
    fi
    if [[ $# == 1 ]]; then
      swift build --product procglint-agent
      binary="$(swift build --show-bin-path)/procglint-agent"
    elif [[ $# == 3 && "$2" == --binary && "$3" == /* && -f "$3" && -x "$3" ]]; then
      binary="$3"
    else
      echo "Usage: $0 start [--binary /absolute/path/to/procglint-agent]" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$plist")"
    temporary=$(mktemp "${plist}.XXXXXX")
    trap 'rm -f "$temporary"' EXIT
    plutil -create xml1 "$temporary"
    # PlistBuddy handles XML escaping in checkout paths (spaces and ampersands included).
    /usr/libexec/PlistBuddy -c "Add :Label string $label" "$temporary"
    /usr/libexec/PlistBuddy -c "Add :Program string $binary" "$temporary"
    /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "$temporary"
    /usr/libexec/PlistBuddy -c 'Add :MachServices:io.github.mkusaka.procglint.agent bool true' "$temporary"
    # Match the bundle: allow XPC-requested work to boost, without permanent Interactive priority.
    /usr/libexec/PlistBuddy -c 'Add :ProcessType string Adaptive' "$temporary"
    /usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType string Aqua' "$temporary"
    plutil -lint "$temporary"
    chmod 600 "$temporary"
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label"
    fi
    mv "$temporary" "$plist"
    launchctl bootstrap "$domain" "$plist"
    echo "Registered $label (launches on the next XPC request)."
    ;;
  stop)
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label"
    fi
    rm -f "$plist"
    ;;
  status)
    launchctl print "$domain/$label"
    ;;
  *)
    echo "Usage: $0 {start [--binary /absolute/path/to/procglint-agent]|stop|status}" >&2
    exit 2
    ;;
esac
