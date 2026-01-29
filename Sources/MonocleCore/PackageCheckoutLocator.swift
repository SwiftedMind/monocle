// By Dennis Müller

import Foundation

/// Represents a Swift Package Manager dependency that has been checked out on disk.
public struct PackageCheckout: Equatable, Hashable, Sendable, Codable {
  /// Package directory name under the checkouts folder.
  public var packageName: String
  /// Absolute path to the checked-out package directory.
  public var checkoutPath: String
  /// Absolute path to the package README file when present.
  public var readmePath: String?

  /// Creates a package checkout description.
  ///
  /// - Parameters:
  ///   - packageName: Package directory name.
  ///   - checkoutPath: Absolute path to the checkout directory.
  ///   - readmePath: Absolute path to the README file, when present.
  public init(packageName: String, checkoutPath: String, readmePath: String?) {
    self.packageName = packageName
    self.checkoutPath = checkoutPath
    self.readmePath = readmePath
  }
}

/// Locates checked-out SwiftPM dependencies for a workspace without invoking SourceKit-LSP.
public enum PackageCheckoutLocator {
  /// Returns all Swift packages checked out for the given workspace.
  ///
  /// For Xcode projects/workspaces, this uses `buildServer.json` to determine the exact DerivedData
  /// `build_root`, then scans `SourcePackages/checkouts`.
  ///
  /// For pure SwiftPM packages, this scans `.build/checkouts` in the workspace root.
  ///
  /// - Parameter workspace: Workspace to inspect.
  /// - Returns: Sorted list of checked-out packages.
  /// - Throws: `MonocleError.buildServerConfigurationMissing` when an Xcode workspace lacks `buildServer.json`.
  /// - Throws: `MonocleError.ioError` when the build server configuration cannot be read or decoded.
  public static func checkedOutPackages(in workspace: Workspace) throws -> [PackageCheckout] {
    let checkoutsRootURL = try checkoutsRootURL(for: workspace)
    let packageDirectories = listChildDirectories(at: checkoutsRootURL)

    let packages: [PackageCheckout] = packageDirectories.map { packageDirectory in
      let packageName = packageDirectory.lastPathComponent
      let checkoutPath = packageDirectory.resolvingSymlinksInPath().standardizedFileURL.path
      let readmeURL = locateReadme(in: packageDirectory)
      let readmePath = readmeURL?.resolvingSymlinksInPath().standardizedFileURL.path
      return PackageCheckout(packageName: packageName, checkoutPath: checkoutPath, readmePath: readmePath)
    }

    return packages.sorted { $0.packageName.localizedStandardCompare($1.packageName) == .orderedAscending }
  }

  private static func checkoutsRootURL(for workspace: Workspace) throws -> URL {
    switch workspace.kind {
    case .swiftPackage:
      return URL(fileURLWithPath: workspace.rootPath).appendingPathComponent(".build/checkouts", isDirectory: true)
    case .xcodeProject, .xcodeWorkspace:
      // Check for Tuist-managed dependencies first
      if let tuistCheckoutsURL = tuistCheckoutsRootURL(inWorkspaceRoot: workspace.rootPath) {
        return tuistCheckoutsURL
      }
      let buildRootPath = try buildRootPath(fromWorkspaceRootPath: workspace.rootPath)
      return try xcodeCheckoutsRootURL(fromBuildRootPath: buildRootPath)
    }
  }

  /// Checks for Tuist-managed SwiftPM dependencies.
  ///
  /// Tuist stores dependencies at `<project-root>/Tuist/.build/checkouts/` instead of Xcode's DerivedData.
  private static func tuistCheckoutsRootURL(inWorkspaceRoot workspaceRootPath: String) -> URL? {
    let fileManager = FileManager.default
    let tuistCheckoutsURL = URL(fileURLWithPath: workspaceRootPath)
      .appendingPathComponent("Tuist/.build/checkouts", isDirectory: true)

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: tuistCheckoutsURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      return nil
    }

    return tuistCheckoutsURL
  }

  private static func buildRootPath(fromWorkspaceRootPath workspaceRootPath: String) throws -> String {
    let buildServerURL = URL(fileURLWithPath: workspaceRootPath).appendingPathComponent("buildServer.json")
    guard FileManager.default.fileExists(atPath: buildServerURL.path) else {
      throw MonocleError.buildServerConfigurationMissing(workspaceRootPath: workspaceRootPath)
    }

    let buildServerData: Data
    do {
      buildServerData = try Data(contentsOf: buildServerURL)
    } catch {
      throw MonocleError.ioError("Unable to read buildServer.json: \(error.localizedDescription)")
    }

    let configuration: BuildServerConfiguration
    do {
      configuration = try JSONDecoder().decode(BuildServerConfiguration.self, from: buildServerData)
    } catch {
      throw MonocleError.ioError("Unable to decode buildServer.json: \(error.localizedDescription)")
    }

    guard let buildRootPath = configuration.buildRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
          buildRootPath.isEmpty == false
    else {
      throw MonocleError.ioError("buildServer.json is missing a valid \"build_root\" value.")
    }

    return FilePathResolver.absolutePath(for: buildRootPath)
  }

  private static func xcodeCheckoutsRootURL(fromBuildRootPath buildRootPath: String) throws -> URL {
    let fileManager = FileManager.default
    let buildRootURL = URL(fileURLWithPath: buildRootPath, isDirectory: true)

    let candidateBaseURLs: [URL] = {
      var bases: [URL] = []
      if buildRootURL.lastPathComponent == "Build" {
        bases.append(buildRootURL.deletingLastPathComponent())
      }
      bases.append(buildRootURL)
      return bases
    }()

    var candidateCheckoutsURLs: [URL] = []
    for baseURL in candidateBaseURLs {
      for parentDepth in 0...3 {
        var currentBaseURL = baseURL
        if parentDepth > 0 {
          for _ in 0..<parentDepth {
            let parent = currentBaseURL.deletingLastPathComponent()
            if parent.path == currentBaseURL.path {
              break
            }
            currentBaseURL = parent
          }
        }

        candidateCheckoutsURLs.append(
          currentBaseURL.appendingPathComponent("SourcePackages/checkouts", isDirectory: true),
        )
      }
    }

    for candidateURL in candidateCheckoutsURLs {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return candidateURL
      }
    }

    let triedPaths = candidateCheckoutsURLs.map(\.path).joined(separator: "\n- ")
    throw MonocleError.ioError(
      """
      Unable to locate Xcode SwiftPM checkouts directory.

      build_root: \(buildRootPath)

      Tried:
      - \(triedPaths)
      """,
    )
  }

  private static func listChildDirectories(at directoryURL: URL) -> [URL] {
    let fileManager = FileManager.default
    let urls = (try? fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles],
    )) ?? []

    return urls.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
  }

  private static func locateReadme(in packageDirectory: URL) -> URL? {
    let fileManager = FileManager.default

    let preferredReadmeFilenames: [String] = [
      "README.md",
      "README.markdown",
      "README.rst",
    ]

    for filename in preferredReadmeFilenames {
      let candidate = packageDirectory.appendingPathComponent(filename)
      if fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    let contents = (try? fileManager.contentsOfDirectory(
      at: packageDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles],
    )) ?? []

    let caseInsensitiveCandidate = contents.first { url in
      url.lastPathComponent.lowercased().hasPrefix("readme")
    }

    return caseInsensitiveCandidate
  }

  private struct BuildServerConfiguration: Codable {
    var buildRoot: String?

    enum CodingKeys: String, CodingKey {
      case buildRoot = "build_root"
    }
  }
}
