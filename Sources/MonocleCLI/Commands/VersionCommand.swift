import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "version",
      abstract: "Show version information."
    )
  }
  
  func run() throws {
    let toolVersion = "0.1.0-mvp"
    let sourceKitVersion = "unavailable (stub)"
    print("monocle \(toolVersion)")
    print("SourceKit-LSP: \(sourceKitVersion)")
  }
}
