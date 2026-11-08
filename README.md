# procglint

A lightweight process monitor for Apple Silicon Macs (macOS 15+). One per-user agent samples the OS; the AppKit app, the bundled stdio MCP server and the CLI share its data, so adding MCP clients does not multiply monitoring cost.

- Contract: [docs/SPEC.md](docs/SPEC.md)
- Plan: [docs/PLAN.md](docs/PLAN.md)

## Development

```sh
mise install          # swiftformat, swiftlint, lefthook
lefthook install
scripts/test.sh       # swift test
scripts/lint.sh       # format check + lint
```
