// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QTerm",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "../Citadel"),
        // SessionVaultKit рядом в той же папке (репо/воркспейс):
        .package(path: "../SessionVaultKit"),
        .package(path: "../Argon2Swift")
    ],
    targets: [
        .executableTarget(
            name: "QTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel"),
                "SessionVaultKit",
                .product(name: "Argon2Swift", package: "Argon2Swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
