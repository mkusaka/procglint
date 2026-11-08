# AGENTS.md

procglint: macOS (arm64, macOS 15+) process monitor. One per-user agent samples the OS; the AppKit GUI, the stdio MCP bridge and the CLI read from it over XPC.

- Contract (types, units, JSON, permissions): `docs/SPEC.md`. Read it before coding. Code must match it; if the contract is wrong, say so in your final report instead of silently diverging.
- Plan / scope: `docs/PLAN.md`.

## Commands

- Test: `scripts/test.sh` (wraps `swift test`; adds the Swift Testing plugin path on Command Line Tools machines). Filter: `scripts/test.sh --filter CoreTests`.
- Format + lint: `scripts/lint.sh` (check) / `scripts/lint.sh --fix` (apply SwiftFormat). Must be clean before you finish.
- Build: `swift build`.

## Rules

- Swift 6 language mode, strict concurrency. No `@unchecked Sendable` / `nonisolated(unsafe)` unless the reason is in a one-line comment.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). XCTest is not available on the dev machine.
- Tests must not depend on timing luck. Inject `MonotonicClock` / `ProcessSource` fakes; real-OS tests only assert invariants that always hold (e.g. own pid is listed).
- Only edit files inside the directories your task owns. Do **not** edit `Package.swift`, `docs/SPEC.md`, CI, or other units' directories. If you need a change there, describe it in your final report.
- Do not commit. Leave changes in the working tree; the reviewer commits.
- No new third-party dependencies.
- JSON: `ProcglintJSON` encoder/decoder, snake_case, 64-bit ids/times as strings.
- CI builds with the newest Xcode on macos-26 and macos-15 runners (macOS 15 is the minimum runtime). Avoid APIs newer than macOS 15 without `if #available`, and split long arithmetic/closure expressions (type checker timeouts).
- Test fixtures: avoid UUID-shaped or long hex/base64 literals (the commit secret scanner flags them). Use short readable fakes like `boot-a`, `tok-1`.
- Executable products differ only by more than case (`procglint` CLI vs `procglint-gui` app binary): the filesystem is case-insensitive.
- Never write to stdout in `procglint-mcp` except MCP protocol messages; logs go to stderr.

## Minimal implementation

- Build what the task and SPEC require, nothing speculative: no single-implementation protocols (except the injected OS/clock/settings seams and `MonitorService` named in SPEC), no config for constants, no "for later" scaffolding.
- Reuse what is already in the repo before writing new helpers. Prefer stdlib / platform APIs.
- Keep input validation, error handling and security checks; they are not optional.
- Non-trivial logic (branches, parsing, permission/termination paths, scheduling) gets a focused test. Trivial code does not need one.
- Comments explain *why*, not *what*. No commented-out code.

## Final report

End with: files changed, what is tested, what you could not verify (e.g. needs a signed bundle / launchd), and any contract changes you need.
