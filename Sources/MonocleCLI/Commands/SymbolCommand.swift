// By Dennis Müller

import ArgumentParser
import Foundation
import MonocleCore

/// Searches workspace symbols by name using SourceKit-LSP.
struct SymbolCommand: AsyncParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "symbol",
      abstract: "Search workspace symbols by name using SourceKit-LSP.",
    )
  }

  /// Optional workspace root path that overrides auto-detection.
  @Option(
    name: [.customShort("w"), .long, .customLong("project")],
    help: "Workspace root path (Package.swift, .xcodeproj, or .xcworkspace). Alias: --project.",
  )
  var workspace: String?

  /// Query string to search for.
  @Option(name: [.customShort("q"), .long], help: "Symbol name query to search for.")
  var query: String

  /// Maximum number of results to return.
  @Option(name: .long, help: "Maximum number of results to return. Defaults to 5.")
  var limit: Int = 5

  /// Whether to enrich results with definition and documentation.
  @Flag(name: .long, help: "Enrich results with definition and documentation.")
  var enrich: Bool = false

  /// Only return exact symbol name matches.
  @Flag(name: .long, help: "Only return exact symbol name matches.")
  var exact: Bool = false

  /// Limit results by source scope.
  @Option(
    name: .long,
    help: "Limit results to a source scope. Options: all, project, package.",
  )
  var scope: SymbolSearchScope = .all

  /// Prefer project or package results when ranking.
  @Option(
    name: .long,
    help: "Ranking preference for project vs package results. Options: project, package, none.",
  )
  var prefer: SymbolSearchSourcePreference = .project

  /// Context lines to include around each symbol definition.
  @Option(name: .long, help: "Context lines to include around each symbol definition. Defaults to 2.")
  var contextLines: Int = 2

  /// Outputs JSON when `true`; otherwise prints human-readable text.
  @Flag(name: .long, help: "Emit JSON output instead of human-readable text.")
  var json: Bool = false

  mutating func run() async throws {
    var resolvedWorkspace = workspace.map { FilePathResolver.absolutePath(for: $0) }

    if resolvedWorkspace == nil {
      let detectedWorkspace = try WorkspaceLocator.locate(
        explicitWorkspacePath: nil,
        filePath: FileManager.default.currentDirectoryPath,
      )
      resolvedWorkspace = detectedWorkspace.rootPath
    }

    let workspaceDescription = try WorkspaceLocator.locate(
      explicitWorkspacePath: resolvedWorkspace,
      filePath: resolvedWorkspace ?? FileManager.default.currentDirectoryPath,
    )

    let output = try await performSymbolSearch(workspace: workspaceDescription)
    try render(output: output)
  }

  /// Prints the results in the requested format.
  ///
  /// - Parameter output: Symbol search results to render.
  private func render(output: SymbolSearchOutput) throws {
    if json {
      try printJSON(output.results)
    } else {
      HumanReadablePrinter.printSymbolSearchResults(output.rankedResults)
    }
  }

  /// Encodes the provided value as pretty-printed JSON.
  ///
  /// - Parameter value: Value to encode.
  private func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
      throw MonocleError.ioError("Unable to encode JSON output.")
    }

    print(output)
  }

  /// Searches checked-out packages for a type definition.
  ///
  /// This is used as a fallback when SourceKit-LSP cannot resolve a symbol in the main workspace.
  ///
  /// - Parameters:
  ///   - typeName: The type name to search for.
  ///   - workspace: The workspace to search within.
  /// - Returns: Matching symbol search results, filtered to type definitions.
  static func searchPackagesForType(typeName: String, workspace: Workspace) async throws -> [SymbolSearchResult] {
    var command = SymbolCommand()
    command.query = typeName
    command.limit = 5
    command.enrich = true
    command.exact = true
    command.scope = .package
    command.prefer = .package
    command.contextLines = 2

    let output = try await command.performSymbolSearch(workspace: workspace)

    // Filter to type definitions only
    let typeKinds: Set<String> = ["class", "struct", "enum", "protocol", "typealias"]
    return output.results.filter { result in
      guard let kind = result.kind else { return false }
      return typeKinds.contains(kind)
    }
  }
}
