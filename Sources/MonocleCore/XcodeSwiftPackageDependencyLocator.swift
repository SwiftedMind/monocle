// By Dennis Müller

import Foundation

/// Locates Swift package dependencies referenced by an Xcode project/workspace.
///
/// `workspace/symbol` results are often limited to the main project target graph when running SourceKit-LSP in
/// build-server mode. Editors usually have additional indexing state, but monocle runs in a clean process.
/// For that reason, monocle may need to explicitly search dependency packages as SwiftPM workspaces.
public enum XcodeSwiftPackageDependencyLocator {
  /// Returns local Swift package dependency roots referenced by the Xcode workspace/project.
  ///
  /// This reads Xcode's `Package.resolved` file and returns only dependencies that resolve to local paths.
  ///
  /// - Parameter workspace: Workspace describing the Xcode root.
  /// - Returns: Absolute filesystem paths for local package roots.
  public static func localPackageRootPaths(for workspace: Workspace) -> [String] {
    guard workspace.kind == .xcodeProject || workspace.kind == .xcodeWorkspace else { return [] }
    guard let packageResolvedURL = locatePackageResolvedFileURL(for: workspace) else { return [] }
    guard let data = try? Data(contentsOf: packageResolvedURL) else { return [] }

    if let version2 = try? JSONDecoder().decode(PackageResolvedVersion2.self, from: data) {
      return normalizeLocalPackagePaths(version2.pins.compactMap(\.location))
    }

    if let version1 = try? JSONDecoder().decode(PackageResolvedVersion1.self, from: data) {
      return normalizeLocalPackagePaths(version1.object.pins.compactMap(\.repositoryURL))
    }

    return []
  }

  private static func locatePackageResolvedFileURL(for workspace: Workspace) -> URL? {
    let rootURL = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
    let fileManager = FileManager.default

    switch workspace.kind {
    case .xcodeWorkspace:
      let workspaceURLs = matchingChildURLs(in: rootURL, withExtension: "xcworkspace", fileManager: fileManager)
      guard workspaceURLs.count == 1, let workspaceURL = workspaceURLs.first else { return nil }

      let candidate = workspaceURL
        .appendingPathComponent("xcshareddata", isDirectory: true)
        .appendingPathComponent("swiftpm", isDirectory: true)
        .appendingPathComponent("Package.resolved")
      if fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
      return nil

    case .xcodeProject:
      let projectURLs = matchingChildURLs(in: rootURL, withExtension: "xcodeproj", fileManager: fileManager)
      guard projectURLs.count == 1, let projectURL = projectURLs.first else { return nil }

      let candidate = projectURL
        .appendingPathComponent("project.xcworkspace", isDirectory: true)
        .appendingPathComponent("xcshareddata", isDirectory: true)
        .appendingPathComponent("swiftpm", isDirectory: true)
        .appendingPathComponent("Package.resolved")
      if fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
      return nil

    case .swiftPackage:
      return nil
    }
  }

  private static func matchingChildURLs(in directoryURL: URL, withExtension fileExtension: String,
                                        fileManager: FileManager) -> [URL] {
    let contents = (try? fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles],
    )) ?? []
    return contents.filter { $0.pathExtension == fileExtension }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func normalizeLocalPackagePaths(_ rawLocations: [String]) -> [String] {
    let fileManager = FileManager.default

    let normalized: [String] = rawLocations.compactMap { location in
      if location.hasPrefix("file://"), let url = URL(string: location), url.isFileURL {
        return url.path
      }

      if location.hasPrefix("/") {
        return location
      }

      return nil
    }.map { FilePathResolver.absolutePath(for: $0) }

    let existingPackageRoots = normalized.filter { path in
      fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("Package.swift").path)
    }

    return Array(Set(existingPackageRoots)).sorted()
  }

  private struct PackageResolvedVersion2: Codable {
    var pins: [Pin]

    struct Pin: Codable {
      var location: String?
    }
  }

  private struct PackageResolvedVersion1: Codable {
    var object: ResolvedObject

    struct ResolvedObject: Codable {
      var pins: [Pin]
    }

    struct Pin: Codable {
      var repositoryURL: String?
    }
  }
}
