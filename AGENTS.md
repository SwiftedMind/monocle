# AGENTS.md — Architecture & Contribution Guide

`monocle` is a read-only Swift code inspection tool built on top of **SourceKit-LSP**.  
Its primary purpose is to provide a command-line equivalent of “cmd-click” in an IDE: given a file, line, and column, it resolves the symbol there and returns information about its definition and documentation.

This document gives a high-level view of how the project is structured and how it is intended to evolve, so that contributors can extend it without breaking the overall design.

---

## General Instructions

Pay attention to these general instructions and closely follow them!

- Whenever you make changes to the code, build the project afterwards to ensure everything still compiles.
- Whenever you make changes to unit tests, run the test suite to verify the changes.
- Always prefer readability over conciseness/compactness.
- Never commit unless instructed to do so.

### **IMPORTANT**: Before you start

- Always scan the Internal and External Resources lists for anything that applies to the work you are doing (features, providers, database, AI tools, tests, docstrings, changelog, commits, etc.) and read those guidelines before making changes.
- When asked to commit changes to the repository, always read and understand the commit guidelines before doing anything!

### When you are done

- Always build the project to check for compilation errors.
- When you have added or modified Swift files, always run `swiftformat --config ".swiftformat" {files}`.

## Symbol Inspection (`monocle` cli)

- Treat the `monocle` cli as your **default tool** for Swift symbol info. 
  Whenever you need the definition file, signature, parameters, or doc comment for any Swift symbol (type, class, struct, enum, method, property, etc.), call `monocle` rather than guessing or doing project-wide searches.
- Resolve the symbol at a specific location: `monocle inspect --file <path> --line <line> --column <column> --json`
- Line and column values are **1-based**, not 0-based; the column must point inside the identifier
- Search workspace symbols by name when you only know the identifier: `monocle symbol --query "TypeOrMember" --limit 5 --enrich --json`.
  - `--limit` caps the number of results (default 5).
  - `--enrich` fetches signature, documentation, and the precise definition location for each match.
- Use `monocle` especially for symbols involved in errors/warnings or coming from external package dependencies.

## Internal Resources

Use these documents proactively whenever you work on the corresponding area; they define the constraints and patterns you must follow.

- agents/guidelines/commit.md - Guidelines for committing changes to the repository
- agents/swift/docc.md - Guidelines on writing docstrings in Swift

---

## Build Instructions

- Build from the repository root with `swift build`.
- Prefer `swift build --quiet` to reduce noise; only drop `--quiet` when debugging a failure.

---

## 1. Purpose and Scope

- Inspect Swift symbols at a given file/line/column.
- Resolve definitions across the workspace, including packages and dependencies.
- Surface signatures and documentation via SourceKit-LSP.
- Operate in a read-only manner: no edits, no refactorings, no code generation.

The tool focuses on **understanding** existing Swift code, not modifying it.

---

## 2. High-Level Architecture

The project is structured into clear layers to keep responsibilities separate while allowing the daemon/server to build on the same foundations.

### 2.1 Core Layer

The core layer encapsulates all interaction with SourceKit-LSP and the workspace:

- Manages the lifecycle of an LSP session (starting and shutting down `sourcekit-lsp`).
- Sends LSP requests (e.g. “go to definition”, “hover”) and parses responses.
- Resolves the workspace (SwiftPM or Xcode) from file paths or an explicit root.
- Provides a small, stable API for “inspect the symbol at this location”.

This layer is intentionally unaware of command-line argument parsing, JSON printing, or daemon concerns.

### 2.2 CLI Layer

The CLI layer provides the `monocle` executable and user-facing interface:

- Parses arguments and options.
- Resolves the workspace using the core’s workspace utilities.
- Calls into the core to perform inspections.
- Formats results either as human-readable text or JSON.

The CLI is a thin wrapper around the core logic. Any substantial behavior should live in the core layer rather than in CLI commands.

### 2.3 Daemon Layer

The long-lived daemon/server keeps one or more LSP sessions alive across requests, handles JSON requests over a local socket (e.g. Unix domain socket), and manages idle timeouts and cleanup when sessions are unused.

The CLI includes commands to start and stop the daemon, and symbol-related commands prefer talking to the daemon when available, with a fallback to the “one LSP session per process” behavior in the core. The daemon builds on the same core API as the CLI.

---

## 3. Project Structure

The repository is intended to be organized as a Swift package with separate targets for core logic and the CLI:

```text
monocle/
  Package.swift
  Sources/
    MonocleCore/
      LspSession.swift
      Workspace.swift
      WorkspaceLocator.swift
      Errors.swift
      Server.swift, protocol definitions for daemon mode
    MonocleCLI/
      main.swift
      Commands/
        InspectCommand.swift
        DefinitionCommand.swift
        HoverCommand.swift
        ServeCommand.swift
        StopCommand.swift
  Tests/
    MonocleCoreTests/
      WorkspaceLocatorTests.swift
      LspSessionTests.swift
      // Fixtures under Tests/Fixtures for sample workspaces
    MonocleCLITests/
      CLISmokeTests.swift
```

The names of individual files and types may change, but this layout illustrates the intended separation:

- Core logic in `MonocleCore`
- CLI glue in `MonocleCLI`
- Tests that exercise both layers with fixtures and simple end-to-end scenarios

---

## 4. Behavior and Workflow

### 4.1 One-Shot CLI Workflow

Each standalone CLI invocation can operate independently:

1. Determine the workspace from the supplied file and optional workspace root.
2. Start a new LSP session (launch `sourcekit-lsp`).
3. Open the file and request information for the symbol at the given line and column.
4. Print the result (text or JSON).
5. Shut down the LSP session and exit.

### 4.2 Daemon Workflow

When the daemon is running, the workflow routes through the server:

1. Start the server once (e.g. `monocle serve`).
2. The server maintains a pool or map of active LSP sessions keyed by workspace.
3. The CLI and other clients send small JSON requests to the server over a socket.
4. The server routes each request to the appropriate LSP session and returns the result.
5. Idle sessions and the daemon itself shut down automatically after a configured period of inactivity.

The core API remains the same; only the transport changes.

---

## 5. Design Principles

When extending or refactoring the project, the following principles should be preserved:

- **Layered responsibilities**  
  Keep LSP interaction, CLI presentation, and daemon routing separate. Avoid cross-dependencies between layers.

- **Read-only operations**  
  Do not introduce functionality that modifies source code or project configuration. `monocle` should remain safe to run on any workspace without risk of changes.

- **Small, focused commands**  
  Prefer simple subcommands that perform one task well (e.g. inspect, definition, hover, serve).

- **Clear error handling**  
  Failures such as “workspace not found”, “LSP not available”, or “symbol not resolved” should produce clear, actionable messages and non-zero exit codes. Core logic should surface errors in a structured way so both CLI and daemon can present them appropriately.

- **Testability**  
  Core logic should be testable against small fixture workspaces. Behavior changes should be accompanied by tests that assert the intended outcome.

---

## 6. Extension Guidelines

- New features should be evaluated in terms of which layer they belong to. LSP-related logic belongs in core, user interaction in the CLI, and connection management in the daemon.
- Changes to the core API should be made cautiously, as both CLI and daemon depend on it.
- When adding new commands or capabilities (e.g. references, document symbols), reuse the existing patterns:
  - Add an entry point in the core for the operation.
  - Expose it through CLI and, once implemented, through the daemon.
- Keep configuration surfaces small and explicit (flags, environment variables) and avoid hidden behavior.

This structure and set of principles should make it possible to evolve `monocle` incrementally while keeping it understandable and predictable for both human and automated contributors.
