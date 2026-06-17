#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN=""
EMAIL=""
CHALLENGE="tls-alpn"
DNS_PROVIDER=""
STAGING=false
TENANT_ALIASES="tenant-as,acme,globex,initech"
DDNS_COMMAND=""
DDNS_UPDATE_URL=""
UP=false

usage() {
  cat >&2 <<EOF
Usage: scripts/start-letsencrypt.sh --base-domain <domain> --email <email>
       [--challenge tls-alpn|dns] [--dns-provider <provider>] [--staging]
       [--tenant-aliases acme,globex] [--ddns-command "<cmd>"]
       [--ddns-update-url <url>] [--up]
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
    --up) UP=true; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[[ -n "$BASE_DOMAIN" ]] || { echo "--base-domain is required" >&2; usage; exit 64; }
[[ -n "$EMAIL" ]] || { echo "--email is required" >&2; usage; exit 64; }
case "$CHALLENGE" in
  tls-alpn) ;;
  dns) [[ -n "$DNS_PROVIDER" ]] || { echo "--challenge dns requires --dns-provider" >&2; usage; exit 64; } ;;
  *) echo "--challenge must be tls-alpn or dns" >&2; usage; exit 64 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$KIT_ROOT/compose"
TRAEFIK_DIR="$COMPOSE_DIR/gateway/traefik"

if [[ "$STAGING" == true ]]; then
  CA_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
else
  CA_SERVER="https://acme-v02.api.letsencrypt.org/directory"
fi

if [[ "$CHALLENGE" == "dns" ]]; then
  CHALLENGE_BLOCK="      dnsChallenge:
        provider: ${DNS_PROVIDER}"
  TLS_DOMAINS="        domains:
          - main: \"${BASE_DOMAIN}\"
            sans:
              - \"*.${BASE_DOMAIN}\""
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
text = text.replace("saas\\.localtest\\.me", escaped).replace("saas.localtest.me", base).replace("__LE_TLS_DOMAINS__", tls_domains)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY

python - "$COMPOSE_DIR/docker-compose.letsencrypt.template.yml" "$COMPOSE_DIR/docker-compose.letsencrypt.yml" "$BASE_DOMAIN" "$DNS_ENV_SECTION" "$TENANT_ALIAS_BLOCK" <<'PY'
import pathlib, sys
src, dst, base, dns_env, aliases = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("saas.localtest.me", base).replace("__LE_DNS_ENV_SECTION__", dns_env).replace("__LE_TENANT_ALIASES__", aliases)
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
echo "Operator console: https://platform.$BASE_DOMAIN/admin-console"

if [[ "$UP" == true ]]; then
  (cd "$COMPOSE_DIR" && docker compose -f docker-compose.yml -f docker-compose.letsencrypt.yml up -d --wait)
fi
