// By Dennis Müller

import Foundation
import LanguageClient
import LanguageServerProtocol

/// Manages the lifetime of a single SourceKit-LSP session.
public actor LspSession {
  private let workspace: Workspace
  private let toolchain: ToolchainConfiguration?
  private let sourceKitService: SourceKitService
  private var openedDocuments: Set<String> = []
  private var serverGeneration: Int = 0

  /// Creates a session bound to a workspace with an optional toolchain override.
  ///
  /// - Parameters:
  ///   - workspace: Workspace description that determines how SourceKit-LSP should start.
  ///   - toolchain: Optional toolchain configuration to pass through to SourceKit-LSP.
  public init(workspace: Workspace, toolchain: ToolchainConfiguration? = nil) {
    self.workspace = workspace
    self.toolchain = toolchain
    sourceKitService = SourceKitService()
  }

  /// Provides a combined definition and hover view for a symbol.
  public func inspectSymbol(file: String, line: Int, column: Int) async throws -> SymbolInfo {
    let definitionInfo = try await fetchDefinition(file: file, line: line, column: column)
    let hoverInfo = try await fetchHover(file: file, line: line, column: column)

    return SymbolInfo(
      symbol: hoverInfo.symbol ?? definitionInfo.symbol,
      kind: definitionInfo.kind ?? hoverInfo.kind,
      module: definitionInfo.module ?? hoverInfo.module,
      definition: definitionInfo.definition,
      signature: hoverInfo.signature ?? definitionInfo.signature,
      documentation: hoverInfo.documentation ?? definitionInfo.documentation,
    )
  }

  /// Returns definition-only information for a symbol.
  public func definition(file: String, line: Int, column: Int) async throws -> SymbolInfo {
    try await fetchDefinition(file: file, line: line, column: column)
  }

  /// Returns hover-only information for a symbol.
  public func hover(file: String, line: Int, column: Int) async throws -> SymbolInfo {
    try await fetchHover(file: file, line: line, column: column)
  }

  /// Searches workspace symbols matching the provided query string.
  ///
  /// - Parameters:
  ///   - query: Search string forwarded to SourceKit-LSP.
  ///   - limit: Maximum number of results to return.
  ///   - enrich: When `true`, fetches signature and documentation for each result.
  /// - Returns: An array of matching symbols across the workspace.
  public func searchSymbols(matching query: String, limit: Int = 20, enrich: Bool = false) async throws
    -> [SymbolSearchResult] {
    guard limit > 0 else { return [] }

    let retryPolicy = makeRetryPolicy()
    let params = WorkspaceSymbolParams(query: query)

    let response = try await workspaceSymbolResponse(
      params: params,
      maxAttempts: retryPolicy.maxAttempts,
      delayNanoseconds: retryPolicy.delayNanoseconds,
    )

    let mapped = mapWorkspaceSymbolResponse(response).prefix(limit).map(\.self)
    guard enrich else { return Array(mapped) }

    var enrichedResults: [SymbolSearchResult] = []
    for result in mapped {
      if let enriched = try await enrichResult(result) {
        enrichedResults.append(enriched)
      } else {
        enrichedResults.append(result)
      }
    }
    return enrichedResults
  }

  /// Gracefully stops the LSP session.
  public func shutdown() async {
    await sourceKitService.shutdown()
    openedDocuments.removeAll()
    serverGeneration = 0
  }

  // MARK: - Private helpers

  /// Ensures there is an initialized SourceKit-LSP connection, starting one if necessary.
  ///
  /// - Returns: An initialized server connection ready for requests.
  private func ensureSessionReady() async throws -> InitializingServer {
    let handle = try await sourceKitService.start(workspace: workspace, toolchain: toolchain)
    if handle.generation != serverGeneration {
      openedDocuments.removeAll()
      serverGeneration = handle.generation
    }
    return handle.server
  }

  /// Looks up definition information for the provided location.
  ///
  /// - Parameters:
  ///   - file: Absolute path to the Swift source file.
  ///   - line: One-based line number where the symbol resides.
  ///   - column: One-based column number within the line.
  /// - Returns: Symbol metadata describing the resolved definition.
  /// - Throws: `MonocleError.symbolNotFound` when no definition is returned.
  private func fetchDefinition(file: String, line: Int, column: Int) async throws -> SymbolInfo {
    let textDocumentParams = try makeTextDocumentPosition(file: file, line: line, column: column)
    let retryPolicy = makeRetryPolicy()
    guard let response = try await performLspRequestWithRetries(
      maxAttempts: retryPolicy.maxAttempts,
      delayNanoseconds: retryPolicy.delayNanoseconds,
      requestTimeoutSeconds: 15,
      { connection in
        try await self.openIfNeeded(connection: connection, file: file)
        return try await connection.definition(textDocumentParams)
      },
    ) else {
      throw MonocleError.symbolNotFound
    }

    let location = try resolveLocation(from: response)
    return SymbolInfo(
      symbol: location.symbolName,
      kind: location.kind,
      module: location.moduleName,
      definition: location.info,
      signature: nil,
      documentation: nil,
    )
  }

  /// Retrieves hover content for the provided location.
  ///
  /// - Parameters:
  ///   - file: Absolute path to the Swift source file.
  ///   - line: One-based line number where the symbol resides.
  ///   - column: One-based column number within the line.
  /// - Returns: Symbol metadata derived from hover information.
  /// - Throws: `MonocleError.symbolNotFound` when hover data is unavailable.
  private func fetchHover(file: String, line: Int, column: Int) async throws -> SymbolInfo {
    let textDocumentParams = try makeTextDocumentPosition(file: file, line: line, column: column)
    let retryPolicy = makeRetryPolicy()
    guard let hoverResponse = try await performLspRequestWithRetries(
      maxAttempts: retryPolicy.maxAttempts,
      delayNanoseconds: retryPolicy.delayNanoseconds,
      requestTimeoutSeconds: 15,
      { connection in
        try await self.openIfNeeded(connection: connection, file: file)
        return try await connection.hover(textDocumentParams)
      },
    ) else {
      throw MonocleError.symbolNotFound
    }

    let rendered = renderHover(hoverResponse)
    return SymbolInfo(
      symbol: rendered.symbol,
      kind: rendered.kind,
      module: rendered.module,
      definition: nil,
      signature: rendered.signature,
      documentation: rendered.documentation,
    )
  }

  /// Builds a text document position request after validating line and column values.
  ///
  /// - Parameters:
  ///   - file: Absolute path to the Swift source file.
  ///   - line: One-based line number of the requested position.
  ///   - column: One-based column number of the requested position.
  /// - Returns: A `TextDocumentPositionParams` ready for LSP requests.
  /// - Throws: `MonocleError.ioError` when line or column are invalid.
  private func makeTextDocumentPosition(file: String, line: Int, column: Int) throws -> TextDocumentPositionParams {
    guard line > 0, column > 0 else {
      throw MonocleError.ioError("Line and column must be one-based positive values.")
    }

    let uri = URL(fileURLWithPath: file).absoluteString
    let position = Position(line: line - 1, character: column - 1)
    return TextDocumentPositionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position)
  }

  /// Opens the document in the LSP session if it has not been opened already.
  ///
  /// - Parameters:
  ///   - connection: Active SourceKit-LSP server connection.
  ///   - file: Absolute path to the Swift source file.
  private func openIfNeeded(connection: InitializingServer, file: String) async throws {
    let uri = URL(fileURLWithPath: file).absoluteString
    if openedDocuments.contains(uri) { return }
    let text = try String(contentsOfFile: file)
    let item = TextDocumentItem(uri: uri, languageId: "swift", version: 1, text: text)
    try await performWithTimeout(seconds: 5) {
      try await connection.textDocumentDidOpen(DidOpenTextDocumentParams(textDocument: item))
    }
    openedDocuments.insert(uri)
  }

  /// Resolves a usable location and symbol metadata from a `DefinitionResponse`.
  ///
  /// - Parameter response: The raw LSP definition response.
  /// - Returns: Tuple containing a prepared location and optional symbol metadata.
  /// - Throws: `MonocleError.symbolNotFound` when the response is empty.
  private func resolveLocation(from response: DefinitionResponse) throws
    -> (info: SymbolInfo.Location, symbolName: String?, kind: String?, moduleName: String?) {
    switch response {
    case let .optionA(singleLocation):
      let locationInfo = try makeLocation(singleLocation)
      return (locationInfo, nil, nil, nil)
    case let .optionB(locations):
      guard let first = locations.first else { throw MonocleError.symbolNotFound }

      let locationInfo = try makeLocation(first)
      return (locationInfo, nil, nil, nil)
    case let .optionC(links):
      guard let first = links.first else { throw MonocleError.symbolNotFound }

      let location = first.targetSelectionRange
      let uri = URL(string: first.targetUri) ?? URL(fileURLWithPath: first.targetUri)
      let locationInfo = SymbolInfo.Location(
        uri: uri,
        startLine: location.start.line + 1,
        startCharacter: location.start.character + 1,
        endLine: location.end.line + 1,
        endCharacter: location.end.character + 1,
        snippet: extractSnippet(from: uri, range: location),
      )
      return (locationInfo, nil, nil, nil)
    case .none:
      throw MonocleError.symbolNotFound
    }
  }

  /// Converts an LSP `Location` into the `SymbolInfo.Location` representation.
  ///
  /// - Parameter location: LSP location containing URI and range.
  /// - Returns: A converted location with one-based line and column values.
  /// - Throws: `MonocleError.symbolNotFound` when the URI is malformed.
  private func makeLocation(_ location: Location) throws -> SymbolInfo.Location {
    let uri = URL(string: location.uri) ?? URL(fileURLWithPath: location.uri)
    return SymbolInfo.Location(
      uri: uri,
      startLine: location.range.start.line + 1,
      startCharacter: location.range.start.character + 1,
      endLine: location.range.end.line + 1,
      endCharacter: location.range.end.character + 1,
      snippet: extractSnippet(from: uri, range: location.range),
    )
  }

  private func shouldRestartSourceKit(after error: Error) -> Bool {
    if error is CancellationError { return false }

    let localized = error.localizedDescription.lowercased()
    let description = String(describing: error).lowercased()
    let combined = localized + " " + description

    if combined.contains("datastreamclosed") { return true }
    if combined.contains("connection reset") { return true }
    if combined.contains("broken pipe") { return true }
    if combined.contains("service is invalid") { return true }
    if combined.contains("sourcekitd fatal error") { return true }

    if combined.contains("timed out") { return true }

    return false
  }

  private func workspaceSymbolResponse(
    params: WorkspaceSymbolParams,
    maxAttempts: Int,
    delayNanoseconds: UInt64,
  ) async throws -> WorkspaceSymbolResponse {
    var attempt = 0

    while attempt < maxAttempts {
      let response = try await performLspRequestWithRetries(
        maxAttempts: 1,
        delayNanoseconds: 0,
        requestTimeoutSeconds: 30,
        { connection in try await connection.workspaceSymbol(params) },
      )

      if let response {
        let mappedCount = mapWorkspaceSymbolResponse(response).count
        if mappedCount > 0 {
          return response
        }
      }

      attempt += 1
      if attempt < maxAttempts {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      }
    }

    return nil
  }

  /// Executes an LSP operation with retry and process-restart recovery.
  ///
  /// Some SourceKit-LSP failures are transient (e.g. indexing/build settings not ready yet) and yield `nil` responses.
  /// Others indicate a broken transport or crashed SourceKit service; those require restarting the process.
  private func performLspRequestWithRetries<T: Sendable>(
    maxAttempts: Int,
    delayNanoseconds: UInt64,
    requestTimeoutSeconds: TimeInterval,
    _ operation: @escaping @Sendable (InitializingServer) async throws -> T?,
  ) async throws -> T? {
    var attempt = 0
    var hasRestarted = false

    while attempt < maxAttempts {
      do {
        let connection = try await ensureSessionReady()
        let result = try await performWithTimeout(seconds: requestTimeoutSeconds) {
          try await operation(connection)
        }
        if let result {
          return result
        }
      } catch {
        if shouldRestartSourceKit(after: error), hasRestarted == false {
          hasRestarted = true
          await sourceKitService.forceTerminate()
          attempt += 1
          continue
        }
        throw error
      }

      attempt += 1
      try await Task.sleep(nanoseconds: delayNanoseconds) // allow build settings to arrive from build server
    }

    return nil
  }

  /// Chooses retry behavior tuned to the workspace kind.
  ///
  /// - Returns: Attempt and delay values suitable for SourceKit-LSP readiness.
  private func makeRetryPolicy() -> (maxAttempts: Int, delayNanoseconds: UInt64) {
    switch workspace.kind {
    case .swiftPackage:
      (maxAttempts: 15, delayNanoseconds: 800_000_000) // SwiftPM often needs extra time to surface build settings
    case .xcodeProject, .xcodeWorkspace:
      (maxAttempts: 5, delayNanoseconds: 350_000_000)
    }
  }

  /// Converts a workspace symbol response into search results.
  ///
  /// - Parameter response: Raw workspace symbol response from SourceKit-LSP.
  /// - Returns: Flattened list of symbol search results.
  private func mapWorkspaceSymbolResponse(_ response: WorkspaceSymbolResponse) -> [SymbolSearchResult] {
    guard let response else { return [] }

    switch response {
    case let .optionA(informationArray):
      return informationArray.map(mapSymbolInformation)
    case let .optionB(symbolArray):
      return symbolArray.compactMap(mapWorkspaceSymbol)
    }
  }

  /// Converts `SymbolInformation` into `SymbolSearchResult`.
  private func mapSymbolInformation(_ info: SymbolInformation) -> SymbolSearchResult {
    let location = try? makeLocation(info.location)
    return SymbolSearchResult(
      name: info.name,
      kind: humanReadableKind(info.kind),
      containerName: info.containerName,
      module: nil,
      location: location,
      documentURI: location?.uri,
      signature: nil,
      documentation: nil,
    )
  }

  /// Converts `WorkspaceSymbol` into `SymbolSearchResult`, handling both location shapes.
  private func mapWorkspaceSymbol(_ symbol: WorkspaceSymbol) -> SymbolSearchResult? {
    let location: SymbolInfo.Location?
    let documentURI: URL?
    if let locationOption = symbol.location {
      switch locationOption {
      case let .optionA(lspLocation):
        let resolvedLocation = try? makeLocation(lspLocation)
        location = resolvedLocation
        documentURI = resolvedLocation?.uri
      case let .optionB(textDocumentIdentifier):
        // The server provided a document URI without a range; surface that we lack precise position data.
        location = nil
        documentURI = URL(string: textDocumentIdentifier.uri) ?? URL(fileURLWithPath: textDocumentIdentifier.uri)
      }
    } else {
      location = nil
      documentURI = nil
    }

    return SymbolSearchResult(
      name: symbol.name,
      kind: humanReadableKind(symbol.kind),
      containerName: symbol.containerName,
      module: nil,
      location: location,
      documentURI: documentURI,
      signature: nil,
      documentation: nil,
    )
  }

  /// Converts an LSP symbol kind into a human-readable description.
  private func humanReadableKind(_ kind: SymbolKind) -> String {
    switch kind {
    case .file: "file"
    case .module: "module"
    case .namespace: "namespace"
    case .package: "package"
    case .class: "class"
    case .method: "method"
    case .property: "property"
    case .field: "field"
    case .constructor: "initializer"
    case .enum: "enum"
    case .interface: "protocol"
    case .function: "function"
    case .variable: "variable"
    case .constant: "constant"
    case .string: "string"
    case .number: "number"
    case .boolean: "boolean"
    case .array: "array"
    case .object: "object"
    case .key: "key"
    case .null: "null"
    case .enumMember: "enum member"
    case .struct: "struct"
    case .event: "event"
    case .operator: "operator"
    case .typeParameter: "type parameter"
    }
  }

  /// Enriches a search result with signature, documentation, and precise location when possible.
  ///
  /// - Parameters:
  ///   - result: The base search result to enrich.
  /// - Returns: An enriched result or `nil` when enrichment is not possible.
  private func enrichResult(_ result: SymbolSearchResult) async throws -> SymbolSearchResult? {
    guard let location = result.location, location.uri.isFileURL else { return nil }

    let line = location.startLine
    let column = max(location.startCharacter, 1)
    let filePath = location.uri.path

    let definitionInfo = try? await fetchDefinition(file: filePath, line: line, column: column)
    let hoverInfo = try? await fetchHover(file: filePath, line: line, column: column)

    let mergedLocation = definitionInfo?.definition ?? result.location
    let signature = hoverInfo?.signature ?? definitionInfo?.signature ?? result.signature
    let documentation = hoverInfo?.documentation ?? result.documentation
    let module = definitionInfo?.module ?? result.module

    return SymbolSearchResult(
      name: result.name,
      kind: result.kind,
      containerName: result.containerName,
      module: module,
      location: mergedLocation,
      documentURI: mergedLocation?.uri ?? result.documentURI,
      signature: signature,
      documentation: documentation,
    )
  }
}
