#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOYMENT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=upgrade-path.sh
source "$SCRIPT_DIR/upgrade-path.sh"

COMPOSE_DIR="$DEPLOYMENT_ROOT/compose"
IMAGE_TAG=""
INSTALLED_IMAGE_TAG=""
BACKUP_ROOT="./edk-compose-upgrade-backup"
SKIP_TARGET_PULL=false
COMPOSE_FILES=()

usage() {
  cat <<'EOF'
Install or safely upgrade EDK Enterprise with Docker Compose.

Usage:
  bash ./scripts/upgrade-compose.sh --image-tag TAG [options]

Options:
  --image-tag TAG             Target immutable image tag (required).
  --compose-dir PATH          Compose directory (default: ../compose).
  --file PATH                 Compose file, repeatable. Defaults to
                              docker-compose.yml in the Compose directory.
  --installed-image-tag TAG   Override detection for a stopped/removed stack.
  --backup-root PATH          Backup parent directory.
  --skip-target-pull          Keep locally built target images. Intermediate
                              release images are still pulled from Nexus.
  -h, --help                  Show this help.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' was not found on PATH."; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    --compose-dir) COMPOSE_DIR="${2:-}"; shift 2 ;;
    --file) COMPOSE_FILES+=("${2:-}"); shift 2 ;;
    --installed-image-tag) INSTALLED_IMAGE_TAG="${2:-}"; shift 2 ;;
    --backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
    --skip-target-pull) SKIP_TARGET_PULL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$IMAGE_TAG" ]] || { usage >&2; die "--image-tag is required."; }
require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
[[ -d "$COMPOSE_DIR" ]] || die "Compose directory does not exist: $COMPOSE_DIR"
COMPOSE_DIR="$(cd -- "$COMPOSE_DIR" && pwd -P)"

if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  COMPOSE_FILES+=("$COMPOSE_DIR/docker-compose.yml")
fi

COMPOSE=(docker compose --project-directory "$COMPOSE_DIR")
for compose_file in "${COMPOSE_FILES[@]}"; do
  [[ -f "$compose_file" ]] || die "Compose file does not exist: $compose_file"
  compose_file="$(cd -- "$(dirname -- "$compose_file")" && pwd -P)/$(basename -- "$compose_file")"
  COMPOSE+=( -f "$compose_file" )
done

STATE_FILE="$COMPOSE_DIR/.edk-installed-image-tag"

detect_installed_tag() {
  local container_id image env_tag
  container_id="$("${COMPOSE[@]}" ps -a -q enterprise-platform 2>/dev/null | head -n 1 || true)"
  if [[ -n "$container_id" ]]; then
    image="$(docker inspect --format '{{.Config.Image}}' "$container_id" 2>/dev/null || true)"
    if [[ "$image" == *:* && "$image" != *@sha256:* ]]; then
      printf '%s\n' "${image##*:}"
      return
    fi
  fi
  if [[ -s "$STATE_FILE" ]]; then
    tr -d '\r\n' <"$STATE_FILE"
    return
  fi
  if [[ -f "$COMPOSE_DIR/.env" ]]; then
    env_tag="$(sed -n 's/^[[:space:]]*EDK_TAG[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$COMPOSE_DIR/.env" | tail -n 1)"
    [[ -z "$env_tag" ]] || printf '%s\n' "$env_tag"
  fi
}

if [[ -z "$INSTALLED_IMAGE_TAG" ]]; then
  INSTALLED_IMAGE_TAG="$(detect_installed_tag)"
fi

INTERMEDIATE_IMAGE_TAG=""
if [[ -n "$INSTALLED_IMAGE_TAG" ]]; then
  if ! edk_plan_known_upgrade_path \
    "$INSTALLED_IMAGE_TAG" \
    "$IMAGE_TAG" \
    "0.25.0-rc1-to-0.25.0-rc2" \
    "0.25.0-rc2-to-0.25.0-rc3" \
    "0.25.0-rc3-to-0.25.0-rc4"; then
    die "Refusing unsupported release downgrade: $INSTALLED_IMAGE_TAG -> $IMAGE_TAG"
  fi
  INTERMEDIATE_IMAGE_TAG="$EDK_INTERMEDIATE_IMAGE_TAG"
fi

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/edk-enterprise-$TIMESTAMP"
mkdir -p -- "$BACKUP_DIR"
"${COMPOSE[@]}" config >"$BACKUP_DIR/compose-before.yaml"
"${COMPOSE[@]}" ps -a >"$BACKUP_DIR/containers-before.txt" || true
if [[ -n "$INSTALLED_IMAGE_TAG" ]]; then
  printf '%s\n' "$INSTALLED_IMAGE_TAG" >"$BACKUP_DIR/installed-image-tag.txt"
fi

run_release_step() {
  local tag="$1"
  local is_target="$2"
  local step_release_number
  step_release_number="$(edk_release_number "$tag")"
  printf 'Validating Docker Compose release %s.\n' "$tag"
  EDK_TAG="$tag" "${COMPOSE[@]}" config --quiet
  if [[ "$is_target" != true || "$SKIP_TARGET_PULL" != true ]]; then
    printf 'Pulling published images for %s.\n' "$tag"
    EDK_TAG="$tag" "${COMPOSE[@]}" pull
  else
    printf 'Using locally built target images for %s; intermediate releases were still pulled.\n' "$tag"
  fi
  if [[ "$(edk_release_number "${INSTALLED_IMAGE_TAG:-}")" -gt 0 &&
        "$(edk_release_number "${INSTALLED_IMAGE_TAG:-}")" -le 2 &&
        "$step_release_number" -ge 3 ]]; then
    # RC3 reconciles durable RC2 tenant signing material during platform startup.
    # Keep the old platform available while the two target dependencies acquire
    # their Compose DNS names, then let the normal full-stack up replace platform.
    printf 'Pre-starting RC3 tenant-AS and tenant-KMS before platform tenant reconciliation.\n'
    EDK_TAG="$tag" "${COMPOSE[@]}" up -d --no-deps --wait --pull never enterprise-tenant-as
    EDK_TAG="$tag" "${COMPOSE[@]}" up -d --no-deps --wait --pull never enterprise-tenant-kms
  fi
  printf 'Starting release %s and waiting for health checks.\n' "$tag"
  EDK_TAG="$tag" "${COMPOSE[@]}" up -d --wait --pull never --remove-orphans
  printf '%s\n' "$tag" >"$STATE_FILE"
  EDK_TAG="$tag" "${COMPOSE[@]}" ps >"$BACKUP_DIR/containers-$tag.txt"
}

printf 'Detected installed image tag: %s\n' "${INSTALLED_IMAGE_TAG:-<fresh-install>}"
if [[ -n "$INTERMEDIATE_IMAGE_TAG" ]]; then
  printf 'Required ordered Compose upgrade: %s -> %s -> %s\n' \
    "$INSTALLED_IMAGE_TAG" "$INTERMEDIATE_IMAGE_TAG" "$IMAGE_TAG"
  run_release_step "$INTERMEDIATE_IMAGE_TAG" false
fi
run_release_step "$IMAGE_TAG" true

printf 'Compose install/upgrade completed successfully. Evidence: %s\n' "$BACKUP_DIR"
printf 'Keep EDK_TAG=%s in .env for subsequent direct docker compose commands.\n' "$IMAGE_TAG"
