// By Dennis Müller

import Foundation
import LanguageServerProtocol

extension LspSession {
  struct HoverRender {
    /// Rendered signature text extracted from hover content.
    var signature: String?
    /// Documentation body extracted from hover content.
    var documentation: String?
    /// Symbol display name when available from hover content.
    var symbol: String?
    /// Symbol kind when available from hover content.
    var kind: String?
    /// Module name when available from hover content.
    var module: String?
  }

  /// Extracts a code snippet for the given URI and LSP range, if the URI is file-based.
  ///
  /// - Parameters:
  ///   - uri: URI pointing to a file on disk.
  ///   - range: Zero-based LSP range describing the snippet bounds.
  /// - Returns: The joined snippet text or `nil` when the file cannot be read.
  func extractSnippet(from uri: URL, range: LSPRange) -> String? {
    guard uri.isFileURL else { return nil }
    guard let contents = try? String(contentsOf: uri) else { return nil }

    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    guard range.start.line < lines.count, range.end.line < lines.count else { return nil }

    let slice = lines[range.start.line...range.end.line]
    return slice.joined(separator: "\n")
  }

  /// Splits hover content into signature and documentation components.
  ///
  /// - Parameter hover: Raw hover response returned by SourceKit-LSP.
  /// - Returns: A structured render containing signature and documentation text when present.
  func renderHover(_ hover: Hover) -> HoverRender {
    let value: String = switch hover.contents {
    case let .optionA(marked):
      marked.value
    case let .optionB(markedArray):
      markedArray.map(\.value).joined(separator: "\n")
    case let .optionC(markup):
      markup.value
    }
    // Heuristically split signature from docs if possible.
    let components = value.components(separatedBy: "\n\n")
    let signature = components.first
    let documentation = components.dropFirst().joined(separator: "\n\n")
    return HoverRender(
      signature: signature,
      documentation: documentation.isEmpty ? nil : documentation,
      symbol: nil,
      kind: nil,
      module: nil,
    )
  }

  struct TimeoutError: Error, LocalizedError {
    var seconds: TimeInterval

    var errorDescription: String? {
      "Timed out after \(seconds)s."
    }
  }

  func performWithTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T,
  ) async throws -> T {
    guard seconds > 0 else {
      return try await operation()
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw TimeoutError(seconds: seconds)
      }

      let result = try await group.next()
      group.cancelAll()
      guard let result else {
        throw TimeoutError(seconds: seconds)
      }

      return result
    }
  }
}
