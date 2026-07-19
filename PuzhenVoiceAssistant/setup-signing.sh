#!/bin/bash
# One-time setup: creates a stable self-signed code-signing identity in a
# dedicated keychain, so rebuilds keep the same designated requirement and
# macOS stops re-prompting for microphone/speech permission on every build.
set -e
KC="$HOME/Library/Keychains/puzhen-signing.keychain-db"
KCPASS="puzhen"
CN="Puzhen Assistant Dev"

if security find-identity "$KC" 2>/dev/null | grep -q "$CN"; then
    echo "✓ 签名身份已存在,无需重建。"; exit 0
fi

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"

openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/pz.key -out /tmp/pz.crt -days 3650 \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -out /tmp/pz.p12 -inkey /tmp/pz.key -in /tmp/pz.crt \
  -passout pass:"$KCPASS" -name "$CN" \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

security import /tmp/pz.p12 -k "$KC" -P "$KCPASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/"//g' | xargs)
rm -f /tmp/pz.key /tmp/pz.crt /tmp/pz.p12

echo "✓ 已创建稳定签名身份「$CN」。之后 ./build.sh 会自动用它签名。"
