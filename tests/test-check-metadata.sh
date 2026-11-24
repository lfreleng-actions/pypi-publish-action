#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for the Twine metadata check run before credentials.
# Needs no credentials; installs the hash-pinned Twine from the
# package index, so needs network access to it.
#
# Usage: bash tests/test-check-metadata.sh

set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
check_script="$repo_root/scripts/check-metadata.sh"
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

new_dir() { mktemp -d "$scratch/sel.XXXXXX"; }
make() { python3 -I "$make_script" "$@" > /dev/null; }
check() { RUNNER_TEMP="$scratch" bash "$check_script" "$@"; }

good="$(new_dir)"
make wheel "$good" demo-project 2.0.0
make sdist "$good" demo-project 2.0.0
expect_ok "accept valid wheel and sdist" check "$good"
leftover="$(find "$scratch" -maxdepth 1 -name 'twine-check.*')"
if [ -z "$leftover" ]; then
  pass "temporary environment removed"
else
  fail "temporary environment left behind: $leftover"
fi

for kind in wheel sdist; do
  dir="$(new_dir)"
  make "$kind" "$dir" demo-project 2.0.0 --header='Unknown-Field: invalid'
  expect_error "reject $kind with an unknown field" \
    "field 'unknown-field'" check "$dir"
  dir="$(new_dir)"
  make "$kind" "$dir" demo-project 2.0.0 \
    --header='Requires-Python: not a specifier'
  expect_error "reject $kind with an invalid Requires-Python" \
    "'requires-python'" check "$dir"
done

planted="$(new_dir)"
marker="$scratch/planted-venv-ran"
printf 'open(%s, "w").close()\nraise SystemExit(1)\n' "'$marker'" \
  > "$planted/venv.py"
check_from() { (cd -- "$1" && check "$2"); }
expect_ok "ignore a venv.py in the working directory" \
  check_from "$planted" "$good"
if [ -e "$marker" ]; then
  fail "a venv.py in the working directory ran"
else
  pass "a venv.py in the working directory did not run"
fi

mixed="$(cp -r "$good" "$scratch/mixed" && echo "$scratch/mixed")"
make wheel "$mixed" demo-project 2.0.1 --header='Unknown-Field: invalid'
expect_error "reject a selection where one distribution is invalid" \
  "Twine rejected" check "$mixed"
expect_error "reject an empty selection" "no distributions" \
  check "$(new_dir)"
expect_error "reject a missing selection directory" "not a directory" \
  check "$scratch/missing"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed ❌"
  exit 1
fi
echo "All tests passed ✅"
