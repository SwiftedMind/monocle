// By Dennis Müller

import ArgumentParser

struct MonocleCommand: AsyncParsableCommand {
  static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "monocle",
      abstract: "Inspect Swift symbols using SourceKit-LSP.",
      discussion: """
      A read-only CLI that resolves Swift symbols at a specific file, line, and column using SourceKit-LSP. It returns definition locations, signatures, and documentation in human-readable or JSON form, and can run a persistent daemon to keep lookups fast.
      """,
      subcommands: [
        InspectCommand.self,
        DefinitionCommand.self,
        HoverCommand.self,
        StatusCommand.self,
        ServeCommand.self,
        StopCommand.self,
        VersionCommand.self,
      ],
      defaultSubcommand: InspectCommand.self,
    )
  }
}
