#!/bin/zsh
set -eu
cd "${0:A:h}"
identity="Safari Recent Tabs Local"
if security find-identity -v -p codesigning | grep -Fq -- "$identity"; then
  print "Persistent signing identity already exists."
  exit 0
fi
signing_temp=$(mktemp -d /tmp/safari-tabs-signing.XXXXXX)
chmod 700 "$signing_temp"
trap 'rm -rf "$signing_temp"' EXIT
umask 077
openssl rand -hex 32 > "$signing_temp/password"
cat > "$signing_temp/cert.cnf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Safari Recent Tabs Local
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF
openssl req -new -x509 -newkey rsa:3072 -nodes -days 3650 -config "$signing_temp/cert.cnf" -keyout "$signing_temp/key.pem" -out "$signing_temp/cert.pem"
openssl pkcs12 -export -inkey "$signing_temp/key.pem" -in "$signing_temp/cert.pem" -out "$signing_temp/identity.p12" -passout "file:$signing_temp/password"
login_keychain="$HOME/Library/Keychains/login.keychain-db"
security import "$signing_temp/identity.p12" -k "$login_keychain" -P "$(cat "$signing_temp/password")" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$signing_temp/cert.pem"
security find-identity -v -p codesigning
print "Signing identity installed. Build with ./build.command."
