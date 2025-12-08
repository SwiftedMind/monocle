import Foundation

/// Represents the workspace context used to drive SourceKit-LSP.
public struct Workspace: Equatable, Hashable {
  public enum Kind: String {
    case swiftPackage
    case xcodeProject
    case xcodeWorkspace
  }
  
  public var rootPath: String
  public var kind: Kind
  
  public init(rootPath: String, kind: Kind) {
    self.rootPath = rootPath
    self.kind = kind
  }
}
