import Foundation

/// Represents the resolved information for a Swift symbol.
public struct SymbolInfo: Codable {
  public struct Location: Codable {
    public var uri: URL
    public var startLine: Int
    public var startCharacter: Int
    public var endLine: Int
    public var endCharacter: Int
    public var snippet: String?
    
    public init(
      uri: URL,
      startLine: Int,
      startCharacter: Int,
      endLine: Int,
      endCharacter: Int,
      snippet: String? = nil
    ) {
      self.uri = uri
      self.startLine = startLine
      self.startCharacter = startCharacter
      self.endLine = endLine
      self.endCharacter = endCharacter
      self.snippet = snippet
    }
  }
  
  public var symbol: String?
  public var kind: String?
  public var module: String?
  public var definition: Location?
  public var signature: String?
  public var documentation: String?
  
  public init(
    symbol: String? = nil,
    kind: String? = nil,
    module: String? = nil,
    definition: Location? = nil,
    signature: String? = nil,
    documentation: String? = nil
  ) {
    self.symbol = symbol
    self.kind = kind
    self.module = module
    self.definition = definition
    self.signature = signature
    self.documentation = documentation
  }
}
