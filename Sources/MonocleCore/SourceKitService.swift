// By Dennis Müller

import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import ProcessEnv

/// Launches and manages a single SourceKit-LSP process and JSON-RPC channel.
public actor SourceKitService {
  /// Tracks the currently running SourceKit-LSP connection, if any.
  private var server: InitializingServer?
  private var process: Process?
  private var serverGeneration: Int = 0

  /// Creates a service ready to lazily start SourceKit-LSP.
  public init() {}

  /// Wraps the current initialized server together with a generation counter that changes when the
  /// underlying SourceKit-LSP process is restarted.
  public struct ServerHandle: Sendable {
    public var server: InitializingServer
    public var generation: Int

    public init(server: InitializingServer, generation: Int) {
      self.server = server
      self.generation = generation
    }
  }

  /// Starts SourceKit-LSP if needed and returns the initialized server connection.
  /// - Parameters:
  ///   - workspace: Workspace root used for LSP initialization.
  ///   - toolchain: Optional toolchain override (developer directory or sourcekit-lsp path).
  /// - Returns: An initialized `InitializingServer` ready for requests.
  public func start(workspace: Workspace, toolchain: ToolchainConfiguration?) async throws -> ServerHandle {
    if let existingServer = server {
      return ServerHandle(server: existingServer, generation: serverGeneration)
    }

    serverGeneration += 1
    let parameters = try makeExecutionParameters(workspace: workspace, toolchain: toolchain)
    let channelWithProcess: (channel: DataChannel, process: Process) = try DataChannel
      .localProcessChannel(parameters: parameters) { [weak self] in
        let _: Task<Void, Never> = Task.detached(priority: .background) {
          await self?.handleTermination()
        }
      }
    process = channelWithProcess.process

    let connection = JSONRPCServerConnection(dataChannel: channelWithProcess.channel)
    let initializeProvider: InitializingServer.InitializeParamsProvider = { [workspace] in
      let rootURL = URL(fileURLWithPath: workspace.rootPath)
      let workspaceFolder = WorkspaceFolder(uri: rootURL.absoluteString, name: rootURL.lastPathComponent)
      return InitializeParams(
        processId: Int(ProcessInfo.processInfo.processIdentifier),
        clientInfo: InitializeParams.ClientInfo(name: "monocle", version: toolVersion),
        locale: Locale.current.identifier,
        rootPath: workspace.rootPath,
        rootUri: rootURL.absoluteString,
        initializationOptions: nil,
        capabilities: Self.clientCapabilities,
        trace: nil,
        workspaceFolders: [workspaceFolder],
      )
    }

    let initializingServer = InitializingServer(server: connection, initializeParamsProvider: initializeProvider)
    server = initializingServer
    return ServerHandle(server: initializingServer, generation: serverGeneration)
  }

  /// Sends shutdown and exit to the server and cleans up the child process.
  public func shutdown(timeoutSeconds: TimeInterval = 2) async {
    defer {
      server = nil
      process = nil
    }

    guard let activeServer = server else { return }

    do {
      try await performWithTimeout(seconds: timeoutSeconds) {
        try await activeServer.shutdownAndExit()
      }
    } catch {
      process?.terminate()
    }
  }

  /// Force-terminates the SourceKit-LSP child process (if present) and discards the current connection.
  public func forceTerminate() {
    process?.terminate()
    server = nil
    process = nil
  }

  /// Returns the current server generation counter.
  public func currentServerGeneration() -> Int {
    serverGeneration
  }

  /// Cleans up state when the child SourceKit-LSP process terminates unexpectedly.
  private func handleTermination() async {
    server = nil
    process = nil
  }

  private func performWithTimeout(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Void,
  ) async throws {
    guard seconds > 0 else {
      try await operation()
      return
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw MonocleError.ioError("Operation timed out after \(seconds)s.")
      }

      _ = try await group.next()
      group.cancelAll()
    }
  }

  /// Client capabilities advertised to SourceKit-LSP.
  private static var clientCapabilities: ClientCapabilities {
    let textDocumentCapabilities = TextDocumentClientCapabilities(
      hover: HoverClientCapabilities(dynamicRegistration: false, contentFormat: [.markdown, .plaintext]),
      definition: DefinitionClientCapabilities(dynamicRegistration: false, linkSupport: true),
    )
    let workspaceCapabilities = ClientCapabilities.Workspace(
      applyEdit: false,
      workspaceEdit: nil,
      didChangeConfiguration: nil,
      didChangeWatchedFiles: nil,
      symbol: WorkspaceSymbolClientCapabilities(
        dynamicRegistration: false,
        symbolKind: nil,
        tagSupport: nil,
        resolveSupport: [],
      ),
      executeCommand: nil,
      workspaceFolders: true,
      configuration: nil,
      semanticTokens: nil,
      codeLens: nil,
      fileOperations: nil,
    )
    return ClientCapabilities(
      workspace: workspaceCapabilities,
      textDocument: textDocumentCapabilities,
      window: nil,
      general: nil,
      experimental: nil,
    )
  }

  /// Builds the process parameters used to launch SourceKit-LSP for a workspace.
  ///
  /// - Parameters:
  ///   - workspace: Workspace description used to derive scratch and build paths.
  ///   - toolchain: Optional toolchain overrides for binary path or environment.
  /// - Returns: Execution parameters suitable for `Process` creation.
  /// - Throws: `MonocleError.ioError` when arguments cannot be constructed.
  private func makeExecutionParameters(workspace: Workspace, toolchain: ToolchainConfiguration?) throws -> Process
    .ExecutionParameters {
    let binaryPath: String
    var arguments: [String] = []
    var sourceKitArguments: [String] = []
    let shouldUseBuildServer = shouldPreferBuildServer(for: workspace)
    let shouldUseSwiftPMBuildSystem = shouldUseSwiftPMBuildSystem(
      for: workspace,
      shouldUseBuildServer: shouldUseBuildServer,
    )

    if let explicitSourceKit = toolchain?.sourceKitPath {
      binaryPath = explicitSourceKit
    } else {
      binaryPath = "/usr/bin/xcrun"
      arguments = ["sourcekit-lsp"]
    }

    switch workspace.kind {
    case .swiftPackage:
      appendSwiftPMArguments(workspaceRootPath: workspace.rootPath, arguments: &sourceKitArguments)
    case .xcodeProject, .xcodeWorkspace:
      if shouldUseBuildServer {
        sourceKitArguments.append(contentsOf: ["--default-workspace-type", "buildServer"])
      } else if shouldUseSwiftPMBuildSystem {
        appendSwiftPMArguments(workspaceRootPath: workspace.rootPath, arguments: &sourceKitArguments)
      } else {
        throw MonocleError.buildServerConfigurationMissing(workspaceRootPath: workspace.rootPath)
      }
    case .compilationDatabase:
      sourceKitArguments.append(contentsOf: ["--default-workspace-type", "compilationDatabase"])
    }

    var environment = ProcessInfo.processInfo.environment
    if let developerDirectory = toolchain?.developerDirectory {
      environment["DEVELOPER_DIR"] = developerDirectory
    }
    if shouldUseSwiftPMBuildSystem {
      environment["SWIFTPM_CACHE_PATH"] = URL(fileURLWithPath: workspace.rootPath)
        .appendingPathComponent(".swiftpm-cache").path
    }

    return Process.ExecutionParameters(
      path: binaryPath,
      arguments: arguments + sourceKitArguments,
      environment: environment,
      currentDirectoryURL: URL(fileURLWithPath: workspace.rootPath),
    )
  }

  private func appendSwiftPMArguments(workspaceRootPath: String, arguments: inout [String]) {
    arguments.append(contentsOf: ["--default-workspace-type", "swiftPM"])
    let scratchPath = URL(fileURLWithPath: workspaceRootPath).appendingPathComponent(".sourcekit-lsp-scratch").path
    arguments.append(contentsOf: ["--scratch-path", scratchPath])
    arguments.append(contentsOf: ["--configuration", "debug"])
  }

  private func shouldUseSwiftPMBuildSystem(for workspace: Workspace, shouldUseBuildServer: Bool) -> Bool {
    if workspace.kind == .swiftPackage { return true }
    if shouldUseBuildServer { return false }

    let manifestURL = URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("Package.swift")
    guard let contents = try? String(contentsOf: manifestURL) else { return false }

    let hasAnyTargetDeclaration = contents.contains(".target(")
      || contents.contains(".executableTarget(")
      || contents.contains(".testTarget(")
      || contents.contains(".macro(")

    return hasAnyTargetDeclaration
  }

  /// Determines whether a non-SwiftPM workspace should prefer the build server protocol.
  private func shouldPreferBuildServer(for workspace: Workspace) -> Bool {
    if workspace.kind == .swiftPackage || workspace.kind == .compilationDatabase {
      return false
    }

    let buildServerPath = URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("buildServer.json")
    return FileManager.default.fileExists(atPath: buildServerPath.path)
  }

  /// Attempts to detect the SourceKit-LSP version by querying the Swift toolchain version.
  ///
  /// Since `sourcekit-lsp --version` is no longer supported, this runs `swift --version`
  /// and extracts a concise version string from the output.
  ///
  /// - Returns: A version string such as "Apple Swift version 6.3.1", or "unknown".
  public static func detectSourceKitVersion() -> String {
    let process = Process()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", "--version"]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return "unknown"
    }
    guard process.terminationStatus == 0 else {
      return "unknown"
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    let firstLine = output.split(separator: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    // Try to extract a concise version like "Apple Swift version 6.3.1"
    if let range = firstLine.range(of: "Swift version ") {
      let suffix = String(firstLine[range.upperBound...])
      let components = suffix.split(separator: " ")
      if let version = components.first {
        return "Swift version \(version)"
      }
    }

    return firstLine.isEmpty ? "unknown" : firstLine
  }
}
