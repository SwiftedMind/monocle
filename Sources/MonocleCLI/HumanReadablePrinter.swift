import Foundation
import MonocleCore

enum HumanReadablePrinter {
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
    
    if info.symbol == nil && info.signature == nil && info.documentation == nil {
      print("Symbol resolution is not implemented yet.")
    }
  }
}
