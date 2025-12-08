import Foundation

/// Describes an optional custom toolchain configuration.
public struct ToolchainConfiguration {
  public var developerDirectory: String?
  public var sourceKitPath: String?
  
  public init(developerDirectory: String? = nil, sourceKitPath: String? = nil) {
    self.developerDirectory = developerDirectory
    self.sourceKitPath = sourceKitPath
  }
}
