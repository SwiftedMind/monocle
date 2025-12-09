// By Dennis Müller

import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import ProcessEnv

/// Launches and manages a single SourceKit-LSP process and JSON-RPC channel.
public actor SourceKitService {
  private var server: InitializingServer?
  private var process: Process?

  /// Creates a service ready to lazily start SourceKit-LSP.
  public init() {}

  /// Starts SourceKit-LSP if needed and returns the initialized server connection.
  /// - Parameters:
  ///   - workspace: Workspace root used for LSP initialization.
  ///   - toolchain: Optional toolchain override (developer directory or sourcekit-lsp path).
  /// - Returns: An initialized `InitializingServer` ready for requests.
  public func start(workspace: Workspace, toolchain: ToolchainConfiguration?) async throws -> InitializingServer {
    if let existingServer = server {
      return existingServer
    }

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
    return initializingServer
  }

  /// Sends shutdown and exit to the server and cleans up the child process.
  public func shutdown() async {
    defer {
      server = nil
      process = nil
    }

    guard let activeServer = server else { return }

    do {
      try await activeServer.shutdownAndExit()
    } catch {
      process?.terminate()
    }
  }

  /// Cleans up state when the child SourceKit-LSP process terminates unexpectedly.
  private func handleTermination() async {
    server = nil
    process = nil
  }

  /// Client capabilities advertised to SourceKit-LSP.
  private static var clientCapabilities: ClientCapabilities {
    let textDocumentCapabilities = TextDocumentClientCapabilities(
      hover: HoverClientCapabilities(dynamicRegistration: false, contentFormat: [.markdown, .plaintext]),
      definition: DefinitionClientCapabilities(dynamicRegistration: false, linkSupport: true),
    )
    return ClientCapabilities(
      workspace: nil,
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

    if let explicitSourceKit = toolchain?.sourceKitPath {
      binaryPath = explicitSourceKit
    } else {
      binaryPath = "/usr/bin/xcrun"
      arguments = ["sourcekit-lsp"]
    }

    switch workspace.kind {
    case .swiftPackage:
      sourceKitArguments.append(contentsOf: ["--default-workspace-type", "swiftPM"])
      let scratchPath = URL(fileURLWithPath: workspace.rootPath).appendingPathComponent(".sourcekit-lsp-scratch").path
      sourceKitArguments.append(contentsOf: ["--scratch-path", scratchPath])
      let buildPath = URL(fileURLWithPath: workspace.rootPath).appendingPathComponent(".build").path
      sourceKitArguments.append(contentsOf: ["--build-path", buildPath])
      sourceKitArguments.append(contentsOf: ["--configuration", "debug"])
    case .xcodeProject, .xcodeWorkspace:
      if shouldPreferBuildServer(for: workspace) {
        sourceKitArguments.append(contentsOf: ["--default-workspace-type", "buildServer"])
      }
    }

    var environment = ProcessInfo.processInfo.environment
    if let developerDirectory = toolchain?.developerDirectory {
      environment["DEVELOPER_DIR"] = developerDirectory
    }
    if workspace.kind == .swiftPackage {
      environment["HOME"] = workspace.rootPath
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

  /// Determines whether a non-SwiftPM workspace should prefer the build server protocol.
  private func shouldPreferBuildServer(for workspace: Workspace) -> Bool {
    guard workspace.kind != .swiftPackage else { return false }

    let buildServerPath = URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("buildServer.json")
    return FileManager.default.fileExists(atPath: buildServerPath.path)
  }

  /// Attempts to query the SourceKit-LSP version by running `sourcekit-lsp --version`.
  ///
  /// - Returns: Version string reported by the `sourcekit-lsp --version` invocation.
  /// - Throws: `MonocleError.lspLaunchFailed` when the process exits with a non-zero status.
  public static func detectSourceKitVersion() throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["sourcekit-lsp", "--version"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MonocleError.lspLaunchFailed("sourcekit-lsp --version returned non-zero exit code")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
  }
}
