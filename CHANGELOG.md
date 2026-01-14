## [1.4.0]

### Added
- **Force-stop for hung daemons**: `monocle stop` now force-stops unresponsive daemons (and `--force` is available for explicit use).
- **Daemon PID visibility**: `monocle status` now shows the daemon PID to aid debugging and force-stop workflows.
- **Dependency type discovery for symbol search**: `monocle symbol` can now surface type declarations from Swift package dependencies when `workspace/symbol` does not return them (checked-out packages + targeted fallback).

### Enhanced
- **Daemon auto-start resilience**: Auto-start is more robust against stale sockets and unresponsive daemons, and avoids spawning duplicate daemons during concurrent invocations.
- **More reliable symbol warm-up**: `monocle symbol` retries during initial SourceKit-LSP warm-up so first-run “empty results” are less likely.
- **Faster repeated dependency searches**: Dependency symbol lookups reuse daemon sessions, improving repeated query performance.

### Fixed
- **SourceKit-LSP crash recovery**: Monocle now recovers more reliably from crashed/invalid SourceKit-LSP sessions by restarting and reopening documents as needed.
- **Graceful daemon shutdown reliability**: Daemon shutdown no longer blocks on long-running SourceKit-LSP shutdown sequences, preventing `monocle stop` timeouts.
- **Xcode `build_root` checkout discovery**: `buildServer.json` setups that point `build_root` at `DerivedData/.../Build` now resolve `SourcePackages/checkouts` correctly.

## [1.3.0]

### Added
- **Checked-out package listing**: Added `monocle packages` to list all SwiftPM package checkouts for the current workspace, including each checkout folder path and (when present) the README path. For Xcode workspaces/projects this uses `buildServer.json`’s `build_root` to locate DerivedData `SourcePackages/checkouts`; for pure SwiftPM packages it scans `./.build/checkouts`.

## [1.2.1]

### Fixed
- **Enriched symbol search timeouts**: `monocle symbol --enrich` no longer times out due to daemon socket request time limits; daemon requests now use operation-appropriate timeouts and the socket read timeout is enforced reliably.

## [1.2.0]

### Added
- **Workspace option alias**: Added `--project` as an alias for `--workspace` to make workspace selection more discoverable across commands.

### Enhanced
- **Actionable build server setup guidance**: Missing `buildServer.json` errors for Xcode workspaces/projects now include concrete next steps (including `xcode-build-server` examples).

### Fixed
- **Explicit Xcode bundle handling**: Passing an explicit `.xcodeproj` or `.xcworkspace` path no longer gets misclassified by workspace auto-detection.
- **Manifest path support**: Passing a `Package.swift` path now correctly resolves the workspace root for SwiftPM projects.

## [1.1.0]
### Added
- **Workspace symbol search command**: Added `monocle symbol` to query workspace symbols with a configurable limit and optional enriched output via the CLI and daemon.

### Enhanced
### Fixed
## [Unreleased]

### Added
- **Symbol search ranking + source labels**: `monocle symbol` now prioritizes exact matches, labels results as project/package, and reduces noise from mangled/test-only symbols.
- **Symbol search filters and context**: New flags `--exact`, `--scope`, `--prefer`, and `--context-lines` add exact matching, source filtering, ranking preference, and multi-line snippets.
