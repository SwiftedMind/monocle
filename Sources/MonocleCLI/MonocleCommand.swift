// By Dennis Müller

import ArgumentParser
import MonocleCore

/// Root command that wires up all monocle subcommands.
struct MonocleCommand: AsyncParsableCommand {
  /// Version string shown when invoking `monocle --version`.
  private static let versionDescription: String = {
    let sourceKitVersion = (try? SourceKitService.detectSourceKitVersion()) ?? "unknown"
    return "monocle \(toolVersion)\nSourceKit-LSP: \(sourceKitVersion)"
  }()

  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "monocle",
      abstract: "Inspect Swift symbols using SourceKit-LSP.",
      discussion: """
      A read-only CLI that resolves Swift symbols at a specific file, line, and column using SourceKit-LSP. It returns definition locations, signatures, and documentation in human-readable or JSON form, and can run a persistent daemon to keep lookups fast.
      """,
      version: versionDescription,
      subcommands: [
        InspectCommand.self,
        DefinitionCommand.self,
        HoverCommand.self,
        StatusCommand.self,
        ServeCommand.self,
        StopCommand.self,
      ],
      defaultSubcommand: InspectCommand.self,
    )
  }
}
