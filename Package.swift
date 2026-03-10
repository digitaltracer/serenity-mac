// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "SerenityMac",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SerenityMac", targets: ["SerenityMac"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.22.0"),
  ],
  targets: [
    .executableTarget(
      name: "SerenityMac",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
      ],
      path: "Serenity",
      exclude: [
        "iOS",
        "Support",
      ],
      sources: [
        "Shared",
        "macOS",
      ]
    ),
    .testTarget(
      name: "SerenityMacTests",
      dependencies: [
        "SerenityMac",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "SerenityTests"
    ),
  ],
)
