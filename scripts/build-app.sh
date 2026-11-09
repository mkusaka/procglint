#!/bin/bash
# Build an arm64 app with its XPC agent, MCP bridge, and CLI.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "Usage: $0 [--configuration release|debug] [--sign <identity>|-]" >&2
  exit 2
}

configuration=release
identity=-
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || usage
      case "$2" in release|debug) configuration="$2" ;; *) usage ;; esac
      shift 2
      ;;
    --sign)
      [[ $# -ge 2 && -n "$2" ]] || usage
      identity="$2"
      shift 2
      ;;
    -) identity=-; shift ;;
    *) usage ;;
  esac
done

marketing_version="${MARKETING_VERSION-1.0.0}"
build_version="${BUILD_VERSION-1}"
for version in "$marketing_version" "$build_version"; do
  if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "MARKETING_VERSION and BUILD_VERSION must have one to three numeric components." >&2
    exit 2
  fi
done

# Bundle tests run under swift test, which keeps the default build directory locked.
build=(swift build --scratch-path .build/app-bundle -c "$configuration" --arch arm64)
for product in procglint-gui procglint-agent procglint-mcp procglint; do
  "${build[@]}" --product "$product"
done
binary_dir="$("${build[@]}" --show-bin-path)"
app="$PWD/build/Procglint.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents" "$app/Contents/Resources"
install -m 755 "$binary_dir/procglint-gui" "$app/Contents/MacOS/procglint-gui"
for helper in procglint-agent procglint-mcp procglint; do
  install -m 755 "$binary_dir/$helper" "$app/Contents/Helpers/$helper"
done
cp Config/io.github.mkusaka.procglint.agent.plist "$app/Contents/Library/LaunchAgents/"
cp Config/Info.plist "$app/Contents/Info.plist"
cp Config/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$app/Contents/Info.plist"
commit="$(git rev-parse --short HEAD 2>/dev/null)" || commit=unknown
if [[ "$commit" != unknown && -n "$(git status --porcelain)" ]]; then commit="$commit-dirty"; fi
/usr/libexec/PlistBuddy -c "Set :ProcglintGitCommit $commit" "$app/Contents/Info.plist"

signing=(--force --options runtime --sign "$identity")
if [[ "$identity" != - ]]; then signing+=(--timestamp); fi
for helper in procglint-agent procglint-mcp procglint; do
  codesign "${signing[@]}" "$app/Contents/Helpers/$helper"
done
codesign "${signing[@]}" "$app"
codesign --verify --deep --strict "$app"
echo "MCP helper: $app/Contents/Helpers/procglint-mcp"
