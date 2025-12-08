# Monocle – Plan for MVP and Daemon Extension

This document outlines the architecture and implementation plan for **monocle**, a CLI tool that uses **SourceKit-LSP** to inspect Swift symbols (definitions, docs, etc.), designed to be friendly for both humans and AI agents.

---

## 1. High-Level Architecture

Monocle is split into three core layers to keep the LSP logic reusable and make it easy to introduce a daemon later without rewrites:

1. **MonocleCore** (library target)
   - Launches and manages `sourcekit-lsp`.
   - Speaks LSP via `LanguageClient` / `LanguageServerProtocol`.
   - Exposes a simple Swift API, e.g.:
     - `inspectSymbol(file:line:column:workspace:) -> SymbolInfo`
     - `definition(...)`
     - `hover(...)`
   - Contains:
     - `LspSession`
     - `SymbolInfo` model
     - `Workspace` / `WorkspaceLocator`
     - Error types

2. **MonocleCLI** (executable: `monocle`)
   - Handles argument parsing and output formatting (human vs JSON).
   - **MVP:** Uses `MonocleCore` directly; each invocation creates an `LspSession`, does a lookup, and exits.
   - **Later:** Can optionally talk to a persistent daemon instead of creating an `LspSession` itself.

3. **MonocleDaemon** (future; subcommand `monocle serve`)
   - A persistent process that:
     - Keeps one or more `LspSession`s alive across requests.
     - Serves JSON requests over a local socket (Unix domain socket or TCP localhost).
     - Implements idle timeout to exit automatically when unused.
   - Clients (CLI, agents, MCP tools) send JSON requests and receive JSON responses.

Because **all LSP-related logic lives in `MonocleCore`**, adding the daemon is mostly additive — the daemon just orchestrates `LspSession`s instead of the CLI doing everything itself.

---

## 2. CLI API and Usage Design

### 2.1 Command Overview

Top-level executable: `monocle`

Subcommands:

- `inspect` – Combined view: definition + docs (primary for AI).
- `definition` / `def` – Symbol location and source snippet.
- `hover` – Signature and documentation only.
- `version` – Tool and SourceKit-LSP version.
- (Future) `serve`, `stop`, maybe `status`.

### 2.2 Global Options

- `--workspace PATH`
  - Optional workspace root. If omitted, auto-detect by walking up from `--file`:
    - Prefer `Package.swift` (SwiftPM).
    - Fallback to `.xcodeproj` / `.xcworkspace`.
- `--json`
  - Output JSON for machine/agent consumption instead of human-readable text.
- `--toolchain PATH` or `--xcode`
  - Optional override to control which toolchain provides `sourcekit-lsp`.

### 2.3 Symbol Location Arguments

Shared by `inspect`, `definition`, and `hover`:

- `--file PATH` (required)
- `--line INT` (required, 1-based)
- `--column INT` / `--col INT` (required, 1-based)

Potential future extension: `--offset` for byte/character offset-based lookup.

### 2.4 Example Usage

**Inspect symbol – JSON (for AI agents):**

```bash
monocle inspect   --workspace /Users/dennis/Dev/MyApp   --file Sources/App/FooView.swift   --line 42   --col 17   --json
```

Example JSON output:

```json
{
  "symbol": "FancyService.loadData(_:)", 
  "kind": "method",
  "module": "NetworkingKit",
  "definition": {
    "uri": "file:///Users/dennis/Dev/NetworkingKit/Sources/FancyService.swift",
    "startLine": 10,
    "startCharacter": 5,
    "endLine": 24,
    "endCharacter": 1,
    "snippet": "public func loadData(_ id: ID) async throws -> Response { ... }"
  },
  "signature": "public func loadData(_ id: ID) async throws -> Response",
  "documentation": "/// Loads data from the backend.\n/// - Parameter id: ..."
}
```

**Inspect symbol – human-readable:**

```bash
monocle inspect --file FooView.swift --line 42 --col 17
```

Output (conceptually):

```text
Symbol:   FancyService.loadData(_:)
Kind:     method
Module:   NetworkingKit

Signature:
    public func loadData(_ id: ID) async throws -> Response

Definition: /.../NetworkingKit/Sources/FancyService.swift:10-24

Snippet:
    public func loadData(_ id: ID) async throws -> Response {
        ...
    }

Doc:
    Loads data from the backend.
    - Parameter id: The identifier.
```

**Hover only (docs/signature):**

```bash
monocle hover --file FooView.swift --line 42 --col 17 --json
```

---

## 3. MVP Implementation (No Daemon)

### 3.1 Package Layout

SwiftPM structure:

```text
monocle/
  Package.swift
  Sources/
    MonocleCore/
      LspSession.swift
      SourceKitService.swift
      SymbolInfo.swift
      Workspace.swift
      WorkspaceLocator.swift
      MonocleError.swift
    MonocleCLI/
      main.swift
      Commands/
        InspectCommand.swift
        DefinitionCommand.swift
        HoverCommand.swift
        VersionCommand.swift
```

**Targets:**

- `MonocleCore` (library)
- `MonocleCLI` (executable, depends on `MonocleCore`)

**Dependencies in Package.swift:**

- `ArgumentParser` – CLI argument parsing.
- `LanguageServerProtocol`, `LanguageClient` (ChimeHQ) – LSP client plumbing.

### 3.2 Core Models and Errors (`MonocleCore`)

**`SymbolInfo`**

```swift
public struct SymbolInfo: Codable {
    public struct Location: Codable {
        public var uri: URL
        public var startLine: Int
        public var startCharacter: Int
        public var endLine: Int
        public var endCharacter: Int
        public var snippet: String?
    }

    public var symbol: String?
    public var kind: String?
    public var module: String?
    public var definition: Location?
    public var signature: String?
    public var documentation: String?
}
```

**`MonocleError`**

```swift
public enum MonocleError: Error {
    case workspaceNotFound
    case lspLaunchFailed(String)
    case lspInitializationFailed(String)
    case symbolNotFound
    case ioError(String)
}
```

**`Workspace` and `WorkspaceLocator`**

- `Workspace`:
  - Contains:
    - `rootPath: String`
    - `kind: .swiftPM | .xcodeproj | .xcworkspace`
- `WorkspaceLocator`:
  - Given:
    - `explicitWorkspacePath: String?`
    - `filePath: String`
  - Walks up parent directories to find:
    - `Package.swift`
    - Or `.xcodeproj` / `.xcworkspace`
  - Returns a `Workspace` or throws `.workspaceNotFound`.

### 3.3 LSP Session (`LspSession`)

**Responsibilities:**

- Spawn `xcrun sourcekit-lsp`.
- Connect stdin/stdout to `LanguageClient`.
- Perform standard LSP handshake:
  - `initialize`
  - `initialized`
- Provide async methods that wrap LSP requests:

```swift
public final class LspSession {
    public init(workspace: Workspace, toolchain: ToolchainConfig?) throws

    public func inspectSymbol(
        file: String,
        line: Int,
        column: Int
    ) async throws -> SymbolInfo

    public func definition(
        file: String,
        line: Int,
        column: Int
    ) async throws -> SymbolInfo

    public func hover(
        file: String,
        line: Int,
        column: Int
    ) async throws -> SymbolInfo
}
```

**Inner flow of `inspectSymbol`:**

1. Convert `file` to `file://` URI.
2. Read file contents from disk.
3. Send `textDocument/didOpen` with the file’s contents.
4. Create `TextDocumentPositionParams` from `(fileURI, Position(line: line-1, character: column-1))`.
5. Call `textDocument/definition`.
6. If a definition location is returned:
   - Resolve to local file path.
   - Read file contents.
   - Extract the range specified by LSP.
7. Call `textDocument/hover` for docs/signature.
8. Combine definition + hover data into `SymbolInfo` (including snippet).
9. Return `SymbolInfo` to caller.

**MVP lifetime:**

- Each CLI run:
  - Creates an `LspSession`, which starts `sourcekit-lsp`.
  - Runs `inspectSymbol` / `definition` / `hover` once.
  - On deinit, sends `shutdown` / `exit` to the LSP server and terminates the process.

### 3.4 CLI (`MonocleCLI`)

Use `ArgumentParser` to define the main entry point and subcommands.

**Main entry:**

```swift
@main
struct Monocle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monocle",
        abstract: "Inspect Swift symbols using SourceKit-LSP.",
        subcommands: [Inspect.self, Definition.self, Hover.self, Version.self],
        defaultSubcommand: Inspect.self
    )
}
```

**Inspect command (conceptual):**

```swift
struct Inspect: ParsableCommand {
    @Option(name: [.customShort("w"), .long], help: "Workspace root (Package.swift or .xcodeproj).")
    var workspace: String?

    @Option(name: .long, help: "Swift source file path.")
    var file: String

    @Option(name: .long, help: "1-based line number.")
    var line: Int

    @Option(name: [.customShort("c"), .long], help: "1-based column number.")
    var column: Int

    @Flag(name: .long, help: "Output JSON.")
    var json: Bool = false

    func run() throws {
        let workspacePath = try WorkspaceLocator.locate(explicit: workspace, file: file)
        let session = try LspSession(workspace: workspacePath, toolchain: nil)

        let info = try await session.inspectSymbol(file: file, line: line, column: column)

        if json {
            let data = try JSONEncoder().encode(info)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("
".data(using: .utf8)!)
        } else {
            HumanReadablePrinter.print(info)
        }
    }
}
```

`Definition` and `Hover` commands follow the same pattern but call their respective methods on `LspSession` and maybe return slimmer `SymbolInfo` variants.

---

## 4. Daemon Extension Plan

Once the MVP behaves well but cold-start cost is annoying, introduce a persistent daemon mode.

### 4.1 Goals

- Keep `MonocleCore` and `LspSession` unchanged.
- Add:
  - A long-lived server process (`monocle serve`).
  - A simple JSON request/response protocol over a local socket.
  - Client-side logic in the CLI to:
    - Attempt daemon usage first.
    - Fall back to the MVP direct LSP approach if no daemon is running.

### 4.2 Protocol Design

Use JSON per request/response, line-delimited or length-prefixed.

**Request:**

```json
{
  "id": "some-uuid",
  "method": "inspect",
  "params": {
    "workspace": "/Users/dennis/Dev/MyApp",
    "file": "Sources/App/FooView.swift",
    "line": 42,
    "column": 17
  }
}
```

**Response (success):**

```json
{
  "id": "some-uuid",
  "result": { /* SymbolInfo JSON */ }
}
```

**Response (error):**

```json
{
  "id": "some-uuid",
  "error": {
    "code": "symbol_not_found",
    "message": "No definition found at this location"
  }
}
```

**Transport:**

- Unix domain socket, e.g.:
  - macOS: `~/Library/Caches/monocle/socket`
  - Linux: `~/.cache/monocle/socket`

### 4.3 MonocleServer and Session Management

Add a server component (could be in a new target `MonocleServer` or part of `MonocleCore`):

```swift
final class MonocleServer {
    var sessions: [Workspace: LspSession] = [:]
    var lastUsed: [Workspace: Date] = [:]
    let idleTimeout: TimeInterval

    func handle(request: Request) async -> Response {
        // decode request, resolve session, call inspect/definition/hover,
        // update lastUsed[workspace], encode response
    }

    func reapIdleSessions() {
        // periodically called: shutdown sessions not used for idleTimeout
    }
}
```

**Session lifecycle:**

- On each request for a workspace:
  - If session exists → reuse it.
  - If not → create a new `LspSession` and store it.
- Update `lastUsed[workspace]` on each successful request.
- Use a timer / loop to periodically:
  - Iterate over `lastUsed`.
  - If `now - lastUsed[w] > idleTimeout`, shutdown and remove `LspSession`.

**Daemon lifetime:**

- Server continues running as long as there is at least one session or recent activity.
- Once all sessions are idle and `idleTimeout` has passed, it can exit automatically.
- Also handle signals (SIGTERM/SIGINT) to gracefully shutdown child `sourcekit-lsp` processes.

### 4.4 CLI Integration with Daemon

Add a `serve` command to `monocle`:

```bash
monocle serve --idle-timeout 600
```

**`serve` implementation (conceptual):**

1. Create the Unix domain socket (fail if already in use by an active server).
2. Instantiate `MonocleServer(idleTimeout: 600)`.
3. Enter an event loop:
   - Accept connections.
   - Read request JSON.
   - Call `MonocleServer.handle(request:)`.
   - Write response JSON.
4. Periodically call `reapIdleSessions()`.

**CLI commands (`inspect`, `definition`, `hover`) change to:**

1. Attempt to connect to the socket.
2. If successful:
   - Encode request JSON.
   - Send request.
   - Wait for response.
   - Print output (JSON or human-readable).
3. If connection fails:
   - Option A: fall back to direct MVP behavior (`LspSession` per call).
   - Option B: try to spawn background `monocle serve` then retry once; if still failing, fall back or error.

### 4.5 Stopping the Daemon

Optional `stop` command:

```bash
monocle stop
```

- Connects to the socket.
- Sends a special request:

```json
{ "id": "shutdown-1", "method": "shutdown", "params": {} }
```

- Server:
  - Shuts down all `LspSession`s.
  - Closes the socket and exits.
- Client prints something like: `Monocle daemon stopped.`

Also ensure cleanup on crash/termination by removing the socket file in `deinit`/signal handlers.

---

## 5. How an AI Agent Uses Monocle

Given:

- Project root (workspace path).
- Current file path.
- Line and column of the symbol.

The agent can:

1. Call:

   ```bash
   monocle inspect      --workspace /Users/dennis/Dev/MyApp      --file Sources/App/FooView.swift      --line 42      --col 17      --json
   ```

2. Parse the JSON response:
   - Extract `definition.snippet`
   - Extract `signature`
   - Extract `documentation`

3. Insert that information into its context, enabling deeper reasoning about third-party packages or unfamiliar APIs.

If the daemon is running, repeated calls are fast and share indexing across requests. If the daemon isn’t running, the MVP behavior still works by launching `sourcekit-lsp` per call, just with more overhead.

---

## 6. Refactor Risk and Future-Proofing

Because the design keeps LSP concerns in `MonocleCore` and treats the daemon as a separate transport layer:

- **MVP phase:**
  - `MonocleCLI` → `LspSession` → `sourcekit-lsp`
- **Daemon phase:**
  - `MonocleCLI` → (socket) → `MonocleServer` → `LspSession` → `sourcekit-lsp`
  - Or fallback to the MVP path when the server isn’t available.

This means:

- No major refactor when adding the daemon.
- No changes required in `LspSession`, `SymbolInfo`, or workspace logic.
- Only additive work: implement `MonocleServer`, JSON protocol, socket handling, and “try daemon then fallback” logic in the CLI.

This keeps monocle incremental, testable, and friendly to future integrations (e.g. MCP tools, editor plugins, or direct use inside a long-lived agent process).
