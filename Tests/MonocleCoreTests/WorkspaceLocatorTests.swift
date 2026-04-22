// By Dennis Müller

import Foundation
@testable import MonocleCore
import Testing

final class WorkspaceLocatorTests {
  @Test func explicitPackageManifestPathResolvesSwiftPackageWorkspace() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let manifestURL = temporaryDirectory.appendingPathComponent("Package.swift")
    try """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "Example", products: [], targets: [])
    """.write(to: manifestURL, atomically: true, encoding: .utf8)

    let workspace = try WorkspaceLocator.locate(explicitWorkspacePath: manifestURL.path, filePath: manifestURL.path)
    let resolvedWorkspaceRootPath = URL(fileURLWithPath: workspace.rootPath).resolvingSymlinksInPath().path
    let resolvedTemporaryRootPath = temporaryDirectory.resolvingSymlinksInPath().path
    #expect(workspace.kind == .swiftPackage)
    #expect(resolvedWorkspaceRootPath == resolvedTemporaryRootPath)
  }

  @Test func autoDetectionPrefersXcodeProjectOverPackageManifest() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let xcodeProjectDirectory = temporaryDirectory.appendingPathComponent("Example.xcodeproj", isDirectory: true)
    try fileManager.createDirectory(at: xcodeProjectDirectory, withIntermediateDirectories: true)

    let manifestURL = temporaryDirectory.appendingPathComponent("Package.swift")
    try """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "Example", products: [], targets: [])
    """.write(to: manifestURL, atomically: true, encoding: .utf8)

    let sourcesDirectory = temporaryDirectory.appendingPathComponent("Sources", isDirectory: true)
    try fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

    let sampleSwiftFileURL = sourcesDirectory.appendingPathComponent("Sample.swift")
    try "public struct Sample {}".write(to: sampleSwiftFileURL, atomically: true, encoding: .utf8)

    let workspace = try WorkspaceLocator.locate(explicitWorkspacePath: nil, filePath: sampleSwiftFileURL.path)
    let resolvedWorkspaceRootPath = URL(fileURLWithPath: workspace.rootPath).resolvingSymlinksInPath().path
    let resolvedTemporaryRootPath = temporaryDirectory.resolvingSymlinksInPath().path
    #expect(workspace.kind == .xcodeProject)
    #expect(resolvedWorkspaceRootPath == resolvedTemporaryRootPath)
  }

  @Test func autoDetectionFindsCompilationDatabaseWorkspace() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let compileCommandsURL = temporaryDirectory.appendingPathComponent("compile_commands.json")
    try "[]".write(to: compileCommandsURL, atomically: true, encoding: .utf8)

    let sourcesDirectory = temporaryDirectory.appendingPathComponent("Sources", isDirectory: true)
    try fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

    let sampleSwiftFileURL = sourcesDirectory.appendingPathComponent("Sample.swift")
    try "public struct Sample {}".write(to: sampleSwiftFileURL, atomically: true, encoding: .utf8)

    let workspace = try WorkspaceLocator.locate(explicitWorkspacePath: nil, filePath: sampleSwiftFileURL.path)
    let resolvedWorkspaceRootPath = URL(fileURLWithPath: workspace.rootPath).resolvingSymlinksInPath().path
    let resolvedTemporaryRootPath = temporaryDirectory.resolvingSymlinksInPath().path
    #expect(workspace.kind == .compilationDatabase)
    #expect(resolvedWorkspaceRootPath == resolvedTemporaryRootPath)
  }

  @Test func autoDetectionPrefersPackageManifestOverCompilationDatabase() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let manifestURL = temporaryDirectory.appendingPathComponent("Package.swift")
    try """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "Example", products: [], targets: [])
    """.write(to: manifestURL, atomically: true, encoding: .utf8)

    let compileCommandsURL = temporaryDirectory.appendingPathComponent("compile_commands.json")
    try "[]".write(to: compileCommandsURL, atomically: true, encoding: .utf8)

    let workspace = try WorkspaceLocator.locate(explicitWorkspacePath: nil, filePath: temporaryDirectory.path)
    #expect(workspace.kind == .swiftPackage)
  }

  @Test func explicitCompilationDatabasePathResolvesCorrectly() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let compileCommandsURL = temporaryDirectory.appendingPathComponent("compile_commands.json")
    try "[]".write(to: compileCommandsURL, atomically: true, encoding: .utf8)

    let workspace = try WorkspaceLocator.locate(
      explicitWorkspacePath: temporaryDirectory.path,
      filePath: temporaryDirectory.path,
    )
    let resolvedWorkspaceRootPath = URL(fileURLWithPath: workspace.rootPath).resolvingSymlinksInPath().path
    let resolvedTemporaryRootPath = temporaryDirectory.resolvingSymlinksInPath().path
    #expect(workspace.kind == .compilationDatabase)
    #expect(resolvedWorkspaceRootPath == resolvedTemporaryRootPath)
  }

  @Test func explicitCompilationDatabasePathViaFilePathResolver() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let compileCommandsURL = temporaryDirectory.appendingPathComponent("compile_commands.json")
    try "[]".write(to: compileCommandsURL, atomically: true, encoding: .utf8)

    let resolvedPath = FilePathResolver.absolutePath(for: temporaryDirectory.path)
    let workspace = try WorkspaceLocator.locate(
      explicitWorkspacePath: resolvedPath,
      filePath: resolvedPath,
    )
    #expect(workspace.kind == .compilationDatabase)
  }
}
