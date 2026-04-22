// By Dennis Müller

import Foundation

/// Locates a workspace starting from a file path and optional explicit hint.
public enum WorkspaceLocator {
  /// Attempts to locate a workspace for the provided Swift source file.
  /// - Parameters:
  ///   - explicitWorkspacePath: Optional explicit workspace root to prefer.
  ///   - filePath: Swift source file path or directory path used as a starting point.
  /// - Returns: A `Workspace` representing the detected root.
  /// - Throws: `MonocleError.workspaceNotFound` when no workspace is discovered.
  public static func locate(explicitWorkspacePath: String?, filePath: String) throws -> Workspace {
    if let explicitPath = explicitWorkspacePath {
      return try classifyWorkspace(at: explicitPath)
    }

    var currentURL = startingDirectory(for: filePath)
    let fileManager = FileManager.default

    while true {
      if let workspace = try locateXcodeWorkspace(in: currentURL, fileManager: fileManager) {
        return workspace
      }

      if let project = try locateXcodeProject(in: currentURL, fileManager: fileManager) {
        return project
      }

      if fileManager.fileExists(atPath: currentURL.appendingPathComponent("Package.swift").path) {
        return Workspace(rootPath: currentURL.path, kind: .swiftPackage)
      }

      if hasCompilationDatabase(in: currentURL, fileManager: fileManager) {
        return Workspace(rootPath: currentURL.path, kind: .compilationDatabase)
      }

      let parent = currentURL.deletingLastPathComponent()
      if parent.path == currentURL.path {
        throw MonocleError.workspaceNotFound
      }
      currentURL = parent
    }
  }

  /// Determines the workspace kind for an explicit path.
  ///
  /// - Parameter path: Path to a package root, `.xcodeproj`, or `.xcworkspace`.
  /// - Returns: A workspace description for the path.
  /// - Throws: `MonocleError.workspaceNotFound` when the path does not describe a workspace.
  private static func classifyWorkspace(at path: String) throws -> Workspace {
    let url = URL(fileURLWithPath: path)
    let fileManager = FileManager.default

    if url.lastPathComponent == "Package.swift" {
      return Workspace(rootPath: url.deletingLastPathComponent().path, kind: .swiftPackage)
    }

    // Treat explicit Xcode bundle paths as the workspace selection itself.
    // Xcode project bundles contain an internal `project.xcworkspace`; scanning inside would
    // incorrectly classify the bundle as a workspace rooted at the project package.
    if url.pathExtension == "xcodeproj" {
      return Workspace(rootPath: url.deletingLastPathComponent().path, kind: .xcodeProject)
    }

    if url.pathExtension == "xcworkspace" {
      return Workspace(rootPath: url.deletingLastPathComponent().path, kind: .xcodeWorkspace)
    }

    if isDirectory(path: path, fileManager: fileManager) {
      if let workspace = try locateXcodeWorkspace(in: url, fileManager: fileManager) {
        return workspace
      }
      if let project = try locateXcodeProject(in: url, fileManager: fileManager) {
        return project
      }
      if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return Workspace(rootPath: url.path, kind: .swiftPackage)
      }
      if hasCompilationDatabase(in: url, fileManager: fileManager) {
        return Workspace(rootPath: url.path, kind: .compilationDatabase)
      }
    }

    if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
      return Workspace(rootPath: url.path, kind: .swiftPackage)
    }

    if hasCompilationDatabase(in: url, fileManager: fileManager) {
      return Workspace(rootPath: url.path, kind: .compilationDatabase)
    }

    throw MonocleError.workspaceNotFound
  }

  /// Returns the directory used as the starting point for discovery.
  ///
  /// - Parameter filePath: File or directory path provided by the caller.
  /// - Returns: A directory URL to begin searching from.
  private static func startingDirectory(for filePath: String) -> URL {
    let url = URL(fileURLWithPath: filePath)
    if url.hasDirectoryPath {
      return url.standardizedFileURL
    }
    return url.deletingLastPathComponent().standardizedFileURL
  }

  /// Locates an Xcode workspace within the provided directory, preferring deterministic selection.
  ///
  /// - Parameters:
  ///   - directory: Directory to search.
  ///   - fileManager: File manager used for the query.
  /// - Returns: A `Workspace` when exactly one workspace is present, or `nil` when absent.
  /// - Throws: `MonocleError.workspaceAmbiguous` when multiple workspaces are found.
  private static func locateXcodeWorkspace(in directory: URL, fileManager: FileManager) throws -> Workspace? {
    if directory.pathExtension == "xcodeproj" || directory.pathExtension == "xcworkspace" {
      return nil
    }

    let workspaces = matches(in: directory, withExtension: "xcworkspace", fileManager: fileManager)

    if workspaces.count > 1 {
      throw MonocleError.workspaceAmbiguous(options: workspaces.map(\ .path))
    }

    guard let workspacePath = workspaces.first else { return nil }

    return Workspace(rootPath: workspacePath.deletingLastPathComponent().path, kind: .xcodeWorkspace)
  }

  /// Locates an Xcode project within the provided directory, preferring deterministic selection.
  ///
  /// - Parameters:
  ///   - directory: Directory to search.
  ///   - fileManager: File manager used for the query.
  /// - Returns: A `Workspace` when exactly one project is present, or `nil` when absent.
  /// - Throws: `MonocleError.workspaceAmbiguous` when multiple projects are found.
  private static func locateXcodeProject(in directory: URL, fileManager: FileManager) throws -> Workspace? {
    if directory.pathExtension == "xcodeproj" || directory.pathExtension == "xcworkspace" {
      return nil
    }

    let projects = matches(in: directory, withExtension: "xcodeproj", fileManager: fileManager)

    if projects.count > 1 {
      throw MonocleError.workspaceAmbiguous(options: projects.map(\ .path))
    }

    guard let projectPath = projects.first else { return nil }

    return Workspace(rootPath: projectPath.deletingLastPathComponent().path, kind: .xcodeProject)
  }

  /// Returns all child items within `directory` matching the provided extension, sorted for stability.
  ///
  /// - Parameters:
  ///   - directory: Directory to search.
  ///   - fileExtension: File extension to match, without the leading dot.
  ///   - fileManager: File manager used for the query.
  /// - Returns: Sorted URLs of matching paths.
  private static func matches(in directory: URL, withExtension fileExtension: String,
                              fileManager: FileManager) -> [URL] {
    let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return contents
      .filter { $0.pathExtension == fileExtension }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Determines whether the path represents a directory on disk.
  ///
  /// - Parameters:
  ///   - path: Filesystem path to test.
  ///   - fileManager: File manager used for the query.
  /// - Returns: `true` when the path exists and is a directory.
  private static func isDirectory(path: String, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }

    return isDirectory.boolValue
  }

  /// Checks whether a directory contains a compilation database or compile flags file.
  ///
  /// - Parameters:
  ///   - directory: Directory to inspect.
  ///   - fileManager: File manager used for the query.
  /// - Returns: `true` when `compile_commands.json` or `compile_flags.txt` exists.
  private static func hasCompilationDatabase(in directory: URL, fileManager: FileManager) -> Bool {
    let candidates = ["compile_commands.json", "compile_flags.txt"]
    return candidates.contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
  }
}
