#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=upgrade-path.sh
source "$SCRIPT_DIR/upgrade-path.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_plan() {
  local installed="$1"
  local target="$2"
  local expected_intermediate="$3"
  local expected_auto="$4"
  local expected_intermediate_files="$5"

  edk_plan_known_upgrade_path "$installed" "$target" "rc1-to-rc2.yaml" "rc2-to-rc3.yaml"

  [[ "$EDK_INTERMEDIATE_IMAGE_TAG" == "$expected_intermediate" ]] ||
    fail "$installed -> $target intermediate: expected '$expected_intermediate', got '$EDK_INTERMEDIATE_IMAGE_TAG'"
  [[ "${EDK_AUTO_MIGRATION_VALUE_FILES[*]}" == "$expected_auto" ]] ||
    fail "$installed -> $target overlays: expected '$expected_auto', got '${EDK_AUTO_MIGRATION_VALUE_FILES[*]}'"
  [[ "${EDK_INTERMEDIATE_MIGRATION_VALUE_FILES[*]}" == "$expected_intermediate_files" ]] ||
    fail "$installed -> $target intermediate overlays: expected '$expected_intermediate_files', got '${EDK_INTERMEDIATE_MIGRATION_VALUE_FILES[*]}'"
}

assert_plan "0.25.0-RC1" "0.25.0-RC2" "" "rc1-to-rc2.yaml" ""
assert_plan "0.25.0-RC2" "0.25.0-RC2" "" "rc1-to-rc2.yaml" ""
assert_plan "0.25.0-rc2" "0.25.0-rc3" "" \
  "rc1-to-rc2.yaml rc2-to-rc3.yaml" ""
assert_plan "0.25.0-RC1" "0.25.0-RC3" "0.25.0-RC2" \
  "rc1-to-rc2.yaml rc2-to-rc3.yaml" "rc1-to-rc2.yaml"
assert_plan "custom-build" "0.25.0-RC3" "" "" ""
assert_plan "0.25.0-RC3" "0.25.0-RC3" "" \
  "rc1-to-rc2.yaml rc2-to-rc3.yaml" ""
assert_plan "0.25.0-RC2" "0.25.0-RC3-20260730T120000Z-a1b2c3d4" "" \
  "rc1-to-rc2.yaml rc2-to-rc3.yaml" ""
assert_plan "0.25.0-RC1" "0.25.0-rc3.preview-2" "0.25.0-RC2" \
  "rc1-to-rc2.yaml rc2-to-rc3.yaml" "rc1-to-rc2.yaml"
assert_plan "0.25.0-RC3_build-42" "0.25.0-RC3_build-42" "" \
  "rc1-to-rc2.yaml rc2-to-rc3.yaml" ""
assert_plan "0.25.0-RC2" "0.25.0-RC30" "" "" ""
assert_plan "0.25.0-RC2" "0.25.0-RC3suffix" "" "" ""

if edk_plan_known_upgrade_path "0.25.0-RC3" "0.25.0-RC2" "one" "two"; then
  fail "known release downgrade must be rejected"
fi
if edk_plan_known_upgrade_path "0.25.0-RC3-build-7" "0.25.0-RC2" "one" "two"; then
  fail "RC3 suffix release downgrade must be rejected"
fi

extracted="$(printf '%s\n' '{"global": {"imageTag": "0.25.0-RC1"}, "services": {"platform": {"imageTag": "wrong"}}}' | edk_extract_global_image_tag)"
[[ "$extracted" == "0.25.0-RC1" ]] || fail "expected global image tag, got '$extracted'"

printf 'Upgrade path tests passed.\n'
