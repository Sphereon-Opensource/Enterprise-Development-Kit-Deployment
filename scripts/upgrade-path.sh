#!/usr/bin/env bash

# Pure release-path planner shared by upgrade-helm.sh and its shell tests.
# Results are returned in global variables because the deployment supports the
# Bash 3.2 version shipped by macOS.

edk_release_number() {
  local normalized
  normalized="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  case "$normalized" in
    0.25.0-RC1) printf '1\n' ;;
    0.25.0-RC2) printf '2\n' ;;
    # RC3 release candidates are published under fresh immutable suffix tags
    # while the final canonical tag is still reserved. Treat only delimited RC3
    # suffixes as RC3; RC1/RC2 retain their exact-match behavior.
    0.25.0-RC3|0.25.0-RC3[-._]*) printf '3\n' ;;
    *) printf '0\n' ;;
  esac
}

edk_extract_global_image_tag() {
  # Helm emits compact JSON today, but collapse newlines and accept whitespace
  # so this remains stable across Helm 3/4 output formatting. Anchor the match
  # inside `global`; service-level imageTag keys must not affect path detection.
  tr -d '\r\n' |
    sed -n 's/.*"global"[[:space:]]*:[[:space:]]*{[^}]*"imageTag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

edk_plan_known_upgrade_path() {
  local installed_tag="$1"
  local target_tag="$2"
  local rc1_to_rc2_values="$3"
  local v0_25_0_rc2_to_v0_25_0_rc3_values="$4"
  local installed_release_number target_release_number

  EDK_AUTO_MIGRATION_VALUE_FILES=()
  EDK_INTERMEDIATE_MIGRATION_VALUE_FILES=()
  EDK_INTERMEDIATE_IMAGE_TAG=""

  installed_release_number="$(edk_release_number "$installed_tag")"
  target_release_number="$(edk_release_number "$target_tag")"

  if [[ "$installed_release_number" -gt 0 && "$target_release_number" -gt 0 &&
        "$target_release_number" -lt "$installed_release_number" ]]; then
    return 2
  fi

  # Once both endpoints are known releases, select the complete compatibility
  # set for the target release. This deliberately includes earlier overlays on
  # later invocations: customers commonly keep using the values file exported
  # from their original installation. Reapplying the same target must therefore
  # not drop a compatibility value that was required by an earlier step.
  if [[ "$installed_release_number" -gt 0 && "$target_release_number" -ge 2 ]]; then
    EDK_AUTO_MIGRATION_VALUE_FILES+=("$rc1_to_rc2_values")
  fi
  if [[ "$installed_release_number" -gt 0 && "$target_release_number" -ge 3 ]]; then
    EDK_AUTO_MIGRATION_VALUE_FILES+=("$v0_25_0_rc2_to_v0_25_0_rc3_values")
  fi
  if [[ "$installed_release_number" == "1" && "$target_release_number" -ge 3 ]]; then
    EDK_INTERMEDIATE_IMAGE_TAG="0.25.0-RC2"
    EDK_INTERMEDIATE_MIGRATION_VALUE_FILES+=("$rc1_to_rc2_values")
  fi
}
