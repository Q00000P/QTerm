#!/bin/bash
# Самоподписанный codesign-серт "QTerm Self-Signed" в login keychain —
# по образцу QSwitcher. Одноразовая операция.
set -euo pipefail
CERT_NAME="QTerm Self-Signed"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Серт '$CERT_NAME' уже есть."
    exit 0
fi

TMP=$(mktemp -d)
cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $CERT_NAME
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf"
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:qterm
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P qterm -T /usr/bin/codesign
# доверие для codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
rm -rf "$TMP"
echo "Готово: $CERT_NAME. Может понадобиться подтвердить доверие в Keychain Access."
