#!/bin/bash
# 자가서명 코드서명 인증서 "AnywhereLLM Dev" 생성 + 로그인 키체인 등록.
# 한 번만 실행. 이후 make가 이 인증서로 서명 → 재빌드해도 TCC(접근성) 권한 유지.
# 실행 중 키체인 암호 GUI 프롬프트 뜰 수 있음 — 허용할 것.
set -euo pipefail

NAME="AnywhereLLM Dev"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$NAME"; then
    echo "이미 존재: $NAME — 재생성 불필요"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

# 시스템 openssl(LibreSSL) 고정 — OpenSSL 3.x 기본 p12 포맷은 키체인이 거부함
OPENSSL=/usr/bin/openssl

$OPENSSL req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf"

$OPENSSL pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:temp \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

security import "$TMP/cert.p12" \
    -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign

# 자가서명 인증서 신뢰 등록 (GUI 인증 프롬프트 가능)
security add-trusted-cert -r trustRoot \
    -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo "완료. 확인:"
security find-identity -p codesigning -v | grep "$NAME"
