#!/usr/bin/env bash
#
# Generate a local wildcard TLS certificate for the single-port gateway, for
# LOCAL EVALUATION of the kit.
#
# The kit's single-port gateway terminates TLS for every tenant and the operator
# host under one wildcard certificate. This helper produces that certificate for
# local evaluation. For production, front the gateway with a publicly-trusted
# certificate instead and skip this script.
#
# Output (compose/gateway/certs/):
#   wildcard.crt / wildcard.key   - server cert for *.saas.localtest.me, mounted into Traefik
#   local-ca.crt                  - the local CA; trust this in your OS/browser/wallet
#   local-truststore.p12          - JVM truststore holding the CA (password: changeit),
#                                   mounted into the service containers so they trust the
#                                   gateway when fetching per-tenant JWKS over TLS
#
# Uses mkcert when available (its CA is auto-trusted by `mkcert -install`), otherwise
# falls back to a self-signed openssl CA you trust manually.
#
# Re-run any time; it overwrites the cert material.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/compose/gateway/certs"
BASE_DOMAIN="${EDK_PLATFORM_BASE_DOMAIN:-saas.localtest.me}"
TRUSTSTORE_PASS="${EDK_TRUSTSTORE_PASSWORD:-changeit}"

mkdir -p "$CERT_DIR"

echo "Generating local wildcard cert for *.$BASE_DOMAIN -> $CERT_DIR"

if command -v mkcert >/dev/null 2>&1; then
  echo "Using mkcert (run 'mkcert -install' once so your browser trusts it)."
  mkcert -cert-file "$CERT_DIR/wildcard.crt" -key-file "$CERT_DIR/wildcard.key" \
    "*.$BASE_DOMAIN" "$BASE_DOMAIN" "platform.$BASE_DOMAIN" localhost 127.0.0.1
  CAROOT="$(mkcert -CAROOT)"
  cp "$CAROOT/rootCA.pem" "$CERT_DIR/local-ca.crt"
else
  echo "mkcert not found; using a self-signed openssl CA. Trust local-ca.crt manually."
  # Local CA
  openssl genrsa -out "$CERT_DIR/local-ca.key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "$CERT_DIR/local-ca.key" -sha256 -days 3650 \
    -subj "/CN=EDK Local Evaluation CA/O=Sphereon EDK" -out "$CERT_DIR/local-ca.crt" >/dev/null 2>&1
  # Server key + CSR + SAN-signed cert
  openssl genrsa -out "$CERT_DIR/wildcard.key" 2048 >/dev/null 2>&1
  cat > "$CERT_DIR/.san.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = *.$BASE_DOMAIN
[v3_req]
subjectAltName = @alt
[alt]
DNS.1 = *.$BASE_DOMAIN
DNS.2 = $BASE_DOMAIN
DNS.3 = platform.$BASE_DOMAIN
DNS.4 = localhost
IP.1 = 127.0.0.1
EOF
  openssl req -new -key "$CERT_DIR/wildcard.key" -out "$CERT_DIR/.wildcard.csr" \
    -config "$CERT_DIR/.san.cnf" >/dev/null 2>&1
  openssl x509 -req -in "$CERT_DIR/.wildcard.csr" -CA "$CERT_DIR/local-ca.crt" \
    -CAkey "$CERT_DIR/local-ca.key" -CAcreateserial -days 825 -sha256 \
    -extensions v3_req -extfile "$CERT_DIR/.san.cnf" -out "$CERT_DIR/wildcard.crt" >/dev/null 2>&1
  rm -f "$CERT_DIR/.wildcard.csr" "$CERT_DIR/.san.cnf" "$CERT_DIR/local-ca.srl"
fi

# JVM truststore with the CA so the service containers trust per-tenant JWKS over TLS.
if command -v keytool >/dev/null 2>&1; then
  rm -f "$CERT_DIR/local-truststore.p12"
  keytool -importcert -noprompt -trustcacerts \
    -alias edk-local-ca -file "$CERT_DIR/local-ca.crt" \
    -keystore "$CERT_DIR/local-truststore.p12" -storetype PKCS12 \
    -storepass "$TRUSTSTORE_PASS" >/dev/null 2>&1
  echo "Wrote local-truststore.p12 (password: $TRUSTSTORE_PASS)."
else
  echo "WARNING: keytool not found; local-truststore.p12 not generated."
  echo "         Per-tenant JWKS over TLS from inside the service containers will fail until you create it."
fi

echo "Done. Trust $CERT_DIR/local-ca.crt in your OS/browser to avoid cert warnings."
