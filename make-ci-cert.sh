#!/bin/bash
# Одноразово: серт подписи «QTerm CI» — в login keychain этого мака и в секреты GitHub
# (MAC_SIGN_P12 / MAC_SIGN_P12_PASS). После этого CI подписывает QTerm.app тем же сертом и
# публикует релиз mac-vX.Y.Z; Keychain/Touch ID вейлта одинаково узнают CI-сборку и локальную.
# Пароль p12 — случайный, живёт только в секрете; ключ на диске не остаётся.
set -euo pipefail
CERT_NAME="QTerm CI"
REPO="Q00000P/QTerm"
OPENSSL=/usr/bin/openssl   # системный LibreSSL: его p12 понимает `security import` (у OpenSSL 3 — нет)

command -v gh >/dev/null || { echo "нужен gh (brew install gh && gh auth login)"; exit 1; }

if security find-identity -p codesigning | grep -q "\"$CERT_NAME\""; then
    echo "Серт «$CERT_NAME» уже в keychain. Удали его в Keychain Access, если нужно выпустить заново."
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$($OPENSSL rand -hex 16)

cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $CERT_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

$OPENSSL req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf" 2>/dev/null
$OPENSSL pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$PASS"

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "==> доверие для подписи кода (macOS спросит пароль)"
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo "==> секреты GitHub"
base64 -i "$TMP/cert.p12" | gh secret set MAC_SIGN_P12 -R "$REPO"
printf '%s' "$PASS" | gh secret set MAC_SIGN_P12_PASS -R "$REPO"

echo "==> сборка и релиз на GitHub"
gh workflow run macos.yml -R "$REPO" --ref main
echo "Готово: «$CERT_NAME» в keychain и в секретах. Релиз mac-v… появится через ~10 минут."
