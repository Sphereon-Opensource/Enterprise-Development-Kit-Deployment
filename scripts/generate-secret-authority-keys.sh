#!/usr/bin/env bash
# Mints one fresh Ed25519 secret-authority key window for customer Compose.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
AUTHORITY_ROOT="$SCRIPT_DIR/../compose/.secret-authority"
OUT_DIR="${1:-}"
if [[ -z "$OUT_DIR" ]]; then
  echo "usage: $(basename "$0") <output-dir> [workload ...]" >&2
  exit 2
fi
shift || true

mkdir -p "$AUTHORITY_ROOT" "$(dirname -- "$OUT_DIR")"
AUTHORITY_ROOT="$(cd "$AUTHORITY_ROOT" && pwd -P)"
OUT_DIR="$(cd "$(dirname -- "$OUT_DIR")" && pwd -P)/$(basename -- "$OUT_DIR")"
case "$OUT_DIR/" in
  "$AUTHORITY_ROOT"/*) ;;
  *) echo "secret-authority output must be below $AUTHORITY_ROOT" >&2; exit 2 ;;
esac

WORKLOADS=("$@")
if [[ ${#WORKLOADS[@]} -eq 0 ]]; then
  WORKLOADS=(service-platform service-crypto service-data service-blob service-tenant-as service-oid4vci service-oid4vp)
fi
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }
for workload in "${WORKLOADS[@]}"; do
  [[ "$workload" =~ ^[a-z0-9-]+$ ]] || { echo "invalid workload: $workload" >&2; exit 2; }
done

rm -rf -- "$OUT_DIR"
mkdir -p "$OUT_DIR/central" "$OUT_DIR/public" "$OUT_DIR/workload"
mint_pair() {
  local private_path="$1" public_path="$2"
  mkdir -p "$(dirname -- "$private_path")" "$(dirname -- "$public_path")"
  openssl genpkey -algorithm ED25519 -out "$private_path" >/dev/null 2>&1
  openssl pkey -in "$private_path" -pubout -out "$public_path" >/dev/null 2>&1
  chmod 600 "$private_path" 2>/dev/null || true
  chmod 644 "$public_path" 2>/dev/null || true
}

mint_pair "$OUT_DIR/central/permit-signing.pem" "$OUT_DIR/public/central-permit.pub.pem"
for workload in "${WORKLOADS[@]}"; do
  mint_pair "$OUT_DIR/workload/$workload/assertion.pem" "$OUT_DIR/public/$workload-assertion.pub.pem"
done

NOW_MILLIS="$(( $(date +%s) * 1000 ))"
FROM_MILLIS="$(( NOW_MILLIS - 3600000 ))"
UNTIL_MILLIS="$(( NOW_MILLIS + 315360000000 ))"
KEY_ID="secret-authority-$NOW_MILLIS"
MOUNT_ROOT="/app/secret-authority"
CENTRAL_VERIFICATION_KEYS=""
for workload in "${WORKLOADS[@]}"; do
  entry="$KEY_ID|$workload|1|$FROM_MILLIS|$UNTIL_MILLIS|$MOUNT_ROOT/public/$workload-assertion.pub.pem"
  CENTRAL_VERIFICATION_KEYS="${CENTRAL_VERIFICATION_KEYS:+$CENTRAL_VERIFICATION_KEYS,}$entry"
done
{
  echo "SECRET_AUTHORITY_KEY_ID=$KEY_ID"
  echo "SECRET_AUTHORITY_ACTIVE_FROM_MILLIS=$FROM_MILLIS"
  echo "SECRET_AUTHORITY_ACTIVE_UNTIL_MILLIS=$UNTIL_MILLIS"
  echo "SECRET_AUTHORITY_WORKLOADS=${WORKLOADS[*]}"
  echo "SECRET_AUTHORITY_CENTRAL_PERMIT_SIGNING_KEY=$KEY_ID|$FROM_MILLIS|$UNTIL_MILLIS|$MOUNT_ROOT/central/permit-signing.pem"
  echo "SECRET_AUTHORITY_CENTRAL_ASSERTION_VERIFICATION_KEYS=$CENTRAL_VERIFICATION_KEYS"
  echo "SECRET_AUTHORITY_SATELLITE_ASSERTION_SIGNING_KEY=$KEY_ID|$FROM_MILLIS|$UNTIL_MILLIS|$MOUNT_ROOT/workload/assertion.pem"
  echo "SECRET_AUTHORITY_SATELLITE_PERMIT_VERIFICATION_KEYS=$KEY_ID|$FROM_MILLIS|$UNTIL_MILLIS|$MOUNT_ROOT/public/central-permit.pub.pem"
} > "$OUT_DIR/window.env"
echo "secret-authority key material written to $OUT_DIR for ${#WORKLOADS[@]} workloads"
