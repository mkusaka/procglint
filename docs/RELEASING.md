# Releasing procglint

Releases contain `Procglint.app` with the GUI, per-user agent, MCP bridge, and CLI. They support Apple Silicon (arm64) on macOS 15 or later. There is no Intel build, automatic updater or appcast. Notarized tag releases update the Homebrew cask `mkusaka/tap/procglint`.

## GitHub configuration

Create the **release** environment in GitHub Settings → Environments. Restrict deployments to trusted release refs and configure required reviewers as appropriate. The release job also requires the triggering actor to be `mkusaka`. Both tag and manual runs must pass the reusable Test workflow first, including the bundle and ad-hoc release packaging checks on `macos-26`.

The default mode is Developer ID signing and notarization. Set these environment secrets (repository secrets also work):

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64-encoded `.p12` containing a **Developer ID Application** certificate and its private key. |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password protecting that `.p12`. |
| `APPLE_KEYCHAIN_PASSWORD` | Nonempty password for the runner's temporary signing keychain. |
| `APPLE_APP_STORE_CONNECT_API_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key authorized for notarization. |
| `APPLE_APP_STORE_CONNECT_KEY_ID` | That API key's key ID. |
| `APPLE_APP_STORE_CONNECT_ISSUER_ID` | That API key's issuer ID. |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with Contents read/write on `mkusaka/homebrew-tap`; required for tag releases. It sends the `update-cask` dispatch that bumps `Casks/procglint.rb`. |

Use `base64 < certificate.p12 | pbcopy` (or the `.p8` file) to prepare a secret without printing it to a terminal. Never commit signing assets or paste them into logs. No Apple Team ID, Apple ID password or Sparkle key is required. The temporary keychain, `.p12`, and `.p8` are removed in an `always()` cleanup step, including after a failed import.

The optional `RELEASE_SIGNING` repository/environment variable selects the signing mode:

- Unset, or any value except `adhoc`: Developer ID signing, hardened runtime, notarization, stapling, and Gatekeeper assessment. Missing credentials cause failure; there is no silent fallback.
- Exactly `adhoc`: ad-hoc signing with no notarization, no Apple secrets and no Homebrew update (Gatekeeper would block an ad-hoc cask install).

The workflow uses only `contents: write` for release publication; checkout credentials are not persisted. `GITHUB_TOKEN` is provided by GitHub, not a separate secret to create.

## Cut a release

1. Merge the intended changes and confirm the Test workflow is green.
2. Choose a version `X.Y.Z`: major **0–9999**, minor and patch **0–99**, with no leading zeroes, suffixes, or prerelease identifiers. The script computes `CFBundleVersion = major × 10000 + minor × 100 + patch` (for example, `1.2.3` → `10203`). The minor/patch limits prevent build-number collisions; the major limit keeps arithmetic bounded. Release versions should increase.
3. Optionally validate the exact commit with a manual **Release** workflow run, supplying the version without `v`. Manual runs build and sign normally but upload only a workflow artifact (retained for 14 days); they do not create a GitHub release.
4. Tag and push the intended commit as `mkusaka`:

   ```sh
   git tag -a v1.0.0 -m 'procglint 1.0.0'
   git push origin v1.0.0
   ```

5. Approve the `release` deployment if required and inspect the workflow result. The workflow publishes:

   ```text
   Procglint-1.0.0-arm64.zip
   Procglint-1.0.0-arm64.zip.sha256
   ```

A tag push must have a valid version after `v`; malformed `v*` tags fail validation. Re-running a tag workflow replaces those two assets with `gh release upload --clobber`. Existing release notes are preserved; ad-hoc runs prepend a Gatekeeper warning if it is missing. If switching an existing release back to Developer ID signing, remove any obsolete ad-hoc warning from its notes after verifying the replacement assets.

Download both files into the same directory and verify with:

```sh
shasum -a 256 -c Procglint-1.0.0-arm64.zip.sha256
ditto -x -k Procglint-1.0.0-arm64.zip .
codesign --verify --deep --strict Procglint.app
# For a notarized release:
xcrun stapler validate Procglint.app
spctl --assess --type execute --verbose=4 Procglint.app
```

The checksum detects corruption; it does not authenticate an ad-hoc build's publisher.

## Ad-hoc releases

Set `RELEASE_SIGNING=adhoc`, then run the manual workflow or push a release tag as above. Remove/reset the variable before the next Developer ID release. Ad-hoc tag releases include a warning in their GitHub release notes.

Ad-hoc builds are **not notarized**. Gatekeeper may block a downloaded app's first launch. Only after verifying the download and trusting its source, use System Settings → Privacy & Security → **Open Anyway**. Do not disable Gatekeeper globally. Manual ad-hoc artifacts and local builds have the same limitation.

## Local app builds

`scripts/build-app.sh [--configuration release|debug] [--sign <identity>|-]` builds the complete bundle at `build/Procglint.app`. Defaults are `release` and ad-hoc signing (`-`); it does not register the LaunchAgent, make a release ZIP or notarize. It replaces any existing app at that path. `MARKETING_VERSION` (default `1.0`) and `BUILD_VERSION` (default `1`) override the bundle versions; each must contain one to three numeric components. Builds use the separate `.build/app-bundle` scratch directory, so the opt-in bundle test can build while `swift test` holds the ordinary build directory lock.

For validation commands, including XcodeGen/XCUITest and the opt-in `PROCGLINT_BUNDLE_TEST=1` bundle test, see [README Testing](../README.md#testing). The UI-test project embeds the MCP helper only; use `build-app.sh` for the complete agent/CLI distribution bundle.

## Local release builds

Run on an Apple Silicon Mac with the Swift toolchain and Xcode command-line tools available. The script always builds the release configuration, replacing `build/Procglint.app` and that version's previous ZIP/checksum. It verifies bundle versions, every Mach-O's arm64-only architecture and signature, and (for Developer ID) hardened runtime before packaging. The ZIP has `Procglint.app` at its root (`ditto --keepParent`).

```sh
# No signing credentials needed:
scripts/release.sh --version 1.0.0 --sign -

# Certificate/private key must already be available in an unlocked keychain:
scripts/release.sh --version 1.0.0 \
  --sign 'Developer ID Application: Your Name (TEAMID)'

# Full signed + notarized build:
export APP_STORE_CONNECT_KEY_PATH="$HOME/private/AuthKey.p8"
export APP_STORE_CONNECT_KEY_ID='your-key-id'
export APP_STORE_CONNECT_ISSUER_ID='your-issuer-id'
scripts/release.sh --version 1.0.0 \
  --sign 'Developer ID Application: Your Name (TEAMID)' --notarize
```

`--notarize` requires all three environment variables and rejects ad-hoc signing. It submits a temporary ZIP with `notarytool --key/--key-id/--issuer`, waits up to one hour, requires an `Accepted` result, staples and validates the ticket, and assesses the app with `spctl` before creating the final ZIP and SHA-256 file. A Developer ID build without `--notarize` is still unnotarized. Local API keys belong to the caller and are not deleted; only temporary packaging/submission files are cleaned up.
