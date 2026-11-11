// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ledger",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(name: "ledger", dependencies: [
            .product(name: "LedgerCore", package: "Core"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ledgerTests", dependencies: ["ledger", .product(name: "LedgerCore", package: "Core")]),
    ]
)
