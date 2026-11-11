// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "LedgerCore", targets: ["LedgerCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "LedgerCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
