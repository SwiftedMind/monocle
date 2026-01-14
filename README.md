<img width="100" height="100" alt="monocle Logo" src="https://github.com/user-attachments/assets/a4c576cc-b70b-4708-94d9-abb82f4c863e" />

# monocle

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSwiftedMind%2Fmonocle%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/SwiftedMind/monocle)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSwiftedMind%2Fmonocle%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/SwiftedMind/monocle)

A read-only CLI for Swift symbol lookup via SourceKit-LSP, designed specifically for coding agents. Point it at a file, line, and column, and monocle resolves the symbol and returns its definition location, signature, and documentation—perfect for agents that need to understand unfamiliar APIs, including types from external Swift packages, without opening Xcode.

## Table of Contents
- [Why monocle](#why-monocle)
- [Installation](#installation)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Agent snippet for AGENTS.md](#agent-snippet-for-agentsmd)
- [What agents get](#what-agents-get)
- [Commands](#commands)
- [Daemon mode](#daemon-mode)
- [Output details](#output-details)
- [Troubleshooting](#troubleshooting)
- [🙏 Acknowledgments](#-acknowledgments)

## Why monocle

- **Built for agents:** Stable, pretty-printed JSON output (`--json`) mirrors the internal `SymbolInfo` model, making it easy for tools and agents to parse.
- **Everything in one call:** `monocle inspect` returns both definition and docs together—ideal for grabbing signatures and docstrings from third-party packages or unfamiliar frameworks.
- **Fast lookups across dependencies:** Resolve symbols from your dependencies (SwiftPM or Xcode) without firing up an IDE. Great when agents need the actual implementation file and docstring.
- **Keep it warm:** Optional `monocle serve` keeps SourceKit-LSP running to eliminate cold starts during repeated agent calls.
- **Workspace aware:** Automatically finds your `Package.swift`, `.xcodeproj`, or `.xcworkspace` when you don't specify `--workspace` (or `--project`).
- **Works everywhere:** Supports both Swift packages and Xcode projects/workspaces.

## Installation

### Homebrew (recommended)
```bash
brew install SwiftedMind/cli/monocle
```

### From source
```bash
git clone https://github.com/SwiftedMind/monocle.git
cd monocle
swift build --configuration release
# optional: make it globally available
cp .build/release/monocle /usr/local/bin/
```

## Requirements

- macOS 13 or newer
- Xcode or a Swift toolchain that provides `sourcekit-lsp` on your PATH (monocle uses `xcrun sourcekit-lsp`)

### Xcode projects/workspaces: `buildServer.json` is required

For Xcode projects/workspaces, monocle relies on SourceKit-LSP’s *build server* integration to get the full compile settings (SDK, search paths, SwiftPM checkouts, etc.). **Without a `buildServer.json` in your workspace root, monocle will not be able to resolve symbols from dependencies/SDK frameworks reliably.**

#### 1) Install `xcode-build-server`

```bash
brew install xcode-build-server
```

> [!TIP]
> Learn more about `xcode-build-server`: https://github.com/SolaWing/xcode-build-server

#### 2) Build the project in Xcode at least once

Before generating `buildServer.json`, open the project/workspace in Xcode and build the scheme you intend to use (this also resolves SwiftPM packages).

You may need to rebuild after:
- Changing Xcode/SDK/toolchains
- Changing package dependencies
- Changing build settings that affect compile arguments

If you regenerate `buildServer.json`, restart monocle’s daemon so it picks up the new configuration:

```bash
# Daemon will automatically restart with your next command
monocle stop
```

#### 3) Generate `buildServer.json` in the workspace root

```bash
cd /path/to/your/workspace/root

# If you have a .xcworkspace:
xcode-build-server config -workspace MyApp.xcworkspace -scheme MyApp

# If you have a .xcodeproj:
xcode-build-server config -project MyApp.xcodeproj -scheme MyApp
```

Example `buildServer.json`:

```json
{
  "name": "xcode build server",
  "version": "0.2",
  "bspVersion": "2.0",
  "languages": ["c", "cpp", "objective-c", "objective-cpp", "swift"],
  "argv": ["/opt/homebrew/bin/xcode-build-server"],
  "workspace": "/path/to/MyApp.xcodeproj/project.xcworkspace",
  "build_root": "/path/to/DerivedData/MyApp-abcdefg",
  "scheme": "MyApp",
  "kind": "xcode"
}
```

## Quick start

Inspect the symbol under the cursor (human-readable output):
```bash
monocle inspect --file Sources/App/FooView.swift --line 42 --column 17
```

Same call with JSON output for agents and tools:
```bash
monocle inspect --file Sources/App/FooView.swift --line 42 --column 17 --json
```

If you prefer shorter commands, `inspect` is the default subcommand:
```bash
monocle --file Sources/App/FooView.swift --line 42 --column 17
```

## Agent snippet for AGENTS.md

Paste this block into your AGENTS guide so coding agents know how to use monocle:

```markdown
## Symbol Inspection (`monocle` cli)
 
- Treat the `monocle` cli as your **default tool** for Swift symbol info. 
  Whenever you need the definition file, signature, parameters, or doc comment for any Swift symbol (type, class, struct, enum, method, property, etc.), call `monocle` rather than guessing or doing project-wide searches.
- List checked-out SwiftPM dependencies (so you can open and read external packages): `monocle packages --json`
- Resolve the symbol at a specific location: `monocle inspect --file <path> --line <line> --column <column> --json`
- Line and column values are **1-based**, not 0-based; the column must point inside the identifier
- Search workspace symbols by name when you only know the identifier: `monocle symbol --query "TypeOrMember" --limit 5 --json`.
  - `--limit` caps the number of results (default 5).
  - `--enrich` fetches signature, documentation, and the precise definition location for each match.
  - `--exact` returns only exact symbol name matches.
  - `--scope project|package|all` limits results by source.
  - `--prefer project|package|none` biases ranking.
  - `--context-lines N` includes N lines of context around the definition (default 2).
- Use `monocle` especially for symbols involved in errors/warnings or coming from external package dependencies.

```

### What agents get

- Symbol name, kind, and module
- Definition URI with line/column range, plus an extracted snippet
- Signature and rendered doc comment (when available)
- Stable JSON shape (`SymbolInfo`) that's easy to ingest for retrieval-augmented workflows or code-review bots

Example JSON output:
```json
{
  "symbol": "FancyService.loadData(_:)",
  "definition": {
    "uri": "file:///.../Sources/FancyService.swift",
    "startLine": 10,
    "endLine": 24,
    "snippet": "public func loadData(_ id: ID) async throws -> Response { ... }"
  },
  "signature": "public func loadData(_ id: ID) async throws -> Response",
  "documentation": "/// Loads data from the backend."
}
```

## Commands

- `inspect` — get definition and hover information together
- `definition` — get just the definition location and snippet
- `hover` — get just the signature and documentation
- `symbol` — search workspace symbols by name (uses `workspace/symbol`)
- `packages` — list checked-out SwiftPM dependencies (checkout paths + README paths)
- `serve` — start the persistent daemon
- `status` — show daemon socket, idle timeout, and active LSP sessions
- `stop` — stop the daemon
- `--version` — print monocle and SourceKit-LSP versions

Common options for symbol commands:
- `--workspace /path/to/root` (optional) – override automatic workspace detection (alias: `--project`)
- `--file /path/to/File.swift` – source file containing the symbol
- `--line <int>` and `--column <int>` – one-based position of the symbol
- `--json` – output pretty-printed JSON instead of text

`symbol` options:
- `--query <string>` – search term (required)
- `--limit <int>` – cap results (default: 5)
- `--enrich` – fetch signature, documentation, and precise location for each result
- `--exact` – only return exact symbol name matches
- `--scope project|package|all` – filter results by workspace vs package sources
- `--prefer project|package|none` – bias ranking toward a source type
- `--context-lines <int>` – include context lines around each definition (default: 2)

## Daemon mode

Speed up repeated lookups by keeping SourceKit-LSP alive:

```bash
monocle serve --idle-timeout 600
```

- You do not need to start the daemon manually—running a symbol command such as `monocle inspect` will start it automatically on first use
- Check status: `monocle status` or `monocle status --json`
- Stop the daemon: `monocle stop`

## Output details

Human-readable output prints the symbol name, kind, module, signature, definition path with range, and an optional snippet and documentation. For `monocle symbol`, results are ranked (exact matches first), labeled by source (`project` vs `package`), and include contextual snippets when `--context-lines` is set (default 2). JSON output mirrors the `SymbolInfo` structure used internally, making it convenient for tools and CI pipelines.

## Troubleshooting

- Make sure `sourcekit-lsp` works by running `xcrun sourcekit-lsp --help`. If it fails, install Xcode or the Swift toolchain.
- For SwiftPM workspaces, monocle creates a scratch directory at `.sourcekit-lsp-scratch` under the workspace root. You can safely remove it if you need a clean slate.
- If monocle can't find your workspace, use `--workspace` (or `--project`) to point directly at your package or Xcode project.

## 🙏 Acknowledgments

- Built with the amazing Swift ecosystem and community

Made with ❤️ for the Swift community
