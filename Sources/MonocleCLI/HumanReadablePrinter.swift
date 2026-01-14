// By Dennis Müller

import Foundation
import MonocleCore

/// Renders SymbolInfo and daemon status results in a human-friendly format.
enum HumanReadablePrinter {
  /// Prints symbol information to stdout in a readable layout.
  ///
  /// - Parameter info: Symbol description returned by monocle.
  static func printSymbolInfo(_ info: SymbolInfo) {
    if let symbolName = info.symbol {
      print("Symbol: \(symbolName)")
    }
    if let kind = info.kind {
      print("Kind: \(kind)")
    }
    if let module = info.module {
      print("Module: \(module)")
    }
    if let signature = info.signature {
      print("\nSignature:\n\(signature)")
    }
    if let definition = info.definition {
      print("\nDefinition: \(definition.uri.absoluteString):\(definition.startLine)-\(definition.endLine)")
      if let snippet = definition.snippet {
        print("\nSnippet:\n\(snippet)")
      }
    }
    if let documentation = info.documentation {
      print("\nDocumentation:\n\(documentation)")
    }

    if info.symbol == nil, info.signature == nil, info.documentation == nil {
      print("Symbol resolution is not implemented yet.")
    }
  }

  /// Prints daemon status details to stdout.
  ///
  /// - Parameter status: Daemon status payload returned by the server.
  static func printDaemonStatus(_ status: DaemonStatus) {
    print("Daemon socket: \(status.socketPath)")
    print("Daemon PID: \(status.daemonProcessIdentifier)")
    print("Idle session timeout: \(status.idleSessionTimeoutSeconds)s")
    print("Logs: \(status.logFilePath)")
    if status.activeSessions.isEmpty {
      print("Active sessions: none")
      return
    }
    print("Active sessions (\(status.activeSessions.count)):")
    for session in status.activeSessions {
      print(" - \(session.workspaceRootPath) [\(session.kind.rawValue)] last used \(session.lastUsedISO8601)")
    }
  }

  /// Prints workspace symbol search results.
  ///
  /// - Parameter results: Symbol search results to display.
  static func printSymbolSearchResults(_ results: [RankedSymbolSearchResult]) {
    guard results.isEmpty == false else {
      print("No symbols found.")
      return
    }

    for (index, ranked) in results.enumerated() {
      let result = ranked.result
      var header = "[\(index + 1)] \(result.name)"
      if let container = result.containerName {
        header += " (\(container))"
      }
      if let kind = result.kind {
        header += " – \(kind)"
      }
      if let sourceLabel = sourceLabel(for: ranked.source) {
        header += " [\(sourceLabel)]"
      }
      print(header)

      if let location = result.location {
        let path = location.uri.isFileURL ? location.uri.path : location.uri.absoluteString
        print("    \(path):\(location.startLine)")
        if let snippet = location.snippet {
          printSnippet(snippet)
        }
      } else if let documentURI = result.documentURI {
        let path = documentURI.isFileURL ? documentURI.path : documentURI.absoluteString
        print("    \(path)")
      }
      if let signature = result.signature {
        print("    \(signature)")
      }
      if let documentation = result.documentation, documentation.isEmpty == false {
        print("    \(documentation)")
      }
    }
  }

  /// Prints checked-out Swift package dependencies.
  ///
  /// - Parameters:
  ///   - packages: Checked-out packages to display.
  ///   - workspace: Workspace that was scanned.
  static func printPackageCheckouts(_ packages: [PackageCheckout], workspace: Workspace) {
    print("Workspace: \(workspace.rootPath) [\(workspace.kind.rawValue)]")

    guard packages.isEmpty == false else {
      print("Checked-out packages: none")
      return
    }

    print("Checked-out packages (\(packages.count)):")
    for package in packages {
      var line = " - \(package.packageName): \(package.checkoutPath)"
      if let readmePath = package.readmePath {
        line += " (README: \(readmePath))"
      }
      print(line)
    }
  }

  private static func sourceLabel(for source: SymbolSearchSource) -> String? {
    switch source.kind {
    case .project:
      return "project"
    case .package:
      if let name = source.packageName {
        return "package:\(name)"
      }
      return "package"
    case .other:
      return nil
    }
  }

  private static func printSnippet(_ snippet: String) {
    let lines = snippet.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
      print("    \(line)")
    }
  }
}
