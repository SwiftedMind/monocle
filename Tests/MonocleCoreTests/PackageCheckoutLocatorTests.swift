// By Dennis Müller

import Foundation
@testable import MonocleCore
import Testing

final class PackageCheckoutLocatorTests {
  @Test func swiftPackageWorkspaceListsCheckedOutPackages() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    try """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "Example", products: [], targets: [])
    """.write(
      to: temporaryDirectory.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8,
    )

    let checkoutsRoot = temporaryDirectory.appendingPathComponent(".build/checkouts", isDirectory: true)
    let checkoutDirectory = checkoutsRoot.appendingPathComponent("ExampleDependency", isDirectory: true)
    try fileManager.createDirectory(at: checkoutDirectory, withIntermediateDirectories: true)
    try "ExampleDependency".write(
      to: checkoutDirectory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8,
    )

    let workspace = Workspace(rootPath: temporaryDirectory.path, kind: .swiftPackage)
    let packages = try PackageCheckoutLocator.checkedOutPackages(in: workspace)

    #expect(packages.count == 1)
    #expect(packages[0].packageName == "ExampleDependency")
    #expect(packages[0].checkoutPath.hasSuffix("/.build/checkouts/ExampleDependency"))
    #expect(packages[0].readmePath?.hasSuffix("/.build/checkouts/ExampleDependency/README.md") == true)
  }

  @Test func xcodeWorkspaceUsesBuildServerBuildRootToFindCheckouts() throws {
    let fileManager = FileManager.default
    let workspaceRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: workspaceRoot) }

    let derivedDataRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: derivedDataRoot) }

    try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: derivedDataRoot, withIntermediateDirectories: true)

    let buildServerJSON = """
    {
      "name": "xcode build server",
      "version": "0.2",
      "bspVersion": "2.0",
      "languages": ["swift"],
      "argv": ["/usr/local/bin/xcode-build-server"],
      "workspace": "\(workspaceRoot.path)/Example.xcodeproj/project.xcworkspace",
      "build_root": "\(derivedDataRoot.path)",
      "scheme": "Example",
      "kind": "xcode"
    }
    """
    try buildServerJSON.write(
      to: workspaceRoot.appendingPathComponent("buildServer.json"),
      atomically: true,
      encoding: .utf8,
    )

    let checkoutDirectory = derivedDataRoot
      .appendingPathComponent("SourcePackages/checkouts/RemoteDependency", isDirectory: true)
    try fileManager.createDirectory(at: checkoutDirectory, withIntermediateDirectories: true)
    try "RemoteDependency".write(
      to: checkoutDirectory.appendingPathComponent("ReadMe.MD"),
      atomically: true,
      encoding: .utf8,
    )

    let workspace = Workspace(rootPath: workspaceRoot.path, kind: .xcodeProject)
    let packages = try PackageCheckoutLocator.checkedOutPackages(in: workspace)

    #expect(packages.count == 1)
    #expect(packages[0].packageName == "RemoteDependency")
    #expect(packages[0].checkoutPath.hasSuffix("/SourcePackages/checkouts/RemoteDependency"))
    #expect(packages[0].readmePath?.hasSuffix("/SourcePackages/checkouts/RemoteDependency/ReadMe.MD") == true)
  }

  @Test func xcodeWorkspaceBuildRootEndingInBuildFindsCheckoutsInParentDirectory() throws {
    let fileManager = FileManager.default
    let workspaceRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: workspaceRoot) }

    let derivedDataRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: derivedDataRoot) }

    try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: derivedDataRoot, withIntermediateDirectories: true)

    let derivedDataBuildRoot = derivedDataRoot.appendingPathComponent("Build", isDirectory: true)
    try fileManager.createDirectory(at: derivedDataBuildRoot, withIntermediateDirectories: true)

    let buildServerJSON = """
    {
      "name": "xcode build server",
      "version": "0.2",
      "bspVersion": "2.0",
      "languages": ["swift"],
      "argv": ["/usr/local/bin/xcode-build-server"],
      "workspace": "\(workspaceRoot.path)/Example.xcodeproj/project.xcworkspace",
      "build_root": "\(derivedDataBuildRoot.path)",
      "scheme": "Example",
      "kind": "xcode"
    }
    """
    try buildServerJSON.write(
      to: workspaceRoot.appendingPathComponent("buildServer.json"),
      atomically: true,
      encoding: .utf8,
    )

    let checkoutDirectory = derivedDataRoot
      .appendingPathComponent("SourcePackages/checkouts/RemoteDependency", isDirectory: true)
    try fileManager.createDirectory(at: checkoutDirectory, withIntermediateDirectories: true)

    let workspace = Workspace(rootPath: workspaceRoot.path, kind: .xcodeProject)
    let packages = try PackageCheckoutLocator.checkedOutPackages(in: workspace)

    #expect(packages.count == 1)
    #expect(packages[0].packageName == "RemoteDependency")
    #expect(packages[0].checkoutPath.hasSuffix("/SourcePackages/checkouts/RemoteDependency"))
  }

  @Test func tuistManagedWorkspaceUsesTuistCheckoutsDirectory() throws {
    let fileManager = FileManager.default
    let workspaceRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: workspaceRoot) }

    try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

    let tuistCheckoutsRoot = workspaceRoot.appendingPathComponent("Tuist/.build/checkouts", isDirectory: true)
    let checkoutDirectory = tuistCheckoutsRoot.appendingPathComponent("TuistDependency", isDirectory: true)
    try fileManager.createDirectory(at: checkoutDirectory, withIntermediateDirectories: true)
    try "TuistDependency".write(
      to: checkoutDirectory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8,
    )

    let workspace = Workspace(rootPath: workspaceRoot.path, kind: .xcodeProject)
    let packages = try PackageCheckoutLocator.checkedOutPackages(in: workspace)

    #expect(packages.count == 1)
    #expect(packages[0].packageName == "TuistDependency")
    #expect(packages[0].checkoutPath.hasSuffix("/Tuist/.build/checkouts/TuistDependency"))
    #expect(packages[0].readmePath?.hasSuffix("/Tuist/.build/checkouts/TuistDependency/README.md") == true)
  }

  @Test func xcodeWorkspaceWithoutBuildServerThrowsHelpfulError() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let workspace = Workspace(rootPath: temporaryDirectory.path, kind: .xcodeWorkspace)

    do {
      _ = try PackageCheckoutLocator.checkedOutPackages(in: workspace)
      Issue.record("Expected checkedOutPackages(in:) to throw when buildServer.json is missing.")
    } catch let error as MonocleError {
      switch error {
      case let .buildServerConfigurationMissing(workspaceRootPath):
        let resolvedWorkspaceRootPath = URL(fileURLWithPath: workspaceRootPath).resolvingSymlinksInPath().path
        let resolvedTemporaryRootPath = temporaryDirectory.resolvingSymlinksInPath().path
        #expect(resolvedWorkspaceRootPath == resolvedTemporaryRootPath)
      default:
        Issue.record("Expected buildServerConfigurationMissing, got \(error).")
      }
    } catch {
      Issue.record("Expected MonocleError, got \(error).")
    }
  }
}
