// By Dennis Müller

import ArgumentParser
import Foundation
import MonocleCore

/// Inspects a Swift symbol and returns combined definition and hover information.
///
/// When SourceKit-LSP cannot resolve a symbol (common for external package types in Xcode/Tuist
/// projects where the index may be incomplete), this command falls back to searching checked-out
/// packages for matching type definitions.
///
/// ## Alternative approaches for improving cross-module symbol resolution
///
/// The current fallback (symbol search) works well for type lookups but has limitations.
/// Future improvements could include:
///
/// 1. **Multi-workspace LSP sessions**: Open separate SourceKit-LSP sessions for each package
///    checkout. When the main workspace can't resolve a symbol, query the relevant package's
///    session directly. This would provide richer results including full hover documentation.
///
/// 2. **Hybrid index configuration**: Configure SourceKit-LSP to include Tuist/SwiftPM package
///    paths in its index search paths via `sourcekit-lsp` command-line options or compile
///    commands. This requires investigating SourceKit-LSP's `--index-store-path` and related
///    configuration.
///
/// 3. **Index store merging**: For Tuist projects, merge the package build indexes with the
///    main project index so SourceKit-LSP has complete symbol information.
struct InspectCommand: AsyncParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "inspect",
      abstract: "Inspect a Swift symbol and return definition and documentation.",
    )
  }

  /// Optional workspace root path that overrides auto-detection.
  @Option(
    name: [.customShort("w"), .long, .customLong("project")],
    help: "Workspace root path (Package.swift, .xcodeproj, or .xcworkspace). Alias: --project.",
  )
  var workspace: String?

  /// Swift source file that contains the target symbol.
  @Option(name: [.customShort("f"), .long], help: "Swift source file path.")
  var file: String

  /// One-based line number of the symbol location.
  @Option(name: [.customShort("l"), .long], help: "One-based line number of the symbol position.")
  var line: Int

  /// One-based column number of the symbol location.
  @Option(name: [.customShort("c"), .long], help: "One-based column number of the symbol position.")
  var column: Int

  /// Outputs JSON when `true`; otherwise prints human-readable text.
  @Flag(name: .long, help: "Emit JSON output instead of human-readable text.")
  var json: Bool = false

  /// Runs the inspect command and prints results in the requested format.
  mutating func run() async throws {
    let resolvedFile = FilePathResolver.absolutePath(for: file)
    let info: SymbolInfo

    do {
      info = try await SymbolCommandRunner.perform(
        method: .inspect,
        workspace: workspace,
        file: file,
        line: line,
        column: column,
      )
    } catch MonocleError.symbolNotFound {
      // Fallback: extract the word at cursor and search packages for matching types.
      // This handles cases where SourceKit-LSP can't resolve external package symbols
      // (common in Xcode/Tuist projects with incomplete indexes).
      if let fallbackInfo = try await fallbackToPackageSearch(file: resolvedFile) {
        info = fallbackInfo
      } else {
        throw MonocleError.symbolNotFound
      }
    }

    if json {
      try printJSON(info)
    } else {
      HumanReadablePrinter.printSymbolInfo(info)
    }
  }

  /// Attempts to find the symbol by searching checked-out packages.
  ///
  /// This fallback is used when SourceKit-LSP cannot resolve a symbol, which commonly
  /// occurs for external package types in Xcode/Tuist projects.
  ///
  /// - Parameter file: Absolute path to the source file.
  /// - Returns: Symbol information if a matching type is found in packages, nil otherwise.
  private func fallbackToPackageSearch(file: String) async throws -> SymbolInfo? {
    guard let symbolName = extractWordAtPosition(file: file, line: line, column: column) else {
      return nil
    }

    // Only fall back for identifiers that look like type names (start with uppercase)
    guard let firstChar = symbolName.first, firstChar.isUppercase else {
      return nil
    }

    let workspaceDescription = try WorkspaceLocator.locate(
      explicitWorkspacePath: workspace.map { FilePathResolver.absolutePath(for: $0) },
      filePath: file,
    )

    // Search checked-out packages for matching type definitions
    let results = try await SymbolCommand.searchPackagesForType(
      typeName: symbolName,
      workspace: workspaceDescription,
    )

    guard let bestMatch = results.first else {
      return nil
    }

    return SymbolInfo(
      symbol: bestMatch.name,
      kind: bestMatch.kind,
      module: bestMatch.module,
      definition: bestMatch.location,
      signature: bestMatch.signature,
      documentation: bestMatch.documentation,
    )
  }

  /// Extracts the word (identifier) at the given position in a file.
  ///
  /// - Parameters:
  ///   - file: Absolute path to the source file.
  ///   - line: One-based line number.
  ///   - column: One-based column number.
  /// - Returns: The identifier at the position, or nil if not found.
  private func extractWordAtPosition(file: String, line: Int, column: Int) -> String? {
    guard let contents = try? String(contentsOfFile: file) else { return nil }
    let lines = contents.components(separatedBy: "\n")

    guard line > 0, line <= lines.count else { return nil }
    let lineContent = lines[line - 1]

    guard column > 0, column <= lineContent.count + 1 else { return nil }

    let lineIndex = lineContent.index(lineContent.startIndex, offsetBy: column - 1, limitedBy: lineContent.endIndex)
      ?? lineContent.endIndex

    // Find word boundaries
    var startIndex = lineIndex
    while startIndex > lineContent.startIndex {
      let prevIndex = lineContent.index(before: startIndex)
      let char = lineContent[prevIndex]
      if char.isLetter || char.isNumber || char == "_" {
        startIndex = prevIndex
      } else {
        break
      }
    }

    var endIndex = lineIndex
    while endIndex < lineContent.endIndex {
      let char = lineContent[endIndex]
      if char.isLetter || char.isNumber || char == "_" {
        endIndex = lineContent.index(after: endIndex)
      } else {
        break
      }
    }

    guard startIndex < endIndex else { return nil }
    return String(lineContent[startIndex..<endIndex])
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
}
