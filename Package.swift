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
        .package(path: "../Argon2Swift"),
        // Встроенный редактор: вендоренный CodeEditSourceEditor 0.13.2
        // (~/dev, пропатчен под CLI-сборку: локальный CodeEditSymbols без
        // xcassets/Bundle.module, без SwiftLint-плагина).
        .package(path: "../CodeEditSourceEditor"),
        // Транзитивная зависимость редактора, но импортируется напрямую
        // (CodeLanguage.detectLanguageFrom) — поэтому объявлена явно.
        // exact 0.1.20 — ровно то, что пинует CodeEditSourceEditor 0.13.2.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20")
    ],
    targets: [
        .executableTarget(
            name: "QTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel"),
                "SessionVaultKit",
                .product(name: "Argon2Swift", package: "Argon2Swift"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
