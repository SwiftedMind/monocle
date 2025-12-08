/// Represents the domain-specific errors produced by Monocle.
public enum MonocleError: Error {
  case workspaceNotFound
  case lspLaunchFailed(String)
  case lspInitializationFailed(String)
  case symbolNotFound
  case ioError(String)
  case unsupportedWorkspaceKind
}
