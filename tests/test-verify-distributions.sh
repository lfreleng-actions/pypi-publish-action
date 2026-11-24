#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for the distribution identity and metadata check.
# Needs no credentials or network access.
#
# Usage: bash tests/test-verify-distributions.sh

set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
verify_script="$repo_root/scripts/verify-distributions.py"
make_script="$repo_root/tests/make-distribution.py"

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

expect_ok() {
  local desc="$1"
  shift
  if out="$("$@" 2>&1)"; then
    pass "$desc"
  else
    fail "$desc (exit $?): $out"
  fi
}

expect_error() {
  local desc="$1" pattern="$2"
  shift 2
  if out="$("$@" 2>&1)"; then
    fail "$desc (unexpected success): $out"
  elif [[ "$out" == *"$pattern"* ]]; then
    pass "$desc"
  else
    fail "$desc (wrong error): $out"
  fi
}

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

# New empty selection directory; prints its path
new_dir() { mktemp -d "$scratch/sel.XXXXXX"; }
make() { python3 -I "$make_script" "$@" > /dev/null; }
verify() { python3 -I "$verify_script" "$@"; }

echo "--- matching release"
good="$(new_dir)"
make wheel "$good" demo-project 2.0.0
make sdist "$good" demo-project 2.0.0
output="$scratch/github-output"
: > "$output"
expect_ok "accept wheel and sdist for the release" \
  env GITHUB_OUTPUT="$output" python3 -I "$verify_script" \
  "$good" demo-project 2.0.0
if [ "$(cat "$output")" = "$(printf 'name=demo-project\nversion=2.0.0')" ]; then
  pass "verified name and version written to GITHUB_OUTPUT"
else
  fail "unexpected GITHUB_OUTPUT: $(cat "$output")"
fi
expect_ok "accept 'v' prefix on tag" verify "$good" demo-project v2.0.0
expect_ok "accept 'V' prefix on tag" verify "$good" demo-project V2.0.0
expect_error "reject tag with trailing zero dropped" \
  "expected demo-project 2.0, found demo-project 2.0.0" \
  verify "$good" demo-project 2.0
expect_error "reject tag that is not a version" "not a valid PEP 440" \
  verify "$good" demo-project release-2
expect_error "reject empty expected name" "no expected project name" \
  verify "$good" "" 2.0.0

echo "--- normalisation"
norm="$(new_dir)"
make wheel "$norm" Demo.Project 2.0.0-RC1
expect_ok "match names across '-', '_', '.' and case" \
  verify "$norm" demo_project 2.0.0rc1
expect_ok "match equivalent PEP 440 spellings" \
  verify "$norm" demo-project v2.0.0.rc.1

echo "--- mismatched selections"
old="$(new_dir)"
make wheel "$old" demo-project 1.9.0
expect_error "reject wheel for another version" \
  "expected demo-project 2.0.0, found demo-project 1.9.0" \
  verify "$old" demo-project 2.0.0
other="$(new_dir)"
make sdist "$other" other-project 2.0.0
expect_error "reject distribution of another project" \
  "expected demo-project 2.0.0, found other-project 2.0.0" \
  verify "$other" demo-project 2.0.0
mixed="$(new_dir)"
make wheel "$mixed" demo-project 2.0.0
make wheel "$mixed" demo-project 2.0.1
expect_error "reject selection mixing versions" "found demo-project 2.0.1" \
  verify "$mixed" demo-project 2.0.0
expect_error "reject empty selection" "no wheel" \
  verify "$(new_dir)" demo-project 2.0.0
extra="$(cp -r "$good" "$scratch/extra" && echo "$scratch/extra")"
printf 'notes\n' > "$extra/README.txt"
expect_error "reject file that is not a distribution" \
  "README.txt: not a wheel or sdist" verify "$extra" demo-project 2.0.0
linked="$(new_dir)"
ln -s "$good/demo_project-2.0.0.tar.gz" "$linked/demo_project-2.0.0.tar.gz"
expect_error "reject symlinked distribution" "not a regular file" \
  verify "$linked" demo-project 2.0.0
expect_error "reject missing selection directory" "not a directory" \
  verify "$scratch/missing" demo-project 2.0.0

echo "--- invalid metadata"
for kind in wheel sdist; do
  for field in Name Version Metadata-Version; do
    dir="$(new_dir)"
    make "$kind" "$dir" demo-project 2.0.0 --omit="$field"
    expect_error "reject $kind without $field" "exactly one $field" \
      verify "$dir" demo-project 2.0.0
  done
  dir="$(new_dir)"
  make "$kind" "$dir" demo-project 2.0.0 --no-metadata
  expect_error "reject $kind without metadata file" "found none" \
    verify "$dir" demo-project 2.0.0
  dir="$(new_dir)"
  make "$kind" "$dir" demo-project not-a-version
  expect_error "reject $kind with invalid Version" "invalid Version" \
    verify "$dir" demo-project 2.0.0
done

echo "--- metadata the uploader would read"
dir="$(new_dir)"
make wheel "$dir" demo-project 2.0.0 --extra=METADATA,other-project,1.0.0
expect_error "reject wheel whose root METADATA twine would upload" \
  "uploader would read METADATA" verify "$dir" demo-project 2.0.0
dir="$(new_dir)"
make wheel "$dir" demo-project 2.0.0 --extra=aaa/METADATA,other-project,1.0.0
expect_error "reject wheel with a shallower METADATA twine sorts first" \
  "uploader would read aaa/METADATA" verify "$dir" demo-project 2.0.0
dir="$(new_dir)"
make wheel "$dir" demo-project 2.0.0 \
  --extra=fixture/_vendor/dep-1.0.dist-info/METADATA,dep,1.0
expect_ok "accept wheel vendoring a nested dist-info" \
  verify "$dir" demo-project 2.0.0
dir="$(new_dir)"
make sdist "$dir" demo-project 2.0.0 \
  --extra=demo_project-2.0.0/PKG-INFO,demo-project,1.9.0
expect_error "reject sdist with a repeated PKG-INFO" \
  "found demo_project-2.0.0/PKG-INFO, demo_project-2.0.0/PKG-INFO" \
  verify "$dir" demo-project 2.0.0
dir="$(new_dir)"
make sdist "$dir" demo-project 2.0.0 --extra=other/setup.cfg,x,1.0
expect_error "reject sdist with several top-level directories" \
  "not under a single top-level directory" verify "$dir" demo-project 2.0.0

corrupt="$(new_dir)"
printf 'wheel\n' > "$corrupt/demo_project-2.0.0-py3-none-any.whl"
printf 'sdist\n' > "$corrupt/demo_project-2.0.0.tar.gz"
expect_error "reject corrupt wheel" "not a valid wheel" \
  verify "$corrupt" demo-project 2.0.0
expect_error "reject corrupt sdist" "not a valid sdist" \
  verify "$corrupt" demo-project 2.0.0

echo "--- action.yaml ordering"
# The checks must run before anything copies, queries the index, picks
# or retrieves a credential, or uploads
action="$repo_root/action.yaml"
line_of() {
  grep -n -F -- "- name: '$1" "$action" | head -n1 | cut -d: -f1 || true
}
for check in 'Verify distributions match the release' \
  'Check distribution metadata'; do
  check_line="$(line_of "$check")"
  if [ -z "$check_line" ]; then
    fail "step '$check' not found in action.yaml"
    continue
  fi
  for step in 'Copy distributions' 'Checking package index' \
    'Determine publishing method' 'Retrieve Credential' 'Publish PyPI'; do
    later="$(line_of "$step")"
    if [ -n "$later" ] && [ "$later" -gt "$check_line" ]; then
      pass "'$check' runs before '$step'"
    else
      fail "'$check' does not run before '$step'"
    fi
  done
done
if grep -q 'verify-metadata: false' "$action"; then
  fail "an upload step disables metadata verification"
else
  pass "every upload step verifies metadata"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed ❌"
  exit 1
fi
echo "All tests passed ✅"
