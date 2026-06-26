#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN=""
EMAIL=""
CHALLENGE="tls-alpn"
DNS_PROVIDER=""
STAGING=false
TENANT_ALIASES=""
DDNS_COMMAND=""
DDNS_UPDATE_URL=""
INCLUDE_BASE_DOMAIN=false
UP=false

usage() {
  cat >&2 <<EOF
Usage: scripts/start-letsencrypt.sh --base-domain <domain> --email <email>
       [--challenge tls-alpn|dns] [--dns-provider <provider|manual>] [--staging]
       [--tenant-aliases acme,globex] [--ddns-command "<cmd>"]
       [--ddns-update-url <url>] [--include-base-domain] [--up]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --challenge) CHALLENGE="$2"; shift 2 ;;
    --dns-provider) DNS_PROVIDER="$2"; shift 2 ;;
    --staging) STAGING=true; shift ;;
    --tenant-aliases) TENANT_ALIASES="$2"; shift 2 ;;
    --ddns-command) DDNS_COMMAND="$2"; shift 2 ;;
    --ddns-update-url) DDNS_UPDATE_URL="$2"; shift 2 ;;
    --include-base-domain) INCLUDE_BASE_DOMAIN=true; shift ;;
    --up) UP=true; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[[ -n "$BASE_DOMAIN" ]] || { echo "--base-domain is required" >&2; usage; exit 64; }
[[ -n "$EMAIL" ]] || { echo "--email is required" >&2; usage; exit 64; }
case "$CHALLENGE" in
  tls-alpn) ;;
  dns) ;;
  *) echo "--challenge must be tls-alpn or dns" >&2; usage; exit 64 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$KIT_ROOT/compose"
TRAEFIK_DIR="$COMPOSE_DIR/gateway/traefik"
MANUAL_DNS=false
if [[ "$CHALLENGE" == "dns" && ( -z "$DNS_PROVIDER" || "$DNS_PROVIDER" == "manual" ) ]]; then
  MANUAL_DNS=true
fi

if [[ "$STAGING" == true ]]; then
  CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
else
  CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
fi

if [[ "$CHALLENGE" == "dns" && "$MANUAL_DNS" != true ]]; then
  CHALLENGE_BLOCK="      dnsChallenge:
        provider: ${DNS_PROVIDER}"
  if [[ "$INCLUDE_BASE_DOMAIN" == true ]]; then
    TLS_DOMAINS="        domains:
          - main: \"${BASE_DOMAIN}\"
            sans:
              - \"*.${BASE_DOMAIN}\""
  else
    TLS_DOMAINS="        domains:
          - main: \"*.${BASE_DOMAIN}\""
  fi
  if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
    DNS_ENV_SECTION="    environment:
      CF_DNS_API_TOKEN: \${CF_DNS_API_TOKEN}"
  else
    DNS_ENV_SECTION=""
    echo "DNS provider '$DNS_PROVIDER' selected. Add provider credential environment passthrough to compose/docker-compose.letsencrypt.yml if needed." >&2
  fi
else
  CHALLENGE_BLOCK="      tlsChallenge: {}"
  DNS_ENV_SECTION=""
fi

ESCAPED_BASE_DOMAIN="$(printf '%s' "$BASE_DOMAIN" | sed -e 's/[.[\*^$()+?{}|]/\\&/g')"
TENANT_ALIAS_BLOCK=""
TENANT_SAN_BLOCK=""
IFS=',' read -ra ALIASES <<< "$TENANT_ALIASES"
for alias in "${ALIASES[@]}"; do
  trimmed="$(printf '%s' "$alias" | xargs)"
  if [[ -n "$trimmed" ]]; then
    TENANT_ALIAS_BLOCK="${TENANT_ALIAS_BLOCK}          - ${trimmed}.${BASE_DOMAIN}"$'\n'
    TENANT_SAN_BLOCK="${TENANT_SAN_BLOCK}              - \"${trimmed}.${BASE_DOMAIN}\""$'\n'
  fi
done
TENANT_ALIAS_BLOCK="${TENANT_ALIAS_BLOCK%$'\n'}"
TENANT_SAN_BLOCK="${TENANT_SAN_BLOCK%$'\n'}"

if [[ "$CHALLENGE" == "tls-alpn" ]]; then
  if [[ -n "$TENANT_SAN_BLOCK" ]]; then
    TLS_DOMAINS="        domains:
          - main: \"platform.${BASE_DOMAIN}\"
            sans:
${TENANT_SAN_BLOCK}"
  else
    TLS_DOMAINS="        domains:
          - main: \"platform.${BASE_DOMAIN}\""
  fi
fi

if [[ "$MANUAL_DNS" == true ]]; then
  python - "$TRAEFIK_DIR/dynamic.public-cert.template.yml" "$TRAEFIK_DIR/dynamic.public-cert.generated.yml" "$BASE_DOMAIN" "$ESCAPED_BASE_DOMAIN" <<'PY'
import pathlib, sys
src, dst, base, escaped = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("__BASE_DOMAIN_REGEX__", escaped).replace("__BASE_DOMAIN__", base)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

  python - "$COMPOSE_DIR/docker-compose.public-cert.template.yml" "$COMPOSE_DIR/docker-compose.public-cert.yml" "$BASE_DOMAIN" "$TENANT_ALIAS_BLOCK" <<'PY'
import pathlib, sys
src, dst, base, aliases = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("__BASE_DOMAIN__", base).replace("__PUBLIC_CERT_TENANT_ALIASES__", aliases)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

  CERT_PATH="$COMPOSE_DIR/gateway/certs/wildcard.crt"
  KEY_PATH="$COMPOSE_DIR/gateway/certs/wildcard.key"

  echo "Generated public static-certificate gateway files for $BASE_DOMAIN"
  echo "  $COMPOSE_DIR/docker-compose.public-cert.yml"
  echo "  $TRAEFIK_DIR/dynamic.public-cert.generated.yml"
  echo
  echo "Manual DNS-01 cannot be renewed by Traefik without DNS API credentials."
  echo "Obtain or renew the certificate with an external ACME client, for example:"
  if [[ "$INCLUDE_BASE_DOMAIN" == true ]]; then
    echo "  certbot certonly --manual --preferred-challenges dns --agree-tos --no-eff-email --email '$EMAIL' -d '$BASE_DOMAIN' -d '*.$BASE_DOMAIN'"
  else
    echo "  certbot certonly --manual --preferred-challenges dns --agree-tos --no-eff-email --email '$EMAIL' -d '*.$BASE_DOMAIN'"
  fi
  echo
  echo "When prompted, create the TXT value(s) at _acme-challenge.$BASE_DOMAIN and wait for DNS propagation."
  echo "Then copy the issued files to:"
  echo "  fullchain.pem -> $CERT_PATH"
  echo "  privkey.pem   -> $KEY_PATH"
  echo
  echo "DNS must point platform.$BASE_DOMAIN and *.$BASE_DOMAIN at this machine. Inbound TCP 443 must reach Docker."
  echo
  echo "Start with:"
  echo "  cd compose"
  echo "  docker compose -f docker-compose.yml -f docker-compose.public-cert.yml up -d --wait"
  echo
  echo "First-run setup: https://platform.$BASE_DOMAIN/setup-license"
  echo "Operator console after setup: https://platform.$BASE_DOMAIN/admin-console"

  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    echo "WARNING: Certificate files are not present yet: $CERT_PATH and $KEY_PATH" >&2
    if [[ "$UP" == true ]]; then
      echo "Cannot start because the manual certificate files are missing." >&2
      exit 1
    fi
  elif [[ "$UP" == true ]]; then
    (cd "$COMPOSE_DIR" && docker compose -f docker-compose.yml -f docker-compose.public-cert.yml up -d --wait)
  fi

  exit 0
fi

python - "$TRAEFIK_DIR/traefik.letsencrypt.template.yml" "$TRAEFIK_DIR/traefik.letsencrypt.generated.yml" "$EMAIL" "$CA_SERVER" "$CHALLENGE_BLOCK" <<'PY'
import pathlib, sys
src, dst, email, ca_server, challenge = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("__LE_EMAIL__", email).replace("__LE_CASERVER__", ca_server).replace("__LE_CHALLENGE_BLOCK__", challenge)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

python - "$TRAEFIK_DIR/dynamic.letsencrypt.template.yml" "$TRAEFIK_DIR/dynamic.letsencrypt.generated.yml" "$BASE_DOMAIN" "$ESCAPED_BASE_DOMAIN" "$TLS_DOMAINS" <<'PY'
import pathlib, sys
src, dst, base, escaped, tls_domains = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("__BASE_DOMAIN_REGEX__", escaped).replace("__BASE_DOMAIN__", base).replace("__LE_TLS_DOMAINS__", tls_domains)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

python - "$COMPOSE_DIR/docker-compose.letsencrypt.template.yml" "$COMPOSE_DIR/docker-compose.letsencrypt.yml" "$BASE_DOMAIN" "$DNS_ENV_SECTION" "$TENANT_ALIAS_BLOCK" <<'PY'
import pathlib, sys
src, dst, base, dns_env, aliases = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("__BASE_DOMAIN__", base).replace("__LE_DNS_ENV_SECTION__", dns_env).replace("__LE_TENANT_ALIASES__", aliases)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

echo "Generated Let's Encrypt gateway files for $BASE_DOMAIN"
echo "  $COMPOSE_DIR/docker-compose.letsencrypt.yml"
echo "  $TRAEFIK_DIR/traefik.letsencrypt.generated.yml"
echo "  $TRAEFIK_DIR/dynamic.letsencrypt.generated.yml"

if [[ -n "$DDNS_COMMAND" ]]; then
  echo "Running DDNS command"
  eval "$DDNS_COMMAND"
elif [[ -n "$DDNS_UPDATE_URL" ]]; then
  if [[ "$DDNS_UPDATE_URL" == *"?"* ]]; then
    echo "Calling DDNS update URL: ${DDNS_UPDATE_URL%%\?*}?<query-redacted>"
  else
    echo "Calling DDNS update URL: $DDNS_UPDATE_URL"
  fi
  curl -fsS "$DDNS_UPDATE_URL" >/dev/null
fi

echo
echo "DNS must point platform.$BASE_DOMAIN and *.$BASE_DOMAIN at this machine. Inbound TCP 443 must reach Docker."
if [[ "$CHALLENGE" == "dns" && "$DNS_PROVIDER" == "cloudflare" ]]; then
  echo "Before compose up, set: export CF_DNS_API_TOKEN='<token>'"
fi
echo
echo "Start with:"
echo "  cd compose"
echo "  docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait"
echo
echo "First-run setup: https://platform.$BASE_DOMAIN/setup-license"
echo "Operator console after setup: https://platform.$BASE_DOMAIN/admin-console"

if [[ "$UP" == true ]]; then
  (cd "$COMPOSE_DIR" && docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait)
fi
