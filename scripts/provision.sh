#!/usr/bin/env bash
#
# Onboards a freshly deployed Sphereon EDK enterprise platform and its first
# production tenant by calling the published gateway REST APIs.
#
# This script runs against a RUNNING deployment (the Docker Compose
# stack or a Kubernetes install). It performs, in order:
#
#   1. Waits for the platform gateway setup-status route to become reachable.
#   2. Platform setup (only if the setup gate is still open): bootstraps the
#      operator account and imports your protected license bundle.
#   3. Signs the operator in through the platform authorization-code flow with
#      PKCE, carrying cookies and the login form CSRF tuple like a browser.
#   4. Registers the first production tenant.
#   5. Verifies the tenant gateway route bindings created by tenant setup.
#   6. Prints a summary with the operator console URL and the tenant gateway.
#
# Prerequisites:
#   - A running EDK enterprise platform reachable at platform.<baseDomain>,
#     or an explicit platformUrl in the environment file. Tenant AS, tenant KMS,
#     and DID must be running before tenant registration, because registration
#     provisions signing material and the tenant DID through east-west services.
#   - A Sphereon protected license bundle ZIP (set in the environment file as
#     licenseBundleZipPath).
#   - curl and node installed. node parses the environment JSON and computes the
#     PKCE S256 code challenge.
#
# Configuration is read from the kit's Postman customer environment file
# (../postman/EDK-Enterprise-Deployment.customer.postman_environment.json by
# default). The default environment derives the platform gateway URL and tenant
# gateway URL from baseDomain and tenantSlug. Override the tenant gateway only
# for non-standard gateway deployments.
#
# Example:
#   ./provision.sh
#   ./provision.sh --tenant-name "Acme Corporation" --tenant-slug acme
#   ./provision.sh --skip-setup            # platform already initialized
#   ./provision.sh --env-file ../postman/EDK-Enterprise-Deployment.customer.postman_environment.json
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE=""
TENANT_NAME=""
TENANT_SLUG=""
SKIP_SETUP="false"

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Flags:
  --env-file PATH      Postman customer environment file (default: ../postman/...customer...json)
  --tenant-name NAME   Tenant display name (overrides the env file)
  --tenant-slug SLUG   Tenant slug (overrides the env file)
  --skip-setup         Skip platform setup (platform already initialized)
  --help               Show this help and exit
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)    ENV_FILE="$2"; shift 2 ;;
    --tenant-name) TENANT_NAME="$2"; shift 2 ;;
    --tenant-slug) TENANT_SLUG="$2"; shift 2 ;;
    --skip-setup)  SKIP_SETUP="true"; shift ;;
    --help|-h)     usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required but was not found on PATH."
command -v node >/dev/null 2>&1 || fail "node is required but was not found on PATH. Install Node.js and retry."

if [ -z "$ENV_FILE" ]; then
  ENV_FILE="$SCRIPT_DIR/../postman/EDK-Enterprise-Deployment.customer.postman_environment.json"
fi
[ -f "$ENV_FILE" ] || fail "Environment file not found: $ENV_FILE"

# --- Read a single key from the Postman environment file via node -------------
cfg() {
  node -e '
    const fs = require("fs");
    const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const key = process.argv[2];
    for (const v of (doc.values || [])) {
      if (v && v.key === key && (v.enabled === undefined || v.enabled)) {
        process.stdout.write(v.value == null ? "" : String(v.value));
        break;
      }
    }
  ' "$ENV_FILE" "$1"
}

# --- Resolve effective config (flags override the environment file) -----------
PLATFORM_URL="$(cfg platformUrl)"
TENANT_GATEWAY_URL="$(cfg tenantGatewayUrl)"
BASE_DOMAIN="$(cfg baseDomain)"

OPERATOR_EMAIL="$(cfg operatorEmail)"
OPERATOR_DISPLAY_NAME="$(cfg operatorDisplayName)"
[ -n "$OPERATOR_DISPLAY_NAME" ] || OPERATOR_DISPLAY_NAME="Platform Operator"
OPERATOR_PASSWORD="$(cfg operatorPassword)"
OPERATOR_REDIRECT_URI="$(cfg operatorRedirectUri)"
ADMIN_CONSOLE_URL="$(cfg adminConsoleUrl)"
OPERATOR_CODE_VERIFIER="$(cfg operatorCodeVerifier)"
LICENSE_BUNDLE_ZIP_PATH="$(cfg licenseBundleZipPath)"

[ -n "$TENANT_NAME" ] || TENANT_NAME="$(cfg tenantName)"
[ -n "$TENANT_SLUG" ] || TENANT_SLUG="$(cfg tenantSlug)"

TENANT_HOST="$(cfg tenantHost)"

BASE_DOMAIN="${BASE_DOMAIN#http://}"
BASE_DOMAIN="${BASE_DOMAIN#https://}"
BASE_DOMAIN="${BASE_DOMAIN%/}"

if [ -z "$TENANT_HOST" ] && [ -n "$BASE_DOMAIN" ] && [ -n "$TENANT_SLUG" ]; then
  TENANT_HOST="$TENANT_SLUG.$BASE_DOMAIN"
fi
if [ -z "$PLATFORM_URL" ] && [ -n "$BASE_DOMAIN" ]; then
  PLATFORM_URL="https://platform.$BASE_DOMAIN"
fi
if [ -n "$TENANT_HOST" ]; then
  [ -n "$TENANT_GATEWAY_URL" ] || TENANT_GATEWAY_URL="https://$TENANT_HOST"
fi
if [ -z "$TENANT_HOST" ] && [ -n "$TENANT_GATEWAY_URL" ]; then
  TENANT_HOST="$(node -e '
    try { process.stdout.write(new URL(process.argv[1]).hostname); } catch (e) {}
  ' "$TENANT_GATEWAY_URL")"
fi
if [ -z "$OPERATOR_REDIRECT_URI" ] && [ -n "$PLATFORM_URL" ]; then
  OPERATOR_REDIRECT_URI="${PLATFORM_URL%/}/admin-console/callback"
fi
if [ -z "$ADMIN_CONSOLE_URL" ] && [ -n "$PLATFORM_URL" ]; then
  ADMIN_CONSOLE_URL="${PLATFORM_URL%/}/admin-console"
fi

[ -n "$PLATFORM_URL" ] || fail "platformUrl is not set in the environment file."
[ -n "$TENANT_NAME" ]  || fail "tenantName is not set (use --tenant-name or set it in the environment file)."
[ -n "$TENANT_SLUG" ]  || fail "tenantSlug is not set (use --tenant-slug or set it in the environment file)."
[ -n "$TENANT_HOST" ]  || fail "tenant gateway host could not be derived. Set baseDomain and tenantSlug, or set tenantGatewayUrl."

PLATFORM_URL="${PLATFORM_URL%/}"

# Cookie jar shared across the operator sign-in requests.
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

# --- JSON helpers (extract a top-level string field via node) -----------------
json_field() {
  # $1 = JSON string, $2 = dotted path (e.g. tenant.id)
  node -e '
    let data = "";
    process.stdin.on("data", c => data += c);
    process.stdin.on("end", () => {
      let obj; try { obj = JSON.parse(data); } catch (e) { process.exit(0); }
      let cur = obj;
      for (const seg of process.argv[1].split(".")) {
        if (cur == null) break;
        cur = cur[seg];
      }
      if (cur != null) process.stdout.write(String(cur));
    });
  ' "$2" <<<"$1"
}

# --- Step 1: wait for platform gateway reachability ---------------------------
wait_platform_gateway() {
  local base="$1" retries=30 delay=4 i code
  local url="${base%/}/api/platform/setup/v1/status"
  for ((i = 0; i < retries; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)"
    if [ "$code" = "200" ] || [ "$code" = "404" ]; then
      echo "  [ok]   platform ($url)"
      return 0
    fi
    sleep "$delay"
  done
  fail "platform did not become reachable at $url"
}

echo "Waiting for the platform gateway route to become reachable..."
wait_platform_gateway "$PLATFORM_URL"

# --- Step 2: platform setup (idempotent) --------------------------------------
SETUP_STATUS_URL="$PLATFORM_URL/api/platform/setup/v1/status"
SETUP_OPEN="false"

if [ "$SKIP_SETUP" = "true" ]; then
  echo "Skipping platform setup (--skip-setup)."
else
  echo "Checking platform setup status..."
  STATUS_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SETUP_STATUS_URL" || echo 000)"
  if [ "$STATUS_CODE" = "404" ]; then
    echo "  Setup gate is closed (already initialized). Skipping setup."
  elif [ "$STATUS_CODE" = "200" ]; then
    SETUP_OPEN="true"
  else
    echo "  Setup status returned $STATUS_CODE; treating setup as closed."
  fi
fi

# POST a JSON body and fail on a non-2xx response. Echoes the body to stdout.
post_json() {
  # $1 = url, $2 = json body, $3 = optional bearer token
  local url="$1" body="$2" token="${3:-}" tmp code
  tmp="$(mktemp)"
  if [ -n "$token" ]; then
    code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$url" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $token" \
      --data "$body")"
  else
    code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$url" \
      -H 'Content-Type: application/json' --data "$body")"
  fi
  local out; out="$(cat "$tmp")"; rm -f "$tmp"
  case "$code" in
    2*) printf '%s' "$out"; return 0 ;;
    *)  fail "POST $url failed ($code): $out" ;;
  esac
}

post_license_bundle() {
  # $1 = url
  local url="$1" tmp code
  tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$url" \
    -F "bundle=@${LICENSE_BUNDLE_ZIP_PATH};type=application/zip")"
  local out; out="$(cat "$tmp")"; rm -f "$tmp"
  case "$code" in
    2*) printf '%s' "$out"; return 0 ;;
    *)  fail "POST $url failed ($code): $out" ;;
  esac
}

if [ "$SETUP_OPEN" = "true" ]; then
  [ -n "$OPERATOR_EMAIL" ] && [ -n "$OPERATOR_PASSWORD" ] || \
    fail "operatorEmail and operatorPassword are required to bootstrap the operator."

  case "$LICENSE_BUNDLE_ZIP_PATH" in
    ""|PASTE-*) fail "licenseBundleZipPath is not set in the environment file. Set it before running setup." ;;
  esac
  [ -f "$LICENSE_BUNDLE_ZIP_PATH" ] || fail "licenseBundleZipPath does not point to a file: $LICENSE_BUNDLE_ZIP_PATH"

  echo "Previewing license bundle import..."
  post_license_bundle "$PLATFORM_URL/api/platform/setup/v1/license/import/preview" >/dev/null
  echo "  License bundle preview accepted."

  echo "Importing license bundle..."
  post_license_bundle "$PLATFORM_URL/api/platform/setup/v1/license/import" >/dev/null
  echo "  License bundle imported."

  echo "Bootstrapping platform operator..."
  BOOTSTRAP_BODY="$(node -e 'process.stdout.write(JSON.stringify({adminEmail:process.argv[1],adminDisplayName:process.argv[2]}))' \
    "$OPERATOR_EMAIL" "$OPERATOR_DISPLAY_NAME")"
  BOOTSTRAP_RESPONSE="$(post_json "$PLATFORM_URL/api/platform/setup/v1/bootstrap" "$BOOTSTRAP_BODY")"
  ACTIVATION_TOKEN="$(node -e '
    const value = JSON.parse(process.argv[1]);
    const link = value?.activation?.manualActivationLink;
    if (!link || !link.includes("#")) process.exit(2);
    process.stdout.write(link.split("#", 2)[1]);
  ' "$BOOTSTRAP_RESPONSE")" || \
    fail "Platform bootstrap did not return the manual activation link required by unattended provisioning."
  ACTIVATION_BODY="$(node -e 'process.stdout.write(JSON.stringify({token:process.argv[1],password:process.argv[2]}))' \
    "$ACTIVATION_TOKEN" "$OPERATOR_PASSWORD")"
  post_json "$PLATFORM_URL/api/account-actions/v1/complete" "$ACTIVATION_BODY" >/dev/null
  echo "  Operator activated; setup gate closed."
fi

# --- Step 3: operator sign-in (PKCE authorization-code flow) -------------------
[ -n "$OPERATOR_EMAIL" ] && [ -n "$OPERATOR_PASSWORD" ] || \
  fail "operatorEmail and operatorPassword are required to sign in."
[ -n "$OPERATOR_REDIRECT_URI" ]  || fail "operatorRedirectUri is not set."
[ -n "$OPERATOR_CODE_VERIFIER" ] || fail "operatorCodeVerifier is not set."

echo "Signing in as operator..."

# Compute S256(code_verifier) -> base64url without padding.
CODE_CHALLENGE="$(node -e '
  const crypto = require("crypto");
  const c = crypto.createHash("sha256").update(process.argv[1]).digest("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  process.stdout.write(c);
' "$OPERATOR_CODE_VERIFIER")"
[ -n "$CODE_CHALLENGE" ] || fail "Failed to compute PKCE code challenge."

STATE="operator-state-$(node -e 'process.stdout.write(require("crypto").randomBytes(6).toString("hex"))')"

urlencode() { node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"; }
urldecode() { node -e 'process.stdout.write(decodeURIComponent(process.argv[1]))' "$1"; }

# Read a response header value (case-insensitive) from a curl -D dump file.
header_value() {
  # $1 = dump file, $2 = header name
  awk -v h="$2" 'BEGIN{IGNORECASE=1} $0 ~ "^"h":" {sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); val=$0} END{print val}' "$1"
}

abs_url() {
  # Prefix a relative Location with the platform base URL.
  case "$1" in
    http://*|https://*) printf '%s' "$1" ;;
    *) printf '%s%s' "$PLATFORM_URL" "$1" ;;
  esac
}

# 3.1 Start the authorization request; prompt=login forces a fresh login form
# even when a previous operator browser session cookie exists.
AUTHORIZE_URL="$PLATFORM_URL/authorize?response_type=code&client_id=platform-operator-cli&redirect_uri=$(urlencode "$OPERATOR_REDIRECT_URI")&scope=openid&state=$STATE&prompt=login&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256"
HDR="$(mktemp)"
curl -s -o /dev/null -D "$HDR" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$AUTHORIZE_URL"
LOGIN_PAGE_URL="$(header_value "$HDR" Location)"
rm -f "$HDR"
[ -n "$LOGIN_PAGE_URL" ] || fail "authorize did not redirect to the login page."
LOGIN_PAGE_URL="$(abs_url "$LOGIN_PAGE_URL")"

SESSION_ID=""; RETURN_URL=""
if [[ "$LOGIN_PAGE_URL" =~ [?\&]session_id=([^\&]+) ]]; then SESSION_ID="$(urldecode "${BASH_REMATCH[1]}")"; fi
if [[ "$LOGIN_PAGE_URL" =~ [?\&]return_url=([^\&]+) ]]; then RETURN_URL="$(urldecode "${BASH_REMATCH[1]}")"; fi

# 3.2 Load the login page (sets CSRF cookie; embeds tab_id and session_code).
LOGIN_HTML="$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$LOGIN_PAGE_URL")"
TAB_ID=""; SESSION_CODE=""
if [[ "$LOGIN_HTML" =~ name=\"tab_id\"[[:space:]]+value=\"([^\"]+)\" ]]; then TAB_ID="${BASH_REMATCH[1]}"; fi
if [[ "$LOGIN_HTML" =~ name=\"session_code\"[[:space:]]+value=\"([^\"]+)\" ]]; then SESSION_CODE="${BASH_REMATCH[1]}"; fi

# 3.3 Submit credentials with the CSRF tuple; capture the callback redirect.
HDR="$(mktemp)"
curl -s -o /dev/null -D "$HDR" -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST "$PLATFORM_URL/login" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "username=$OPERATOR_EMAIL" \
  --data-urlencode "password=$OPERATOR_PASSWORD" \
  --data-urlencode "session_id=$SESSION_ID" \
  --data-urlencode "tab_id=$TAB_ID" \
  --data-urlencode "session_code=$SESSION_CODE" \
  --data-urlencode "return_url=$RETURN_URL"
CALLBACK_URL="$(header_value "$HDR" Location)"
rm -f "$HDR"
[ -n "$CALLBACK_URL" ] || fail "Operator login did not return a callback Location."
case "$CALLBACK_URL" in
  *error=invalid_credentials*) fail "Operator login rejected: invalid credentials." ;;
esac
CALLBACK_URL="$(abs_url "$CALLBACK_URL")"

# 3.4 Resume the authorization callback to obtain the authorization code.
HDR="$(mktemp)"
curl -s -o /dev/null -D "$HDR" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$CALLBACK_URL"
REDIRECT_WITH_CODE="$(header_value "$HDR" Location)"
rm -f "$HDR"
[ -n "$REDIRECT_WITH_CODE" ] || fail "Authorization callback did not return a redirect with code."
AUTH_CODE=""
if [[ "$REDIRECT_WITH_CODE" =~ [?\&\#]code=([^\&]+) ]]; then AUTH_CODE="$(urldecode "${BASH_REMATCH[1]}")"; fi
[ -n "$AUTH_CODE" ] || fail "Authorization code not found in callback redirect."

# 3.5 Exchange the code for an operator access token.
TOKEN_RESPONSE="$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST "$PLATFORM_URL/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode "code=$AUTH_CODE" \
  --data-urlencode "redirect_uri=$OPERATOR_REDIRECT_URI" \
  --data-urlencode 'client_id=platform-operator-cli' \
  --data-urlencode "code_verifier=$OPERATOR_CODE_VERIFIER")"
OPERATOR_TOKEN="$(json_field "$TOKEN_RESPONSE" access_token)"
[ -n "$OPERATOR_TOKEN" ] || fail "No access_token returned from /token: $TOKEN_RESPONSE"
echo "  Operator signed in."

# --- Step 4: register the first production tenant -----------------------------
echo "Registering tenant '$TENANT_NAME' ($TENANT_SLUG)..."
TENANTS_URL="$PLATFORM_URL/api/platform/admin/v1/tenants"
TENANT_BODY="$(node -e '
  const [name, slug] = [process.argv[1], process.argv[2]];
  process.stdout.write(JSON.stringify({
    tenantType: "organization",
    name,
    description: name + " issuing and verification tenant",
    slug,
    addIssuer: true,
    addVerifier: true,
    owner: { type: "local", email: "admin@" + slug + ".example", displayName: name + " Administrator" },
    ownerDelivery: { mode: "none" }
  }));
' "$TENANT_NAME" "$TENANT_SLUG")"

TMP="$(mktemp)"
CODE="$(curl -s -o "$TMP" -w '%{http_code}' -X POST "$TENANTS_URL" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $OPERATOR_TOKEN" \
  --data "$TENANT_BODY")"
BODY="$(cat "$TMP")"; rm -f "$TMP"

TENANT_ID=""
case "$CODE" in
  2*)
    TENANT_ID="$(json_field "$BODY" tenant.id)"
    [ -n "$TENANT_ID" ] || TENANT_ID="$(json_field "$BODY" id)"
    echo "  Tenant registered: $TENANT_ID"
    ;;
  409)
    echo "  Tenant '$TENANT_SLUG' already exists; continuing."
    LIST="$(curl -s "$TENANTS_URL" -H "Authorization: Bearer $OPERATOR_TOKEN")"
    TENANT_ID="$(node -e '
      let data=""; process.stdin.on("data",c=>data+=c);
      process.stdin.on("end",()=>{
        let o; try{o=JSON.parse(data);}catch(e){return;}
        const items = o.items || o.tenants || (Array.isArray(o) ? o : []);
        const slug = process.argv[1];
        const m = items.find(t => t && t.slug === slug);
        if (m && m.id) process.stdout.write(String(m.id));
      });
    ' "$TENANT_SLUG" <<<"$LIST")"
    ;;
  *)
    fail "Tenant registration failed ($CODE): $BODY"
    ;;
esac
[ -n "$TENANT_ID" ] || fail "Could not determine tenantId; cannot verify tenant gateway endpoint bindings."

# --- Step 5: verify tenant setup-created gateway endpoint bindings ------------
verify_endpoint_bindings() {
  # $1 = JSON response body, $2 = expected tenant gateway host
  node -e '
    let data = "";
    process.stdin.on("data", c => data += c);
    process.stdin.on("end", () => {
      const expectedHost = process.argv[1];
      let obj;
      try { obj = JSON.parse(data); } catch (e) {
        console.error("endpoint binding response is not JSON");
        process.exit(1);
      }
      const endpoints = obj.data || obj.items || obj.endpoints || (Array.isArray(obj) ? obj : []);
      const serviceTypes = endpoints.map(endpoint => endpoint && endpoint.serviceType).filter(Boolean);
      const required = ["OAUTH2_AUTHORIZATION_SERVER", "OID4VCI_ISSUER", "OID4VP_VERIFIER"];
      const missing = required.filter(kind => !serviceTypes.includes(kind));
      if (missing.length) {
        console.error("missing endpoint binding(s): " + missing.join(", "));
        process.exit(1);
      }
      const hasHost = endpoints.some(endpoint => {
        if (!endpoint) return false;
        return endpoint.host === expectedHost ||
          String(endpoint.url || "").includes("://" + expectedHost) ||
          String(endpoint.baseUrl || "").includes("://" + expectedHost) ||
          String(endpoint.publicUrl || "").includes("://" + expectedHost);
      });
      if (!hasHost) {
        console.error("endpoint bindings do not include expected host " + expectedHost);
        process.exit(1);
      }
    });
  ' "$2" <<<"$1"
}

echo "Verifying tenant setup-created gateway protocol routes..."
TMP="$(mktemp)"
CODE="$(curl -s -o "$TMP" -w '%{http_code}' "$PLATFORM_URL/api/platform/admin/v1/tenants/$TENANT_ID/public-endpoints" \
  -H "Authorization: Bearer $OPERATOR_TOKEN")"
ENDPOINTS_BODY="$(cat "$TMP")"; rm -f "$TMP"
case "$CODE" in
  2*) ;;
  *) fail "GET tenant gateway endpoint bindings failed ($CODE): $ENDPOINTS_BODY" ;;
esac
verify_endpoint_bindings "$ENDPOINTS_BODY" "$TENANT_HOST" || \
  fail "Tenant setup did not create the expected gateway endpoint bindings."
echo "  Verified platform-created route bindings for $TENANT_HOST."

# --- Step 6: summary ----------------------------------------------------------
echo ""
echo "==================== Tenant onboarded ===================="
echo "Operator console : $ADMIN_CONSOLE_URL"
echo "Tenant           : $TENANT_NAME [$TENANT_SLUG] ($TENANT_ID)"
echo "Tenant gateway   : $TENANT_GATEWAY_URL"
echo ""
[ -n "$TENANT_GATEWAY_URL" ] && echo "OID4VCI metadata : ${TENANT_GATEWAY_URL%/}/.well-known/openid-credential-issuer"
[ -n "$TENANT_GATEWAY_URL" ] && echo "OAuth metadata   : ${TENANT_GATEWAY_URL%/}/.well-known/oauth-authorization-server"
[ -n "$TENANT_GATEWAY_URL" ] && echo "DID document     : ${TENANT_GATEWAY_URL%/}/.well-known/did.json"
echo "========================================================="
exit 0
