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
#   wildcard.crt / wildcard.key   - server cert for the selected base domain, mounted into Traefik
#   local-ca.crt                  - the local CA; trust this in your OS/browser/wallet
#   local-truststore.p12          - JVM default public roots plus the local CA
#                                   (password: changeit), mounted into service containers
#                                   so internal and public provider TLS both validate
#
# Uses mkcert when available (its CA is auto-trusted by `mkcert -install`), otherwise
# falls back to a self-signed openssl CA you trust manually.
#
# Re-run any time; it overwrites the cert material.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/compose/gateway/certs"
BASE_DOMAIN="${EDK_PLATFORM_BASE_DOMAIN:-}"
BASE_DOMAIN_ARGUMENT_PROVIDED=false
LOCALTEST=false
TRUSTSTORE_PASS="${EDK_TRUSTSTORE_PASSWORD:-changeit}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-domain) BASE_DOMAIN="$2"; BASE_DOMAIN_ARGUMENT_PROVIDED=true; shift 2 ;;
    --localtest) LOCALTEST=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ "$LOCALTEST" == true && "$BASE_DOMAIN_ARGUMENT_PROVIDED" == true ]]; then
  echo "--localtest and --base-domain are mutually exclusive." >&2
  exit 64
fi
if [[ "$LOCALTEST" == true ]]; then BASE_DOMAIN="saas.localtest.me"; fi
if [[ -z "${BASE_DOMAIN//[[:space:]]/}" ]]; then
  echo "A base domain is required. Pass --base-domain, set EDK_PLATFORM_BASE_DOMAIN, or pass --localtest explicitly." >&2
  exit 64
fi
if [[ "$BASE_DOMAIN" == *"://"* || "$BASE_DOMAIN" == *":"* || "$BASE_DOMAIN" == *"/"* || "$BASE_DOMAIN" == *"\\"* || "$BASE_DOMAIN" =~ [[:space:]] || "$BASE_DOMAIN" == .* || "$BASE_DOMAIN" == *. ]]; then
  echo "Base domain must be a hostname without scheme, port, path, or whitespace; got '$BASE_DOMAIN'." >&2
  exit 64
fi

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

# Preserve the JVM public roots when adding the local CA. Replacing the default
# trust anchors with only the local CA breaks HTTPS calls to external providers.
if command -v keytool >/dev/null 2>&1; then
  keytool_bin="$(readlink -f "$(command -v keytool)")"
  default_cacerts="$(cd "$(dirname "$keytool_bin")/../lib/security" && pwd)/cacerts"
  [[ -f "$default_cacerts" ]] || { echo "Could not locate the JVM default truststore." >&2; exit 2; }
  rm -f "$CERT_DIR/local-truststore.p12"
  keytool -importkeystore -noprompt \
    -srckeystore "$default_cacerts" -srcstorepass changeit \
    -destkeystore "$CERT_DIR/local-truststore.p12" \
    -deststorepass "$TRUSTSTORE_PASS" -deststoretype PKCS12 >/dev/null 2>&1
  keytool -importcert -noprompt -trustcacerts \
    -alias edk-local-ca -file "$CERT_DIR/local-ca.crt" \
    -keystore "$CERT_DIR/local-truststore.p12" -storetype PKCS12 \
    -storepass "$TRUSTSTORE_PASS" >/dev/null 2>&1
  echo "Wrote local-truststore.p12 with JVM public roots and the local CA (password: $TRUSTSTORE_PASS)."
else
  echo "WARNING: keytool not found; local-truststore.p12 not generated."
  echo "         Per-tenant JWKS over TLS from inside the service containers will fail until you create it."
fi

echo "Done. Trust $CERT_DIR/local-ca.crt in your OS/browser to avoid cert warnings."
