#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOYMENT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=upgrade-path.sh
source "$SCRIPT_DIR/upgrade-path.sh"

RELEASE_NAME="sphereon-edk-enterprise"
NAMESPACE="edk"
VALUES_FILE=""
CHART_PATH="$DEPLOYMENT_ROOT/helm/edk-enterprise"
IMAGE_TAG=""
RUNTIME_SECRET_NAME="edk-runtime-secrets"
PIPELINE_SECRET_NAME="edk-issuer-pipeline-secrets"
TENANT_HOST=""
TIMEOUT="15m"
BACKUP_ROOT="./edk-upgrade-backup"
CANDIDATE_FILE=""
INTERMEDIATE_CANDIDATE_FILE=""
MIGRATION_VALUE_FILES=()
AUTO_MIGRATION_VALUE_FILES=()
INTERMEDIATE_MIGRATION_VALUE_FILES=()
INTERMEDIATE_IMAGE_TAG=""
INSTALLED_IMAGE_TAG=""
RELEASE_SET_EVIDENCE=""
RELEASE_IDENTITY_FILE=""

usage() {
  cat <<'EOF'
Install or safely upgrade EDK Enterprise with the selected Helm chart.

Usage:
  bash ./scripts/upgrade-helm.sh --values ./customer-values.yaml [options]

Required:
  --values PATH                 Maintained installation values file.

Options:
  --release NAME                Helm release (default: sphereon-edk-enterprise).
  --namespace NAME              Kubernetes namespace (default: edk).
  --chart PATH                  Chart directory (default: ../helm/edk-enterprise).
  --image-tag TAG               Override the target image tag. When omitted, use
                                the selected chart/site values.
  --migration-values PATH       Optional release-specific values overlay. May be
                                repeated and is applied after automatically
                                selected release-transition overlays.
  --runtime-secret NAME         Runtime Secret name (default: edk-runtime-secrets).
  --pipeline-secret NAME        Issuer pipeline Secret name.
  --tenant-host HOST            Verify did.json for this tenant host after rollout.
  --timeout DURATION            Helm/kubectl timeout (default: 15m).
  --backup-root PATH            Backup parent directory.
  --release-set-evidence PATH   Canonical enterprise-image-set.json for an
                                immutable RC3 upgrade (required for RC3 tags).
  -h, --help                    Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' was not found on PATH."
}

absolute_file() {
  local path="$1"
  local directory base
  [[ -f "$path" ]] || die "File does not exist: $path"
  directory="$(cd -- "$(dirname -- "$path")" && pwd -P)"
  base="$(basename -- "$path")"
  printf '%s/%s\n' "$directory" "$base"
}

absolute_directory() {
  local path="$1"
  [[ -d "$path" ]] || die "Directory does not exist: $path"
  (cd -- "$path" && pwd -P)
}

base64url_secret() {
  local byte_count="${1:-48}"
  openssl rand -base64 "$byte_count" | tr -d '\n=' | tr '/+' '_-'
}

secret_exists() {
  kubectl -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1
}

secret_key_value() {
  local secret_name="$1"
  local key="$2"
  kubectl -n "$NAMESPACE" get secret "$secret_name" \
    -o "go-template={{ with index .data \"$key\" }}{{ . }}{{ end }}" 2>/dev/null || true
}

secret_has_key() {
  [[ -n "$(secret_key_value "$1" "$2")" ]]
}

apply_secret_fields() {
  local secret_name="$1"
  local json_fields="$2"

  printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"%s"},"type":"Opaque","stringData":{%s}}\n' \
    "$secret_name" "$NAMESPACE" "$json_fields" |
    kubectl apply --server-side --field-manager=edk-helm-upgrade -f -
}

cleanup() {
  if [[ -n "$CANDIDATE_FILE" && -f "$CANDIDATE_FILE" ]]; then
    rm -f -- "$CANDIDATE_FILE"
  fi
  if [[ -n "$INTERMEDIATE_CANDIDATE_FILE" && -f "$INTERMEDIATE_CANDIDATE_FILE" ]]; then
    rm -f -- "$INTERMEDIATE_CANDIDATE_FILE"
  fi
  if [[ -n "$RELEASE_IDENTITY_FILE" && -f "$RELEASE_IDENTITY_FILE" ]]; then
    rm -f -- "$RELEASE_IDENTITY_FILE"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --values) VALUES_FILE="${2:-}"; shift 2 ;;
    --release) RELEASE_NAME="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --chart) CHART_PATH="${2:-}"; shift 2 ;;
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    --migration-values) MIGRATION_VALUE_FILES+=("${2:-}"); shift 2 ;;
    --runtime-secret) RUNTIME_SECRET_NAME="${2:-}"; shift 2 ;;
    --pipeline-secret) PIPELINE_SECRET_NAME="${2:-}"; shift 2 ;;
    --tenant-host) TENANT_HOST="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
    --release-set-evidence) RELEASE_SET_EVIDENCE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$VALUES_FILE" ]] || { usage >&2; die "--values is required."; }
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid Kubernetes namespace: $NAMESPACE"
[[ "$RUNTIME_SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid runtime Secret name."
[[ "$PIPELINE_SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Invalid pipeline Secret name."
if [[ "$IMAGE_TAG" =~ ^0\.25\.0-RC3([._-][A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
  [[ -n "$RELEASE_SET_EVIDENCE" ]] ||
    die "--release-set-evidence is required for immutable RC3 upgrades."
fi

require_command helm
require_command kubectl
require_command openssl
require_command node

if [[ -n "$RELEASE_SET_EVIDENCE" ]]; then
  RELEASE_SET_EVIDENCE="$(absolute_file "$RELEASE_SET_EVIDENCE")"
  RELEASE_IDENTITY_FILE="$(mktemp "${TMPDIR:-/tmp}/edk-release-identity.XXXXXX")"
  RELEASE_EVIDENCE_PATH="$RELEASE_SET_EVIDENCE" \
  RELEASE_REQUESTED_TAG="$IMAGE_TAG" \
  RELEASE_IDENTITY_PATH="$RELEASE_IDENTITY_FILE" \
    node -e '
      const crypto = require("node:crypto");
      const fs = require("node:fs");
      const report = JSON.parse(fs.readFileSync(process.env.RELEASE_EVIDENCE_PATH, "utf8"));
      const build = report.releaseBuild || {};
      const fields = ["version", "source", "revision", "created", "sourceFingerprint"];
      if (report.tag !== process.env.RELEASE_REQUESTED_TAG ||
          build.version !== process.env.RELEASE_REQUESTED_TAG ||
          !Array.isArray(report.images) || report.images.length !== 7 ||
          fields.some((field) => !build[field]) ||
          !/^sha256:[a-f0-9]{64}$/.test(build.sourceFingerprint) ||
          report.images.some((image) => !/^sha256:[a-f0-9]{64}$/.test(image.localContentId || ""))) {
        throw new Error("release-set evidence does not bind the requested tag to seven immutable image bytes and one provenance tuple");
      }
      const canonical = Object.fromEntries(fields.map((field) => [field, build[field]]));
      const identity = {
        schemaVersion: 1,
        tag: report.tag,
        releaseBuild: canonical,
        identitySha256: `sha256:${crypto.createHash("sha256").update(JSON.stringify(canonical)).digest("hex")}`,
      };
      fs.writeFileSync(process.env.RELEASE_IDENTITY_PATH, JSON.stringify(identity, null, 2) + "\n", { mode: 0o600 });
    '
fi

# Helm 4 renamed the rollback behavior exposed by Helm 3's --atomic flag.
# Select the supported spelling so this release-independent wrapper works on
# both currently common Helm major versions.
HELM_UPGRADE_SAFETY_ARGS=(--wait)
if helm upgrade --help 2>/dev/null | grep -q -- '--rollback-on-failure'; then
  HELM_UPGRADE_SAFETY_ARGS+=(--rollback-on-failure --cleanup-on-fail)
else
  HELM_UPGRADE_SAFETY_ARGS+=(--atomic)
fi

VALUES_FILE="$(absolute_file "$VALUES_FILE")"
CHART_PATH="$(absolute_directory "$CHART_PATH")"

BASE_VALUE_ARGS=(
  -f "$VALUES_FILE"
)
SECRET_VALUE_ARGS=(
  --set-string "serviceIdentity.internalClientExistingSecret=$RUNTIME_SECRET_NAME"
  --set-string "keystore.existingSecret=$RUNTIME_SECRET_NAME"
  --set-string "portalBff.existingSecret=$RUNTIME_SECRET_NAME"
  --set-string "issuerPipeline.existingSecret=$PIPELINE_SECRET_NAME"
)

append_unique_file() {
  local candidate="$1"
  shift
  local existing
  for existing in "$@"; do
    [[ "$existing" == "$candidate" ]] && return 1
  done
  return 0
}

RC1_TO_RC2_VALUES="$DEPLOYMENT_ROOT/helm/edk-enterprise/examples/upgrades/0.25.0-rc1-to-0.25.0-rc2-values.yaml"
V0_25_0_RC2_TO_V0_25_0_RC3_VALUES="$DEPLOYMENT_ROOT/helm/edk-enterprise/examples/upgrades/0.25.0-rc2-to-0.25.0-rc3-values.yaml"

# Resolve the currently installed immutable image tag before rendering. Known
# release transitions are selected automatically. Compatibility overlays are
# cumulative for the target release so rerunning an upgrade with the original
# customer values cannot undo an earlier transition. RC1 -> RC3 is deliberately
# executed as two Helm revisions (RC1 -> RC2 -> RC3), not collapsed into one.
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  INSTALLED_IMAGE_TAG="$(
    helm get values "$RELEASE_NAME" -n "$NAMESPACE" -a -o json |
      edk_extract_global_image_tag
  )"
fi

if [[ -n "$INSTALLED_IMAGE_TAG" && -n "$IMAGE_TAG" ]]; then
  if ! edk_plan_known_upgrade_path \
    "$INSTALLED_IMAGE_TAG" \
    "$IMAGE_TAG" \
    "$(absolute_file "$RC1_TO_RC2_VALUES")" \
    "$(absolute_file "$V0_25_0_RC2_TO_V0_25_0_RC3_VALUES")"; then
    die "Refusing unsupported release downgrade: $INSTALLED_IMAGE_TAG -> $IMAGE_TAG"
  fi
  AUTO_MIGRATION_VALUE_FILES=("${EDK_AUTO_MIGRATION_VALUE_FILES[@]}")
  INTERMEDIATE_MIGRATION_VALUE_FILES=("${EDK_INTERMEDIATE_MIGRATION_VALUE_FILES[@]}")
  INTERMEDIATE_IMAGE_TAG="$EDK_INTERMEDIATE_IMAGE_TAG"
fi

RESOLVED_MIGRATION_VALUE_FILES=("${AUTO_MIGRATION_VALUE_FILES[@]}")
for migration_values in "${MIGRATION_VALUE_FILES[@]}"; do
  [[ -n "$migration_values" ]] || die "--migration-values requires a path."
  migration_values="$(absolute_file "$migration_values")"
  if append_unique_file "$migration_values" "${RESOLVED_MIGRATION_VALUE_FILES[@]}"; then
    RESOLVED_MIGRATION_VALUE_FILES+=("$migration_values")
  fi
done

VALUE_ARGS=("${BASE_VALUE_ARGS[@]}")
for migration_values in "${RESOLVED_MIGRATION_VALUE_FILES[@]}"; do
  VALUE_ARGS+=( -f "$migration_values" )
done
if [[ -n "$IMAGE_TAG" ]]; then
  VALUE_ARGS+=( --set-string "global.imageTag=$IMAGE_TAG" )
fi
VALUE_ARGS+=("${SECRET_VALUE_ARGS[@]}")

INTERMEDIATE_VALUE_ARGS=()
if [[ -n "$INTERMEDIATE_IMAGE_TAG" ]]; then
  INTERMEDIATE_VALUE_ARGS=("${BASE_VALUE_ARGS[@]}")
  for migration_values in "${INTERMEDIATE_MIGRATION_VALUE_FILES[@]}"; do
    INTERMEDIATE_VALUE_ARGS+=( -f "$migration_values" )
  done
  INTERMEDIATE_VALUE_ARGS+=(
    --set-string "global.imageTag=$INTERMEDIATE_IMAGE_TAG"
    "${SECRET_VALUE_ARGS[@]}"
  )
fi

# Reject invalid values before making any cluster changes.
printf 'Linting and rendering the candidate release.\n'
helm lint "$CHART_PATH" "${VALUE_ARGS[@]}"
CANDIDATE_FILE="$(mktemp "${TMPDIR:-/tmp}/edk-helm-candidate.XXXXXX")"
helm template "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  "${VALUE_ARGS[@]}" >"$CANDIDATE_FILE"
if [[ -n "$INTERMEDIATE_IMAGE_TAG" ]]; then
  printf 'Linting and rendering required intermediate release %s.\n' "$INTERMEDIATE_IMAGE_TAG"
  helm lint "$CHART_PATH" "${INTERMEDIATE_VALUE_ARGS[@]}"
  INTERMEDIATE_CANDIDATE_FILE="$(mktemp "${TMPDIR:-/tmp}/edk-helm-intermediate.XXXXXX")"
  helm template "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
    "${INTERMEDIATE_VALUE_ARGS[@]}" >"$INTERMEDIATE_CANDIDATE_FILE"
fi

CONTEXT="$(kubectl config current-context)"
printf 'Kubernetes context: %s\n' "$CONTEXT"
printf 'Release: %s; namespace: %s; image override: %s\n' \
  "$RELEASE_NAME" "$NAMESPACE" "${IMAGE_TAG:-<chart/site values>}"
if [[ -n "$INSTALLED_IMAGE_TAG" ]]; then
  printf 'Detected installed image tag: %s\n' "$INSTALLED_IMAGE_TAG"
fi
if [[ ${#AUTO_MIGRATION_VALUE_FILES[@]} -gt 0 ]]; then
  printf 'Automatically selected migration values:\n'
  printf '  %s\n' "${AUTO_MIGRATION_VALUE_FILES[@]}"
fi
if [[ -n "$INTERMEDIATE_IMAGE_TAG" ]]; then
  printf 'Required ordered upgrade path: %s -> %s -> %s\n' \
    "$INSTALLED_IMAGE_TAG" "$INTERMEDIATE_IMAGE_TAG" "$IMAGE_TAG"
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create namespace "$NAMESPACE"
fi

# Never rotate an existing internal-client or keystore credential implicitly.
if ! secret_exists "$RUNTIME_SECRET_NAME"; then
  printf 'Creating new runtime Secret/%s.\n' "$RUNTIME_SECRET_NAME"
  INTERNAL_CLIENT_SECRET="$(base64url_secret 48)"
  KEYSTORE_PASSWORD="$(base64url_secret 48)"
  PORTAL_BFF_SECRET="$(base64url_secret 48)"
  apply_secret_fields "$RUNTIME_SECRET_NAME" \
    "\"internal-client-secret\":\"$INTERNAL_CLIENT_SECRET\",\"keystore-password\":\"$KEYSTORE_PASSWORD\",\"admin-console-portal-bff-secret\":\"$PORTAL_BFF_SECRET\""
  unset INTERNAL_CLIENT_SECRET KEYSTORE_PASSWORD PORTAL_BFF_SECRET
else
  for required_key in internal-client-secret keystore-password; do
    secret_has_key "$RUNTIME_SECRET_NAME" "$required_key" ||
      die "Existing Secret/$RUNTIME_SECRET_NAME is missing '$required_key'. Restore the original value; it is unsafe to generate a replacement during an upgrade."
  done
  if ! secret_has_key "$RUNTIME_SECRET_NAME" admin-console-portal-bff-secret; then
    printf 'Adding the missing portal BFF key without changing existing runtime credentials.\n'
    PORTAL_BFF_SECRET="$(base64url_secret 48)"
    apply_secret_fields "$RUNTIME_SECRET_NAME" \
      "\"admin-console-portal-bff-secret\":\"$PORTAL_BFF_SECRET\""
    unset PORTAL_BFF_SECRET
  fi
fi

for required_key in internal-client-secret keystore-password admin-console-portal-bff-secret; do
  secret_has_key "$RUNTIME_SECRET_NAME" "$required_key" ||
    die "Secret/$RUNTIME_SECRET_NAME is missing '$required_key' after runtime-secret reconciliation."
done

if ! secret_exists "$PIPELINE_SECRET_NAME"; then
  printf 'Creating issuer pipeline Secret/%s.\n' "$PIPELINE_SECRET_NAME"
  PIPELINE_MASTER_KEK="$(base64url_secret 32)"
  PIPELINE_BLIND_INDEX_KEY="$(base64url_secret 32)"
  [[ "$PIPELINE_MASTER_KEK" != "$PIPELINE_BLIND_INDEX_KEY" ]] ||
    die "Random generation unexpectedly produced duplicate issuer pipeline keys."
  apply_secret_fields "$PIPELINE_SECRET_NAME" \
    "\"master-kek\":\"$PIPELINE_MASTER_KEK\",\"blind-index-key\":\"$PIPELINE_BLIND_INDEX_KEY\""
  unset PIPELINE_MASTER_KEK PIPELINE_BLIND_INDEX_KEY
else
  for required_key in master-kek blind-index-key; do
    secret_has_key "$PIPELINE_SECRET_NAME" "$required_key" ||
      die "Existing Secret/$PIPELINE_SECRET_NAME is missing '$required_key'. Refusing a partial pipeline-key rotation."
  done
  [[ "$(secret_key_value "$PIPELINE_SECRET_NAME" master-kek)" != \
     "$(secret_key_value "$PIPELINE_SECRET_NAME" blind-index-key)" ]] ||
    die "Existing Secret/$PIPELINE_SECRET_NAME reuses the same value for both pipeline keys."
fi

for required_key in master-kek blind-index-key; do
  secret_has_key "$PIPELINE_SECRET_NAME" "$required_key" ||
    die "Secret/$PIPELINE_SECRET_NAME is missing '$required_key' after issuer-pipeline reconciliation."
done

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$RELEASE_NAME-$TIMESTAMP"
mkdir -p -- "$BACKUP_DIR"
if [[ -n "$RELEASE_IDENTITY_FILE" ]]; then
  cp -- "$RELEASE_SET_EVIDENCE" "$BACKUP_DIR/enterprise-image-set.json"
  cp -- "$RELEASE_IDENTITY_FILE" "$BACKUP_DIR/release-identity.json"
fi

if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'Backing up the current Helm release to %s.\n' "$BACKUP_DIR"
  helm get values "$RELEASE_NAME" -n "$NAMESPACE" -a >"$BACKUP_DIR/installed-values.yaml"
  helm get manifest "$RELEASE_NAME" -n "$NAMESPACE" >"$BACKUP_DIR/installed-manifest.yaml"
  helm history "$RELEASE_NAME" -n "$NAMESPACE" >"$BACKUP_DIR/helm-history.txt"
fi

kubectl -n "$NAMESPACE" get pods -o wide >"$BACKUP_DIR/pods-before.txt"
kubectl -n "$NAMESPACE" get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{end}' \
  >"$BACKUP_DIR/image-digests-before.txt"
cp -- "$CANDIDATE_FILE" "$BACKUP_DIR/candidate-manifest.yaml"
if [[ -n "$INTERMEDIATE_CANDIDATE_FILE" ]]; then
  cp -- "$INTERMEDIATE_CANDIDATE_FILE" "$BACKUP_DIR/intermediate-rc2-candidate-manifest.yaml"
fi

wait_for_release_deployments() {
  kubectl -n "$NAMESPACE" get deployment \
    -l "app.kubernetes.io/instance=$RELEASE_NAME" -o name |
    while IFS= read -r deployment; do
      [[ -n "$deployment" ]] || continue
      kubectl -n "$NAMESPACE" rollout status "$deployment" --timeout "$TIMEOUT"
    done
}

if [[ -n "$INTERMEDIATE_IMAGE_TAG" ]]; then
  printf 'Performing required intermediate Helm upgrade to %s.\n' "$INTERMEDIATE_IMAGE_TAG"
  helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
    -n "$NAMESPACE" --create-namespace \
    "${INTERMEDIATE_VALUE_ARGS[@]}" \
    "${HELM_UPGRADE_SAFETY_ARGS[@]}" --timeout "$TIMEOUT"
  wait_for_release_deployments
fi

printf 'Performing rollback-on-failure Helm upgrade/install.\n'
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  -n "$NAMESPACE" --create-namespace \
  "${VALUE_ARGS[@]}" \
  "${HELM_UPGRADE_SAFETY_ARGS[@]}" --timeout "$TIMEOUT"

wait_for_release_deployments

if [[ -n "$TENANT_HOST" ]]; then
  # Kubernetes resource names cannot contain whitespace, so shell word splitting
  # is safe here and keeps compatibility with the Bash 3.2 shipped by macOS.
  DID_SERVICES="$(kubectl -n "$NAMESPACE" get service \
    -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=did" \
    -o jsonpath='{.items[*].metadata.name}')"
  # shellcheck disable=SC2086
  set -- $DID_SERVICES
  [[ $# -eq 1 ]] || die "Expected exactly one DID Service, found $#."
  DID_SERVICE_NAME="$1"
  CHECK_POD="did-check-$(date -u +%s)"
  kubectl -n "$NAMESPACE" run "$CHECK_POD" --rm --attach=true --restart=Never \
    --image=curlimages/curl -- \
    curl -fsS -i -H "Host: $TENANT_HOST" \
    "http://$DID_SERVICE_NAME:8080/.well-known/did.json"
fi

kubectl -n "$NAMESPACE" get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{end}' \
  >"$BACKUP_DIR/image-digests-after.txt"

printf 'Helm upgrade completed successfully. Backup and candidate manifests: %s\n' "$BACKUP_DIR"
