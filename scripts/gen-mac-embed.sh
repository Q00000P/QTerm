#!/bin/bash
# Вшивает scripts/vpn-cascade.sh в мак-сборку (Sources/QTerm/Xui/CascadeScript.swift, raw-строка).
# Зовётся из make-app.sh перед swift build; файл в гите — чтобы `swift build` работал и без make-app.
set -euo pipefail
cd "$(dirname "$0")/.."
src=scripts/vpn-cascade.sh
out=Sources/QTerm/Xui/CascadeScript.swift
grep -q '"""#' "$src" && { echo "в $src есть \"\"\"# — raw-строка Swift сломается" >&2; exit 1; }
grep -q '\\#' "$src" && { echo "в $src есть \\# — интерполяция raw-строки Swift" >&2; exit 1; }
tmp=$(mktemp)
{
  echo '// Сгенерировано scripts/gen-mac-embed.sh из scripts/vpn-cascade.sh — не править руками.'
  echo '// Скрипт сервера qcascade: QTerm заливает его на каскад-сервер сам (вкладка «Каскад»).'
  echo 'enum CascadeScript {'
  echo '    static let text = #"""'
  cat "$src"
  echo '"""#'
  echo '}'
} > "$tmp"
if cmp -s "$tmp" "$out" 2>/dev/null; then rm -f "$tmp"; else mv -f "$tmp" "$out"; echo "==> $out обновлён"; fi
