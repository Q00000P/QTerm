#!/bin/bash
# Вшивает scripts/vpn-cascade.sh в мак-сборку (Sources/QTerm/Xui/CascadeScript.swift, raw-строка).
# Зовётся из make-app.sh перед swift build; файл в гите — чтобы `swift build` работал и без make-app.
# Число # у raw-строки подбирается само: в скрипте не должно быть ни """#…, ни \#… той же длины.
set -euo pipefail
cd "$(dirname "$0")/.."
src=scripts/vpn-cascade.sh
out=Sources/QTerm/Xui/CascadeScript.swift
hs=""
for n in 1 2 3 4 5 6; do
  hs=$(printf '%*s' "$n" '' | tr ' ' '#')
  if ! grep -qF -- "\"\"\"$hs" "$src" && ! grep -qF -- "\\$hs" "$src"; then break; fi
  [ "$n" = 6 ] && { echo "не подобрать разделитель raw-строки для $src" >&2; exit 1; }
done
tmp=$(mktemp)
{
  echo '// Сгенерировано scripts/gen-mac-embed.sh из scripts/vpn-cascade.sh — не править руками.'
  echo '// Скрипт сервера qcascade: QTerm заливает его на каскад-сервер сам (окно «Каскад»).'
  echo 'enum CascadeScript {'
  echo "    static let text = $hs\"\"\""
  cat "$src"
  echo "\"\"\"$hs"
  echo '}'
} > "$tmp"
if cmp -s "$tmp" "$out" 2>/dev/null; then rm -f "$tmp"; else mv -f "$tmp" "$out"; echo "==> $out обновлён"; fi
