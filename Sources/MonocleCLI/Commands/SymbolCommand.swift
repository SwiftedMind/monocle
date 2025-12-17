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

    let parameters = DaemonRequestParameters(
      workspaceRootPath: workspaceDescription.rootPath,
      query: query,
      limit: limit,
      enrich: enrich,
    )

    if let daemonResults = try await AutomaticDaemonLauncher.sendSymbolSearch(parameters: parameters) {
      let augmentedResults = try await augmentWithCheckedOutPackageSymbolsIfNeeded(
        results: daemonResults,
        workspace: workspaceDescription,
      )
      try output(results: augmentedResults)
      return
    }

    let session = LspSession(workspace: workspaceDescription)
    let results = try await session.searchSymbols(matching: query, limit: limit, enrich: enrich)
    let augmentedResults = try await augmentWithCheckedOutPackageSymbolsIfNeeded(
      results: results,
      workspace: workspaceDescription,
    )
    try output(results: augmentedResults)
  }

  /// Prints the results in the requested format.
  ///
  /// - Parameter results: Symbol search results to render.
  private func output(results: [SymbolSearchResult]) throws {
    if json {
      try printJSON(results)
    } else {
      HumanReadablePrinter.printSymbolSearchResults(results)
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

  private func augmentWithCheckedOutPackageSymbolsIfNeeded(
    results: [SymbolSearchResult],
    workspace: Workspace,
  ) async throws -> [SymbolSearchResult] {
    let deduplicatedResults = deduplicating(results)
    if resultsContainExactTypeMatch(results: deduplicatedResults) {
      return deduplicatedResults
    }

    let checkedOutPackages: [PackageCheckout]
    do {
      checkedOutPackages = try PackageCheckoutLocator.checkedOutPackages(in: workspace)
    } catch {
      return deduplicatedResults
    }

    let localDependencyRoots = XcodeSwiftPackageDependencyLocator.localPackageRootPaths(for: workspace)
    let localDependencyPackages = localDependencyRoots.map { rootPath in
      PackageCheckout(
        packageName: URL(fileURLWithPath: rootPath).lastPathComponent,
        checkoutPath: rootPath,
        readmePath: nil,
      )
    }

    let allPackages = checkedOutPackages + localDependencyPackages

    let candidatePackages = allPackages.filter { checkout in
      hasLikelyDeclaration(for: query, packageRootPath: checkout.checkoutPath)
    }

    guard candidatePackages.isEmpty == false else {
      return deduplicatedResults
    }

    var additionalResults: [SymbolSearchResult] = []
    for package in candidatePackages {
      let packageResults = try await searchSymbols(
        in: package.checkoutPath,
        query: query,
        limit: max(limit, 20),
        enrich: enrich,
      )

      let filtered = packageResults.filter { matchesTypeQuery(resultName: $0.name, query: query) }
      additionalResults.append(contentsOf: filtered)

      if additionalResults.contains(where: { isTypeKind($0.kind) }) {
        break
      }
    }

    if resultsContainExactTypeMatch(results: additionalResults) == false {
      let typeDeclarationResults = try await locateTypeDeclarationsInPackages(
        packages: candidatePackages,
        typeName: query,
        enrich: enrich,
        limit: limit,
      )
      additionalResults.append(contentsOf: typeDeclarationResults)
    }

    let merged = deduplicating(deduplicatedResults + additionalResults)
    return merged
  }

  private func searchSymbols(
    in workspaceRootPath: String,
    query: String,
    limit: Int,
    enrich: Bool,
  ) async throws -> [SymbolSearchResult] {
    let parameters = DaemonRequestParameters(
      workspaceRootPath: workspaceRootPath,
      query: query,
      limit: limit,
      enrich: enrich,
    )

    if let daemonResults = try await AutomaticDaemonLauncher.sendSymbolSearch(parameters: parameters) {
      return daemonResults
    }

    let workspaceDescription = try WorkspaceLocator.locate(
      explicitWorkspacePath: workspaceRootPath,
      filePath: workspaceRootPath,
    )
    let session = LspSession(workspace: workspaceDescription)
    return try await session.searchSymbols(matching: query, limit: limit, enrich: enrich)
  }

  private func inspectSymbol(
    in workspaceRootPath: String,
    file: String,
    line: Int,
    column: Int,
  ) async throws -> SymbolInfo {
    let parameters = DaemonRequestParameters(
      workspaceRootPath: workspaceRootPath,
      filePath: file,
      line: line,
      column: column,
    )

    if let daemonResult = try await AutomaticDaemonLauncher.send(method: .inspect, parameters: parameters) {
      return daemonResult
    }

    let workspaceDescription = try WorkspaceLocator.locate(
      explicitWorkspacePath: workspaceRootPath,
      filePath: workspaceRootPath,
    )
    let session = LspSession(workspace: workspaceDescription)
    return try await session.inspectSymbol(file: file, line: line, column: column)
  }

  private func resultsContainExactTypeMatch(results: [SymbolSearchResult]) -> Bool {
    results.contains { result in
      matchesTypeQuery(resultName: result.name, query: query) && isTypeKind(result.kind)
    }
  }

  private func matchesTypeQuery(resultName: String, query: String) -> Bool {
    if resultName.caseInsensitiveCompare(query) == .orderedSame {
      return true
    }

    // Some servers return fully qualified names for types (e.g. `Module.TypeName`).
    let normalizedQuery = query.lowercased()
    let normalizedResult = resultName.lowercased()
    return normalizedResult.hasSuffix(".\(normalizedQuery)")
  }

  private func isTypeKind(_ kind: String?) -> Bool {
    guard let kind else { return false }

    switch kind {
    case "class", "struct", "enum", "protocol":
      return true
    default:
      return false
    }
  }

  private func deduplicating(_ results: [SymbolSearchResult]) -> [SymbolSearchResult] {
    struct Key: Hashable {
      var name: String
      var uri: String?
      var startLine: Int?
    }

    var seen = Set<Key>()
    var output: [SymbolSearchResult] = []
    for result in results {
      let key = Key(
        name: result.name,
        uri: result.location?.uri.absoluteString ?? result.documentURI?.absoluteString,
        startLine: result.location?.startLine,
      )
      guard seen.contains(key) == false else { continue }

      seen.insert(key)
      output.append(result)
    }
    return output
  }

  private func hasLikelyDeclaration(for symbolName: String, packageRootPath: String) -> Bool {
    let fileManager = FileManager.default
    let packageRootURL = URL(fileURLWithPath: packageRootPath, isDirectory: true)
    let sourcesRootURL = packageRootURL.appendingPathComponent("Sources", isDirectory: true)
    let searchRootURL: URL = fileManager.fileExists(atPath: sourcesRootURL.path) ? sourcesRootURL : packageRootURL

    let preferredFilename = "\(symbolName).swift"
    if let enumerator = fileManager.enumerator(at: searchRootURL, includingPropertiesForKeys: nil) {
      var scannedFileCount = 0
      for case let fileURL as URL in enumerator {
        scannedFileCount += 1
        if scannedFileCount > 5000 {
          break
        }

        if shouldSkipPackageSearchDirectory(fileURL) {
          enumerator.skipDescendants()
          continue
        }

        if fileURL.lastPathComponent == preferredFilename {
          return true
        }

        if fileURL.pathExtension != "swift" {
          continue
        }
        if fileURL.lastPathComponent.localizedCaseInsensitiveContains(symbolName) == false {
          continue
        }
        if let contents = try? String(contentsOf: fileURL), contents.contains(" \(symbolName)") {
          return true
        }
      }
    }

    return false
  }

  private func shouldSkipPackageSearchDirectory(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    if name == ".git" { return true }
    if name == ".build" { return true }
    if name == ".swiftpm" { return true }
    return false
  }

  private struct TypeDeclarationCandidate: Sendable {
    var kindKeyword: String
    var filePath: String
    var line: Int
    var column: Int
    var lineSnippet: String
  }

  private func locateTypeDeclarationsInPackages(
    packages: [PackageCheckout],
    typeName: String,
    enrich: Bool,
    limit: Int,
  ) async throws -> [SymbolSearchResult] {
    var results: [SymbolSearchResult] = []

    for package in packages {
      let candidates = findTypeDeclarationCandidates(
        typeName: typeName,
        packageRootPath: package.checkoutPath,
        maximumCandidates: max(limit, 5),
      )

      guard candidates.isEmpty == false else { continue }

      if enrich {
        for candidate in candidates {
          let info = try await inspectSymbol(
            in: package.checkoutPath,
            file: candidate.filePath,
            line: candidate.line,
            column: candidate.column,
          )

          let location = info.definition ?? SymbolInfo.Location(
            uri: URL(fileURLWithPath: candidate.filePath),
            startLine: candidate.line,
            startCharacter: candidate.column,
            endLine: candidate.line,
            endCharacter: candidate.column,
            snippet: candidate.lineSnippet,
          )

          results.append(SymbolSearchResult(
            name: typeName,
            kind: candidate.kindKeyword,
            containerName: nil,
            module: info.module,
            location: location,
            documentURI: location.uri,
            signature: info.signature,
            documentation: info.documentation,
          ))

          if results.count >= limit { break }
        }
      } else {
        for candidate in candidates {
          let location = SymbolInfo.Location(
            uri: URL(fileURLWithPath: candidate.filePath),
            startLine: candidate.line,
            startCharacter: candidate.column,
            endLine: candidate.line,
            endCharacter: candidate.column,
            snippet: candidate.lineSnippet,
          )
          results.append(SymbolSearchResult(
            name: typeName,
            kind: candidate.kindKeyword,
            containerName: nil,
            module: nil,
            location: location,
            documentURI: location.uri,
            signature: nil,
            documentation: nil,
          ))
          if results.count >= limit { break }
        }
      }

      if results.count >= limit { break }
    }

    return results
  }

  private func findTypeDeclarationCandidates(
    typeName: String,
    packageRootPath: String,
    maximumCandidates: Int,
  ) -> [TypeDeclarationCandidate] {
    guard maximumCandidates > 0 else { return [] }

    let sourcesRootURL = URL(fileURLWithPath: packageRootPath, isDirectory: true).appendingPathComponent(
      "Sources",
      isDirectory: true,
    )
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourcesRootURL.path) else { return [] }
    guard let regex = try? NSRegularExpression(
      pattern: "\\b(enum|struct|class|protocol)\\s+\\Q\(typeName)\\E\\b",
      options: [],
    ) else {
      return []
    }

    var candidates: [TypeDeclarationCandidate] = []
    if let enumerator = fileManager.enumerator(at: sourcesRootURL, includingPropertiesForKeys: nil) {
      for case let fileURL as URL in enumerator {
        if shouldSkipPackageSearchDirectory(fileURL) {
          enumerator.skipDescendants()
          continue
        }

        guard fileURL.pathExtension == "swift" else { continue }
        guard let contents = try? String(contentsOf: fileURL) else { continue }

        let nsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex.firstMatch(in: contents, options: [], range: nsRange) else { continue }
        guard let matchRange = Range(match.range, in: contents) else { continue }

        let matchString = String(contents[matchRange])
        let kindKeyword = matchString.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "type"

        guard let typeNameRange = matchString.range(of: typeName) else { continue }

        let typeNameIndex = contents.index(
          matchRange.lowerBound,
          offsetBy: matchString.distance(from: matchString.startIndex, to: typeNameRange.lowerBound),
        )

        let position = lineAndColumn(in: contents, at: typeNameIndex)
        let snippet = lineSnippet(in: contents, line: position.line)

        candidates.append(TypeDeclarationCandidate(
          kindKeyword: kindKeyword,
          filePath: fileURL.path,
          line: position.line,
          column: position.column,
          lineSnippet: snippet ?? matchString,
        ))

        if candidates.count >= maximumCandidates {
          break
        }
      }
    }

    return candidates
  }

  private func lineAndColumn(in contents: String, at index: String.Index) -> (line: Int, column: Int) {
    let prefix = contents[..<index]
    let line = prefix.reduce(into: 1) { partialResult, character in
      if character == "\n" { partialResult += 1 }
    }

    let lastNewlineIndex = prefix.lastIndex(of: "\n")
    let lineStartIndex = lastNewlineIndex.map { prefix.index(after: $0) } ?? prefix.startIndex
    let column = prefix.distance(from: lineStartIndex, to: index) + 1

    return (line: line, column: max(column, 1))
  }

  private func lineSnippet(in contents: String, line: Int) -> String? {
    guard line > 0 else { return nil }

    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    let index = line - 1
    guard index >= 0, index < lines.count else { return nil }

    return String(lines[index])
  }
}
