#!/bin/bash
# Build, verify, and package an arm64 release; notarize only with Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "release: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 --version X.Y.Z --sign <Developer ID Application identity>|- [--notarize]" >&2
  exit 2
}

version=
identity=
notarize=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 && -n "$2" ]] || usage
      version="$2"
      shift 2
      ;;
    --sign)
      [[ $# -ge 2 && -n "$2" ]] || usage
      identity="$2"
      shift 2
      ;;
    --notarize) notarize=true; shift ;;
    *) usage ;;
  esac
done
[[ -n "$version" && -n "$identity" ]] || usage

# Two-digit minor/patch components keep the computed build number unambiguous.
if [[ ! "$version" =~ ^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
  fail "Version must be X.Y.Z: major 0–9999, minor/patch 0–99, no leading zeroes."
fi
IFS=. read -r major minor patch <<< "$version"
build_version=$((major * 10000 + minor * 100 + patch))
if [[ "$identity" != - && "$identity" != "Developer ID Application" && "$identity" != "Developer ID Application: "* ]]; then
  fail "Use a Developer ID Application identity, or '-' for ad-hoc signing."
fi
if [[ "$notarize" == true ]]; then
  [[ "$identity" != - ]] || fail "Notarization requires Developer ID signing, not ad-hoc signing."
  for variable in APP_STORE_CONNECT_KEY_PATH APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
    [[ -n "${!variable:-}" ]] || fail "Notarization requires $variable."
  done
  [[ -f "$APP_STORE_CONNECT_KEY_PATH" && -r "$APP_STORE_CONNECT_KEY_PATH" && -s "$APP_STORE_CONNECT_KEY_PATH" ]] ||
    fail "APP_STORE_CONNECT_KEY_PATH must point to a readable, nonempty .p8 key file."
fi

archive_name="Procglint-$version-arm64.zip"
archive="$PWD/build/$archive_name"
# A failed rebuild must not leave an older archive looking like its output.
rm -f "$archive" "$archive.sha256"
MARKETING_VERSION="$version" BUILD_VERSION="$build_version" \
  scripts/build-app.sh --configuration release --sign "$identity" || fail "App build or signing failed."
app="$PWD/build/Procglint.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] ||
  fail "Bundle marketing version does not match the requested version."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_version" ]] ||
  fail "Bundle build version does not match the computed build number."

mach_o_count=0
while IFS= read -r -d '' binary; do
  case "$(file -b "$binary")" in
    Mach-O*)
      [[ "$(lipo -archs "$binary")" == arm64 ]] || fail "Not arm64-only: $binary"
      codesign --verify --strict "$binary" || fail "Invalid signature: $binary"
      if [[ "$identity" != - ]]; then
        signature="$(codesign --display --verbose=4 "$binary" 2>&1)" || fail "Cannot inspect signature: $binary"
        [[ "$signature" == *"Authority=Developer ID Application"* ]] || fail "Missing Developer ID signature: $binary"
        grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$signature" || fail "Hardened runtime is missing: $binary"
      fi
      mach_o_count=$((mach_o_count + 1))
      ;;
  esac
done < <(find "$app" -type f -print0)
[[ "$mach_o_count" -gt 0 ]] || fail "No Mach-O binaries found in the app bundle."
codesign --verify --deep --strict "$app" || fail "Bundle signature verification failed."

staging="$(mktemp -d "$PWD/build/.release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
if [[ "$notarize" == true ]]; then
  ditto -c -k --keepParent "$app" "$staging/notarization.zip"
  xcrun notarytool submit "$staging/notarization.zip" \
    --key "$APP_STORE_CONNECT_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait --timeout 1h --output-format json > "$staging/notarization.json" ||
    fail "Notarization submission failed; no release archive was produced."
  # notarytool can exit successfully even when the submission is Invalid.
  status="$(/usr/bin/plutil -extract status raw -o - "$staging/notarization.json")" ||
    fail "Could not read the notarization result."
  [[ "$status" == Accepted ]] || fail "Notarization was not accepted; check the submission in notarytool history/log."
  xcrun stapler staple "$app" || fail "Could not staple the notarization ticket."
  xcrun stapler validate "$app" || fail "Stapled ticket validation failed."
  spctl --assess --type execute --verbose=4 "$app" || fail "Gatekeeper assessment failed."
else
  echo "release: Not notarized; Gatekeeper may block this build on other Macs." >&2
fi

codesign --verify --deep --strict "$app" || fail "Final bundle signature verification failed."
ditto -c -k --keepParent "$app" "$staging/$archive_name"
(cd "$staging" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
mv "$staging/$archive_name" "$staging/$archive_name.sha256" build/
echo "Release archive: $archive"
echo "SHA-256: $archive.sha256"
