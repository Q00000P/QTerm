#!/bin/bash
# QTerm: подготовка зависимостей для сборки из исходников.
# Клонирует пакеты РЯДОМ с папкой QTerm (Package.swift ссылается на ../),
# редакторные пакеты патчит для CLI-сборки (swift build не умеет xcassets).
set -e

# Родительская папка QTerm — сюда кладём соседей.
BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
echo "==> Зависимости будут в: $BASE"

clone() { # repo dir [branch]
  if [ -d "$2" ]; then echo "  $2 уже есть — пропускаю"; return; fi
  if [ -n "$3" ]; then git clone --branch "$3" "$1" "$2"; else git clone "$1" "$2"; fi
}

# --- форки и пакеты QTerm ---
clone https://github.com/Q00000P/Citadel.git         Citadel
clone https://github.com/Q00000P/SessionVaultKit.git SessionVaultKit
clone https://github.com/Q00000P/Argon2Swift.git     Argon2Swift

# --- редактор: апстрим на тегах + патчи для CLI-сборки ---
clone https://github.com/CodeEditApp/CodeEditSymbols.git      CodeEditSymbols      v0.2.3
clone https://github.com/CodeEditApp/CodeEditSourceEditor.git CodeEditSourceEditor 0.13.2

# Патч CodeEditSymbols: системные SF Symbols вместо xcassets/Bundle.module
# (swift build из CLI не обрабатывает xcassets — Bundle.module не генерится;
# редактор эти символы фактически не использует).
if ! grep -q "QTerm" CodeEditSymbols/Sources/CodeEditSymbols/CodeEditSymbols.swift; then
cat > CodeEditSymbols/Sources/CodeEditSymbols/CodeEditSymbols.swift << 'EOF'
//
// CodeEditSymbols.swift — ПАТЧ QTerm: fallback на системные SF Symbols,
// оригинал грузит кастомные символы из Symbols.xcassets через Bundle.module,
// недоступный при сборке swift build (CLI).
//

import SwiftUI
import AppKit

public extension Image {

    init(symbol: String) {
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            self.init(systemName: symbol)
        } else {
            self.init(nsImage: NSImage(
                systemSymbolName: "questionmark.square.dashed",
                accessibilityDescription: nil
            ) ?? NSImage())
        }
    }

    static let vault: Image = .init(symbol: "vault")
    static let vaultFill: Image = .init(symbol: "vault.fill")
    static let commit: Image = .init(symbol: "commit")
    static let checkout: Image = .init(symbol: "checkout")
    static let branch: Image = .init(symbol: "branch")
    static let breakpoint: Image = .init(symbol: "breakpoint")
    static let breakpointFill: Image = .init(symbol: "breakpoint.fill")
    static let chevronUpChevronDown: Image = .init(symbol: "chevron.up.chevron.down")
    static let github: Image = .init(symbol: "github")
    static let docJava: Image = .init(symbol: "doc.java")
    static let docJavascript: Image = .init(symbol: "doc.javascript")
    static let docJson: Image = .init(symbol: "doc.json")
    static let docPython: Image = .init(symbol: "doc.python")
    static let docRuby: Image = .init(symbol: "doc.ruby")
    static let squareSplitHorizontalPlus: Image = .init(symbol: "square.split.horizontal.plus")
    static let squareSplitVerticalPlus: Image = .init(symbol: "square.split.vertical.plus")
}

public extension NSImage {

    static func symbol(named: String) -> NSImage? {
        NSImage(systemSymbolName: named, accessibilityDescription: nil)
    }

    static let vault: NSImage? = .symbol(named: "vault")
    static let vaultFill: NSImage? = .symbol(named: "vault.fill")
    static let commit: NSImage? = .symbol(named: "commit")
    static let checkout: NSImage? = .symbol(named: "checkout")
    static let branch: NSImage? = .symbol(named: "branch")
    static let breakpoint: NSImage? = .symbol(named: "breakpoint")
    static let breakpointFill: NSImage? = .symbol(named: "breakpoint.fill")
    static let chevronUpChevronDown: NSImage? = .symbol(named: "chevron.up.chevron.down")
    static let github: NSImage? = .symbol(named: "github")
    static let docJava: NSImage? = .symbol(named: "doc.java")
    static let docJavascript: NSImage? = .symbol(named: "doc.javascript")
    static let docJson: NSImage? = .symbol(named: "doc.json")
    static let docPython: NSImage? = .symbol(named: "doc.python")
    static let docRuby: NSImage? = .symbol(named: "doc.ruby")
    static let squareSplitHorizontalPlus: NSImage? = .symbol(named: "square.split.horizontal.plus")
    static let squareSplitVerticalPlus: NSImage? = .symbol(named: "square.split.vertical.plus")
}
EOF
cat > CodeEditSymbols/Package.swift << 'EOF'
// swift-tools-version: 5.5
// ПАТЧ QTerm: убраны тесты и snapshot-testing.
import PackageDescription

let package = Package(
    name: "CodeEditSymbols",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "CodeEditSymbols",
            targets: ["CodeEditSymbols"]),
    ],
    targets: [
        .target(
            name: "CodeEditSymbols",
            dependencies: []
        ),
    ]
)
EOF
fi

# Патч CodeEditSourceEditor: локальный Symbols, без SwiftLint и тестов,
# CodeEditTextView строго 0.11.1 (0.12 сломал API LineFragmentView).
cat > CodeEditSourceEditor/Package.swift << 'EOF'
// swift-tools-version: 5.9
// ПАТЧ QTerm: CodeEditSymbols локальный, SwiftLint-плагин и тесты убраны,
// CodeEditTextView пин exact 0.11.1 (в 0.12.0 сломан API LineFragmentView).
import PackageDescription

let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditSourceEditor",
            targets: ["CodeEditSourceEditor"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/CodeEditApp/CodeEditTextView.git",
            exact: "0.11.1"
        ),
        .package(
            url: "https://github.com/CodeEditApp/CodeEditLanguages.git",
            exact: "0.1.20"
        ),
        .package(path: "../CodeEditSymbols"),
        .package(
            url: "https://github.com/ChimeHQ/TextFormation",
            from: "0.8.2"
        )
    ],
    targets: [
        .target(
            name: "CodeEditSourceEditor",
            dependencies: [
                "CodeEditTextView",
                "CodeEditLanguages",
                "TextFormation",
                "CodeEditSymbols"
            ]
        ),
    ]
)
EOF

echo
echo "==> Готово. Сборка: cd QTerm && ./make-app.sh"
