import ArgumentParser
import Foundation
import MonocleCore

struct HoverCommand: AsyncParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "hover",
      abstract: "Fetch signature and documentation for a Swift symbol."
    )
  }
  
  @Option(name: [.customShort("w"), .long], help: "Workspace root path (Package.swift or Xcode project/workspace directory).")
  var workspace: String?
  
  @Option(name: .long, help: "Swift source file path.")
  var file: String
  
  @Option(name: .long, help: "One-based line number of the symbol position.")
  var line: Int
  
  @Option(name: [.customShort("c"), .long], help: "One-based column number of the symbol position.")
  var column: Int
  
  @Flag(name: .long, help: "Emit JSON output instead of human-readable text.")
  var json: Bool = false
  
  mutating func run() async throws {
    let workspaceDescription = try WorkspaceLocator.locate(explicitWorkspacePath: workspace, filePath: file)
    let session = try LspSession(workspace: workspaceDescription)
    let info = try await session.hover(file: file, line: line, column: column)
    
    if json {
      try printJSON(info)
    } else {
      HumanReadablePrinter.printSymbolInfo(info)
    }
  }
  
  private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
      throw MonocleError.ioError("Unable to encode JSON output.")
    }
    print(output)
  }
}
