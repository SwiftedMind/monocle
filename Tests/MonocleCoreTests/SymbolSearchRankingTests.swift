// By Dennis Müller

import Foundation
import MonocleCore
import Testing

final class SymbolSearchRankingTests {
  @Test func exactMatchRanksAboveFuzzyResults() {
    let workspaceRoot = "/Workspace"
    let projectLocation = SymbolInfo.Location(
      uri: URL(fileURLWithPath: "/Workspace/Components/SymbolViewCardHeader.swift"),
      startLine: 48,
      startCharacter: 1,
      endLine: 48,
      endCharacter: 10,
      snippet: nil,
    )

    let packageLocation = SymbolInfo.Location(
      uri: URL(
        fileURLWithPath: "/DerivedData/Example/SourcePackages/checkouts/Tessera/Sources/Tessera/TesseraPlacement.swift",
      ),
      startLine: 6,
      startCharacter: 1,
      endLine: 6,
      endCharacter: 10,
      snippet: nil,
    )

    let mangledLocation = SymbolInfo.Location(
      uri: URL(fileURLWithPath: "/Workspace/Tests/ScalingHelpersTests.swift"),
      startLine: 26,
      startCharacter: 1,
      endLine: 26,
      endCharacter: 10,
      snippet: nil,
    )

    let results: [SymbolSearchResult] = [
      SymbolSearchResult(
        name: "init(title:iconName:iconColor:)",
        kind: "initializer",
        containerName: "SymbolViewCardHeader",
        location: projectLocation,
        documentURI: projectLocation.uri,
      ),
      SymbolSearchResult(
        name: "$s22Tessera_Designer_Tests014ScalingHelpersC0V44symbolLocalViewTransformMapsCornersAndCenter4TestfMp_25generator300b730e913b3e62fMu_()",
        kind: "method",
        containerName: "ScalingHelpersTests",
        location: mangledLocation,
        documentURI: mangledLocation.uri,
      ),
      SymbolSearchResult(
        name: "TesseraPlacement",
        kind: "enum",
        containerName: nil,
        location: packageLocation,
        documentURI: packageLocation.uri,
      ),
    ]

    let ranker = SymbolSearchRanker(query: "TesseraPlacement")
    let ranked = ranker.rank(results: results, workspaceRootPath: workspaceRoot)

    #expect(ranked.first?.result.name == "TesseraPlacement")
  }

  @Test func scopeFiltersToProjectResults() {
    let workspaceRoot = "/Workspace"
    let projectLocation = SymbolInfo.Location(
      uri: URL(fileURLWithPath: "/Workspace/Sources/App/AppModel.swift"),
      startLine: 10,
      startCharacter: 1,
      endLine: 10,
      endCharacter: 10,
      snippet: nil,
    )

    let packageLocation = SymbolInfo.Location(
      uri: URL(
        fileURLWithPath: "/DerivedData/Example/SourcePackages/checkouts/Tessera/Sources/Tessera/TesseraPlacement.swift",
      ),
      startLine: 6,
      startCharacter: 1,
      endLine: 6,
      endCharacter: 10,
      snippet: nil,
    )

    let results: [SymbolSearchResult] = [
      SymbolSearchResult(name: "AppModel", kind: "class", location: projectLocation, documentURI: projectLocation.uri),
      SymbolSearchResult(
        name: "TesseraPlacement",
        kind: "enum",
        location: packageLocation,
        documentURI: packageLocation.uri,
      ),
    ]

    let ranker = SymbolSearchRanker(query: "App", scope: .project, preference: .project)
    let ranked = ranker.rank(results: results, workspaceRootPath: workspaceRoot)

    #expect(ranked.count == 1)
    #expect(ranked.first?.source.kind == .project)
  }

  @Test func extractsPackageNameFromCheckoutsPath() {
    let workspaceRoot = "/Workspace"
    let packageLocation = SymbolInfo.Location(
      uri: URL(
        fileURLWithPath: "/DerivedData/Example/SourcePackages/checkouts/Tessera/Sources/Tessera/TesseraPlacement.swift",
      ),
      startLine: 6,
      startCharacter: 1,
      endLine: 6,
      endCharacter: 10,
      snippet: nil,
    )

    let results: [SymbolSearchResult] = [
      SymbolSearchResult(
        name: "TesseraPlacement",
        kind: "enum",
        location: packageLocation,
        documentURI: packageLocation.uri,
      ),
    ]

    let ranker = SymbolSearchRanker(query: "TesseraPlacement")
    let ranked = ranker.rank(results: results, workspaceRootPath: workspaceRoot)

    #expect(ranked.first?.source.kind == .package)
    #expect(ranked.first?.source.packageName == "Tessera")
  }
}
