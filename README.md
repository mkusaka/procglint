# procglint

A lightweight process monitor for Apple Silicon Macs (macOS 15+). One per-user agent samples the OS; the AppKit app, the bundled stdio MCP server and the CLI share its data, so adding MCP clients does not multiply monitoring cost.

- Contract: [docs/SPEC.md](docs/SPEC.md)
- Plan: [docs/PLAN.md](docs/PLAN.md)

## Features

- Process CPU, cumulative CPU time, memory footprint and RSS, attributed disk I/O counters/rates, PID and owner; system CPU and defined VM memory statistics.
- Search, filter, sort and choose columns; inspect details, pin processes and read bounded history with explicit gaps for unobserved time.
- Optional CPU/memory menu-bar display. Default updates are 5 seconds for the window and 10 seconds for the menu bar; no periodic sampling without an active lease.
- Shared stdio MCP bridge: read-only, own processes, no paths by default; opt-in bounded observations, configuration and termination.
- Confirmed own-process TERM/KILL with short-lived, single-use tickets, identity revalidation and a bounded audit log. No automatic escalation.
- Monitor diagnostics for collection cost, coverage, failures, connected clients and history usage. No root helper or network listener.

See [MCP](docs/MCP.md), [Security](docs/SECURITY.md) and [Performance and metrics](docs/PERFORMANCE.md). Missing metrics are never zero; process CPU uses 100% per core and may exceed 100%.

## Requirements

Apple Silicon (arm64), macOS 15 or later, and a GUI login session for the per-user LaunchAgent.

## Install

The packaged 1.0 interface is a complete app with bundled agent, MCP bridge and CLI:

1. Download the app ZIP from [GitHub Releases](https://github.com/mkusaka/procglint/releases), unzip it and move **Procglint.app** to `/Applications` before registering the agent.
2. Open the app. In first-run setup / Settings, explicitly register its per-user agent (`io.github.mkusaka.procglint.agent`).
3. If registration requires approval, allow Procglint in **System Settings → General → Login Items & Extensions**, then check registration again. Use `procglint doctor` for registration state and recovery instructions.

The registered agent starts on demand; the GUI need not remain open for MCP use. With no clients it exits after a 60-second grace period. If unavailable, clients report an error instead of starting another sampler.

For a source-built app, the 1.0 bundle-build entry point is `scripts/build-app.sh`. `swift build` alone does not install/register an app or copy helpers into `/Applications`.

## Connect an MCP client

Start read-only:

```sh
claude mcp add procglint -- /Applications/Procglint.app/Contents/Helpers/procglint-mcp
```

Settings → **Copy MCP config** generates JSON using the installed helper path. See [docs/MCP.md](docs/MCP.md) for generic JSON, Codex configuration, permissions and all 10 tools. Flags only request access: macOS and app settings still cap it. Your MCP host may forward process results to an external model.

The bundled [procglint skill](skills/procglint/SKILL.md) guides resource investigations and human-confirmed termination.

## CLI

The packaged CLI is `/Applications/Procglint.app/Contents/Helpers/procglint`. Use that absolute path, or put the helper directory on your shell's `PATH`.

| Command | Purpose |
| --- | --- |
| `procglint status` | Inspect the shared agent's sampling state, overhead and diagnostics. |
| `procglint doctor` | Report agent registration/reachability and recovery steps, including Login Items approval. |
| `procglint export` | Export current values / retained history through the agent. |

```sh
/Applications/Procglint.app/Contents/Helpers/procglint status
/Applications/Procglint.app/Contents/Helpers/procglint doctor
/Applications/Procglint.app/Contents/Helpers/procglint export
```

These are the 1.0 CLI commands from the [contract](docs/SPEC.md); the CLI shares the agent and does not run its own periodic sampler. History cannot recover time when a process was not tracked.

## Architecture

```text
AppKit GUI + menu bar -------------------\
CLI (status / doctor / export) -----------+-- XPC --> per-user procglint-agent
MCP host -- stdio --> procglint-mcp ------/          |-- one OS sampler
                                                   |-- snapshot + history
                                                   |-- leases + permissions
                                                   `-- termination + audit
```

launchd starts the agent through `io.github.mkusaka.procglint.agent`. Clients share single-flight collection and scoped results; a connection alone does not request periodic sampling. See [docs/SPEC.md](docs/SPEC.md) for component boundaries and the wire contract.

## Uninstall

1. While the app is still installed, run `procglint doctor` and follow its agent-unregistration instructions. Merely denying Login Items approval is not the same as unregistering the service. For a development registration, use `scripts/dev-agent.sh stop`.
2. Remove procglint from your MCP host configuration, close its bridge connections and quit the app.
3. Remove the app, its application-support directory (including audit logs), and its actual defaults suite. This permanently deletes settings and audit history; keep any records you need first:

   ```sh
   rm -rf /Applications/Procglint.app "$HOME/Library/Application Support/Procglint"
   defaults delete io.github.mkusaka.procglint
   ```

   If the defaults domain does not exist, there are no saved preferences to remove. Monitoring history is in memory and disappears when the agent exits; any exports you saved elsewhere must be removed separately.

## Development

```sh
mise install          # swiftformat, swiftlint, lefthook
lefthook install
scripts/test.sh       # swift test
scripts/lint.sh       # format check + lint
```
