#!/usr/bin/env bash
#
# Offline tests for prune.sh's input validation. Everything asserted here is
# checked before the first network call, so these run anywhere with no token
# and no package.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../prune.sh"
pass=0
fail=0

# Run prune.sh with a controlled environment and assert it fails with a
# particular message. Ambient GitHub Actions variables are cleared so a real
# CI run can't accidentally satisfy a check the test wants to see fail.
expect_fail() {
  local desc="$1" expect="$2"
  shift 2

  local out rc
  out="$(env -u GITHUB_REPOSITORY -u GITHUB_REPOSITORY_OWNER -u INPUT_TOKEN \
    -u INPUT_OWNER -u INPUT_PACKAGE -u INPUT_PACKAGE_TYPE \
    -u INPUT_KEEP_LAST -u INPUT_DRY_RUN \
    GITHUB_OUTPUT="$(mktemp)" "$@" bash "$script" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    printf 'FAIL  %s\n      expected a non-zero exit, got 0\n' "$desc"
    fail=$((fail + 1))
    return
  fi

  if ! printf '%s' "$out" | grep -qF -- "$expect"; then
    printf 'FAIL  %s\n      expected to see: %s\n      actual: %s\n' "$desc" "$expect" "$out"
    fail=$((fail + 1))
    return
  fi

  printf 'ok    %s\n' "$desc"
  pass=$((pass + 1))
}

expect_fail 'missing token is rejected' \
  'No token supplied' \
  INPUT_TOKEN=''

expect_fail 'unresolvable owner is rejected' \
  'Could not determine the package owner' \
  INPUT_TOKEN=x

expect_fail 'unresolvable package name is rejected' \
  'Could not determine the package name' \
  INPUT_TOKEN=x INPUT_OWNER=someone

expect_fail 'unknown package-type is rejected' \
  "Unsupported package-type 'gems'" \
  INPUT_TOKEN=x INPUT_OWNER=someone INPUT_PACKAGE=thing INPUT_PACKAGE_TYPE=gems

expect_fail 'non-numeric keep-last is rejected' \
  'keep-last must be a whole number' \
  INPUT_TOKEN=x INPUT_OWNER=someone INPUT_PACKAGE=thing INPUT_KEEP_LAST=lots

expect_fail 'negative keep-last is rejected' \
  'keep-last must be a whole number' \
  INPUT_TOKEN=x INPUT_OWNER=someone INPUT_PACKAGE=thing INPUT_KEEP_LAST=-1

expect_fail 'keep-last of zero is refused' \
  'refusing to delete every version' \
  INPUT_TOKEN=x INPUT_OWNER=someone INPUT_PACKAGE=thing INPUT_KEEP_LAST=0

expect_fail 'non-boolean dry-run is rejected' \
  'dry-run must be true or false' \
  INPUT_TOKEN=x INPUT_OWNER=someone INPUT_PACKAGE=thing INPUT_DRY_RUN=maybe

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
