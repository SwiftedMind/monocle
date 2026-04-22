// By Dennis Müller

import Foundation

/// Represents the workspace context used to drive SourceKit-LSP.
public struct Workspace: Equatable, Hashable, Sendable, Codable {
  /// Categorizes the workspace layout so SourceKit-LSP can be configured correctly.
  public enum Kind: String, Sendable, Codable {
    /// A Swift Package Manager workspace rooted by a `Package.swift` manifest.
    case swiftPackage
    /// A single Xcode project contained in an `.xcodeproj` bundle.
    case xcodeProject
    /// An Xcode workspace contained in an `.xcworkspace` bundle.
    case xcodeWorkspace
    /// A workspace using a compilation database (`compile_commands.json` or `compile_flags.txt`).
    case compilationDatabase
  }

  /// Absolute path to the workspace root directory.
  public var rootPath: String
  /// Resolved workspace kind used to pick SourceKit-LSP configuration.
  public var kind: Kind

  /// Creates a workspace description from a root path and detected kind.
  ///
  /// - Parameters:
  ///   - rootPath: Absolute path to the workspace root.
  ///   - kind: Workspace layout that determines how SourceKit-LSP should start.
  public init(rootPath: String, kind: Kind) {
    self.rootPath = rootPath
    self.kind = kind
  }
}
