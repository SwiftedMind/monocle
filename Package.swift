// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "monocle",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "MonocleCore",
      targets: ["MonocleCore"]
    ),
    .executable(
      name: "monocle",
      targets: ["MonocleCLI"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol.git", from: "0.14.0"),
    .package(url: "https://github.com/ChimeHQ/LanguageClient.git", from: "0.8.2")
  ],
  targets: [
    .target(
      name: "MonocleCore",
      dependencies: [
        .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
        .product(name: "LanguageClient", package: "LanguageClient")
      ],
      path: "Sources/MonocleCore"
    ),
    .executableTarget(
      name: "MonocleCLI",
      dependencies: [
        "MonocleCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources/MonocleCLI"
    )
  ]
)
