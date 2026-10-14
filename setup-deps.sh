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

# --- редактор QEditor: отдельное репо, свои зависимости (CodeEditSourceEditor + CodeEditSymbols
# клонирует и патчит его ../QEditor/macos/setup-deps.sh) ---
clone https://github.com/Q00000P/QEditor.git QEditor
if [ -x QEditor/macos/setup-deps.sh ]; then QEditor/macos/setup-deps.sh; fi

echo
echo "==> Готово. Сборка: (cd QEditor/macos && ./make-app.sh) && cd QTerm && ./make-app.sh"
