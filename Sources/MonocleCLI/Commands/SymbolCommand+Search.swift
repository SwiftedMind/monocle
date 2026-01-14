// By Dennis Müller

import Foundation
import MonocleCore

extension SymbolCommand {
  struct SymbolSearchOutput {
    var results: [SymbolSearchResult]
    var rankedResults: [RankedSymbolSearchResult]
  }

  func performSymbolSearch(workspace: Workspace) async throws -> SymbolSearchOutput {
    guard limit > 0 else {
      return SymbolSearchOutput(results: [], rankedResults: [])
    }

    let candidateLimit = candidateLimit(for: limit, enrich: enrich)
    let baseResults = try await searchSymbols(
      in: workspace.rootPath,
      query: query,
      limit: candidateLimit,
      enrich: enrich,
    )

    let augmentedResults = try await augmentWithCheckedOutPackageSymbolsIfNeeded(
      results: baseResults,
      workspace: workspace,
      candidateLimit: candidateLimit,
    )

    let deduplicatedResults = deduplicating(augmentedResults)
    let ranker = SymbolSearchRanker(
      query: query,
      scope: scope,
      preference: prefer,
      requireExactMatch: exact,
    )

    var rankedResults = ranker.rank(results: deduplicatedResults, workspaceRootPath: workspace.rootPath)
    if rankedResults.count > limit {
      rankedResults = Array(rankedResults.prefix(limit))
    }

    let resolvedContextLines = max(contextLines, 0)
    if resolvedContextLines > 0 {
      rankedResults = applyContextLines(to: rankedResults, contextLines: resolvedContextLines)
    }

    let results = rankedResults.map(\.result)
    return SymbolSearchOutput(results: results, rankedResults: rankedResults)
  }

  private func candidateLimit(for userLimit: Int, enrich: Bool) -> Int {
    let baseLimit = enrich ? max(userLimit * 3, 20) : max(userLimit * 20, 50)
    let upperBound = enrich ? 120 : 500
    return min(baseLimit, upperBound)
  }

  private func augmentWithCheckedOutPackageSymbolsIfNeeded(
    results: [SymbolSearchResult],
    workspace: Workspace,
    candidateLimit: Int,
  ) async throws -> [SymbolSearchResult] {
    let deduplicatedResults = deduplicating(results)
    if scope == .project {
      return deduplicatedResults
    }

    if scope != .package, resultsContainExactTypeMatch(results: deduplicatedResults) {
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

    let packageLimit = min(max(candidateLimit, 20), 50)
    var additionalResults: [SymbolSearchResult] = []
    for package in candidatePackages {
      let packageResults = try await searchSymbols(
        in: package.checkoutPath,
        query: query,
        limit: packageLimit,
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

  private func applyContextLines(
    to results: [RankedSymbolSearchResult],
    contextLines: Int,
  ) -> [RankedSymbolSearchResult] {
    results.map { ranked in
      guard var location = ranked.result.location else { return ranked }
      guard location.uri.isFileURL else { return ranked }
      guard let snippet = contextSnippet(
        filePath: location.uri.path,
        line: location.startLine,
        contextLines: contextLines,
      ) else {
        return ranked
      }

      var updatedResult = ranked.result
      location.snippet = snippet
      updatedResult.location = location

      var updatedRanked = ranked
      updatedRanked.result = updatedResult
      return updatedRanked
    }
  }

  private func contextSnippet(filePath: String, line: Int, contextLines: Int) -> String? {
    guard contextLines >= 0 else { return nil }
    guard let contents = try? String(contentsOfFile: filePath) else { return nil }

    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    guard line > 0, line <= lines.count else { return nil }

    let startIndex = max(line - contextLines - 1, 0)
    let endIndex = min(line + contextLines - 1, lines.count - 1)
    let width = String(endIndex + 1).count

    return (startIndex...endIndex).map { index in
      let number = String(format: "%\(width)d", index + 1)
      return "\(number) | \(lines[index])"
    }.joined(separator: "\n")
  }
}
