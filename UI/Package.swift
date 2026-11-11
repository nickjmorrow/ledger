// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "LedgerUI", targets: ["LedgerUI"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "LedgerUI", dependencies: [.product(name: "LedgerCore", package: "Core")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LedgerUITests", dependencies: ["LedgerUI", .product(name: "LedgerCore", package: "Core")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
