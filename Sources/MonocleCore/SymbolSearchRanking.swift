// By Dennis Müller

import Foundation

public enum SymbolSearchScope: String, Sendable, Codable {
  case all
  case project
  case package
}

public enum SymbolSearchSourcePreference: String, Sendable, Codable {
  case project
  case package
  case none
}

public enum SymbolSearchSourceKind: String, Sendable, Codable {
  case project
  case package
  case other
}

public struct SymbolSearchSource: Sendable, Codable, Equatable {
  public var kind: SymbolSearchSourceKind
  public var packageName: String?
  public var isDerivedData: Bool

  public init(kind: SymbolSearchSourceKind, packageName: String? = nil, isDerivedData: Bool = false) {
    self.kind = kind
    self.packageName = packageName
    self.isDerivedData = isDerivedData
  }
}

public struct RankedSymbolSearchResult: Sendable, Codable {
  public var result: SymbolSearchResult
  public var source: SymbolSearchSource
  public var score: Int
  public var isExactMatch: Bool

  public init(result: SymbolSearchResult, source: SymbolSearchSource, score: Int, isExactMatch: Bool) {
    self.result = result
    self.source = source
    self.score = score
    self.isExactMatch = isExactMatch
  }
}

public struct SymbolSearchRanker: Sendable {
  public var query: String
  public var scope: SymbolSearchScope
  public var preference: SymbolSearchSourcePreference
  public var requireExactMatch: Bool

  public init(
    query: String,
    scope: SymbolSearchScope = .all,
    preference: SymbolSearchSourcePreference = .project,
    requireExactMatch: Bool = false,
  ) {
    self.query = query
    self.scope = scope
    self.preference = preference
    self.requireExactMatch = requireExactMatch
  }

  public func rank(results: [SymbolSearchResult], workspaceRootPath: String) -> [RankedSymbolSearchResult] {
    guard results.isEmpty == false else { return [] }

    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let rootPath = URL(fileURLWithPath: workspaceRootPath).resolvingSymlinksInPath().standardizedFileURL.path

    var ranked: [(index: Int, entry: RankedSymbolSearchResult)] = []
    ranked.reserveCapacity(results.count)

    for (index, result) in results.enumerated() {
      let path = resultPath(for: result)
      let source = classifySource(for: path, workspaceRootPath: rootPath)

      if !matchesScope(source: source) {
        continue
      }

      let isExact = isExactMatch(name: result.name, normalizedQuery: normalizedQuery)
      if requireExactMatch, !isExact {
        continue
      }

      let score = score(
        for: result.name,
        normalizedQuery: normalizedQuery,
        source: source,
        path: path,
      )

      ranked.append((
        index: index,
        entry: RankedSymbolSearchResult(
          result: result,
          source: source,
          score: score,
          isExactMatch: isExact,
        ),
      ))
    }

    ranked.sort { lhs, rhs in
      if lhs.entry.score != rhs.entry.score {
        return lhs.entry.score > rhs.entry.score
      }
      if lhs.entry.isExactMatch != rhs.entry.isExactMatch {
        return lhs.entry.isExactMatch && !rhs.entry.isExactMatch
      }
      return lhs.index < rhs.index
    }

    return ranked.map(\.entry)
  }

  private func matchesScope(source: SymbolSearchSource) -> Bool {
    switch scope {
    case .all:
      true
    case .project:
      source.kind == .project
    case .package:
      source.kind == .package
    }
  }

  private func score(
    for name: String,
    normalizedQuery: String,
    source: SymbolSearchSource,
    path: String?,
  ) -> Int {
    var score = matchQualityScore(name: name, normalizedQuery: normalizedQuery)

    if isMangled(name: name) {
      score -= 400
    }

    if isTestPath(path) {
      score -= 100
    }

    switch preference {
    case .project:
      if source.kind == .project { score += 50 }
    case .package:
      if source.kind == .package { score += 50 }
    case .none:
      break
    }

    return score
  }

  private func matchQualityScore(name: String, normalizedQuery: String) -> Int {
    guard normalizedQuery.isEmpty == false else { return 0 }

    let normalizedName = name.lowercased()
    if normalizedName == normalizedQuery {
      return 1000
    }

    let lastComponent = normalizedName.split(separator: ".").last.map(String.init) ?? normalizedName
    if lastComponent == normalizedQuery {
      return 950
    }

    if normalizedName.hasPrefix(normalizedQuery) {
      return 800
    }

    if lastComponent.hasPrefix(normalizedQuery) {
      return 750
    }

    if normalizedName.contains(normalizedQuery) {
      return 600
    }

    return 0
  }

  private func isExactMatch(name: String, normalizedQuery: String) -> Bool {
    guard normalizedQuery.isEmpty == false else { return false }

    let normalizedName = name.lowercased()
    if normalizedName == normalizedQuery {
      return true
    }

    let lastComponent = normalizedName.split(separator: ".").last.map(String.init) ?? normalizedName
    return lastComponent == normalizedQuery
  }

  private func resultPath(for result: SymbolSearchResult) -> String? {
    if let location = result.location {
      if location.uri.isFileURL {
        return location.uri.path
      }
      return location.uri.absoluteString
    }

    if let documentURI = result.documentURI {
      if documentURI.isFileURL {
        return documentURI.path
      }
      return documentURI.absoluteString
    }

    return nil
  }

  private func classifySource(for path: String?, workspaceRootPath: String) -> SymbolSearchSource {
    guard let path else {
      return SymbolSearchSource(kind: .other)
    }

    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let isDerivedData = standardizedPath.contains("/DerivedData/")

    // Check for package markers first, before workspace root check.
    // This handles Tuist projects where packages live inside the workspace at Tuist/.build/checkouts/.
    if let packageName = packageName(from: standardizedPath) {
      return SymbolSearchSource(kind: .package, packageName: packageName, isDerivedData: isDerivedData)
    }

    if standardizedPath.contains("/SourcePackages/") || standardizedPath.contains("/.build/checkouts/") || isDerivedData {
      return SymbolSearchSource(kind: .package, isDerivedData: isDerivedData)
    }

    if standardizedPath == workspaceRootPath || standardizedPath.hasPrefix("\(workspaceRootPath)/") {
      return SymbolSearchSource(kind: .project, isDerivedData: isDerivedData)
    }

    return SymbolSearchSource(kind: .other, isDerivedData: isDerivedData)
  }

  private func packageName(from path: String) -> String? {
    if let name = extractPackageName(path: path, marker: "/SourcePackages/checkouts/") {
      return name
    }

    if let name = extractPackageName(path: path, marker: "/.build/checkouts/") {
      return name
    }

    return nil
  }

  private func extractPackageName(path: String, marker: String) -> String? {
    guard let markerRange = path.range(of: marker) else { return nil }

    let remainder = path[markerRange.upperBound...]
    guard let slashIndex = remainder.firstIndex(of: "/") else {
      return remainder.isEmpty ? nil : String(remainder)
    }

    return String(remainder[..<slashIndex])
  }

  private func isMangled(name: String) -> Bool {
    name.hasPrefix("$s") || name.hasPrefix("$S")
  }

  private func isTestPath(_ path: String?) -> Bool {
    guard let path else { return false }

    if path.contains("/Tests/") { return true }
    if path.contains(".xctest/") { return true }
    return false
  }
}
