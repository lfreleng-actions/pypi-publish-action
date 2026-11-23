#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for the artefact path validation and distribution
# selection scripts. Needs no credentials or network access.
#
# Usage: bash tests/test-artefact-safety.sh

set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
scripts="$repo_root/scripts"

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# Run a command expected to succeed; output goes to $out
expect_ok() {
  local desc="$1"
  shift
  if out="$("$@" 2>&1)"; then
    pass "$desc"
  else
    fail "$desc (exit $?): $out"
  fi
}

# Run a command expected to fail with a message matching a pattern
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

validate() {
  PATH_PREFIX="$1" ARTEFACT_PATH="$2" \
    bash "$scripts/validate-artefact-path.sh"
}

copy_to() {
  PATH_PREFIX="$1" ARTEFACT_PATH="$2" \
    bash "$scripts/copy-distributions.sh" "$3"
}

workspace="$(mktemp -d)"
outside="$(mktemp -d)"
trap 'rm -rf -- "$workspace" "$outside"' EXIT
workspace="$(cd -- "$workspace" && pwd -P)"
export GITHUB_WORKSPACE="$workspace"
cd -- "$workspace"

# Fixture project: metadata, source, an unrelated file and built
# distributions sitting in the project root
mkdir -p proj/src/fixture other
printf '[project]\nname = "fixture"\nversion = "0.0.1"\n' \
  > proj/pyproject.toml
printf '"""Fixture."""\n' > proj/src/fixture/__init__.py
printf 'unrelated\n' > proj/notes.txt
printf 'wheel\n' > proj/fixture-0.0.1-py3-none-any.whl
printf 'sdist\n' > proj/fixture-0.0.1.tar.gz
ln -s . proj/link-self
ln -s .. proj/link-parent
ln -s "$outside" proj/link-outside
ln -s does-not-exist proj/link-dangling
ln -s ../other proj/link-other

snapshot() {
  find proj -type f -print0 | sort -z | xargs -0 sha256sum
}
before="$(snapshot)"

echo "--- validate-artefact-path.sh"
expect_error "reject empty artefact_path" "must not be empty" \
  validate proj ""
expect_error "reject absolute artefact_path" "relative path" \
  validate proj /tmp
expect_error "reject '..' in artefact_path" "must not contain '..'" \
  validate proj src/..
expect_error "reject project root '.'" "project root" validate proj .
expect_error "reject project root './'" "project root" validate proj ./
expect_error "reject project root './.'" "project root" \
  validate proj ./.
expect_error "reject workspace root" "workspace root" validate . .
expect_error "reject symlink to project root" "project root" \
  validate proj link-self
expect_error "reject symlink to parent of project" "workspace root" \
  validate proj link-parent
expect_error "reject symlink outside workspace" "escapes the workspace" \
  validate proj link-outside
expect_error "reject dangling symlink" "not a directory" \
  validate proj link-dangling/dist
expect_error "reject regular file" "not a directory" \
  validate proj notes.txt
expect_ok "accept new subdirectory" validate proj dist
[ "$out" = "$workspace/proj/dist" ] || fail "resolved path: $out"
expect_ok "accept default layout" validate . dist
expect_ok "accept symlink to sibling directory" validate proj link-other
[ "$out" = "$workspace/other" ] || fail "resolved path: $out"

echo "--- select-distributions.sh"
download="$(mktemp -d "$outside/download.XXXXXX")"
selection="$(mktemp -d "$outside/selection.XXXXXX")"
printf 'wheel\n' > "$download/fixture-0.0.1-py3-none-any.whl"
printf 'sdist\n' > "$download/fixture-0.0.1.tar.gz"
printf 'readme\n' > "$download/README.txt"
mkdir "$download/nested"
printf 'nested\n' > "$download/nested/nested-0.0.1.tar.gz"
ln -s README.txt "$download/link.txt"
expect_ok "select regular distributions" \
  bash "$scripts/select-distributions.sh" "$download" "$selection"
selected="$(cd -- "$selection" && ls -A)"
expected="$(printf 'fixture-0.0.1-py3-none-any.whl\nfixture-0.0.1.tar.gz')"
if [ "$selected" = "$expected" ]; then
  pass "only regular wheel and sdist selected"
else
  fail "unexpected selection: $selected"
fi
if [ -f "$download/README.txt" ] && [ -f "$download/nested/nested-0.0.1.tar.gz" ]; then
  pass "download directory left untouched"
else
  fail "download directory changed"
fi
expect_error "reject non-empty selection directory" "not empty" \
  bash "$scripts/select-distributions.sh" "$download" "$selection"

empty="$(mktemp -d "$outside/empty.XXXXXX")"
target="$(mktemp -d "$outside/target.XXXXXX")"
expect_error "reject empty download" "no wheel" \
  bash "$scripts/select-distributions.sh" "$empty" "$target"
printf 'readme\n' > "$empty/README.txt"
expect_error "reject download without distributions" "no wheel" \
  bash "$scripts/select-distributions.sh" "$empty" "$target"

linked="$(mktemp -d "$outside/linked.XXXXXX")"
ln -s "$workspace/proj/fixture-0.0.1-py3-none-any.whl" \
  "$linked/fixture-0.0.1-py3-none-any.whl"
expect_error "reject symlinked wheel" "not a regular file" \
  bash "$scripts/select-distributions.sh" "$linked" "$target"
dirdist="$(mktemp -d "$outside/dirdist.XXXXXX")"
mkdir "$dirdist/fixture-0.0.1.tar.gz"
expect_error "reject directory named as sdist" "not a regular file" \
  bash "$scripts/select-distributions.sh" "$dirdist" "$target"
expect_error "reject symlinked download directory" "not a directory" \
  bash "$scripts/select-distributions.sh" proj/link-outside "$target"

echo "--- copy-distributions.sh"
expect_error "refuse copy into project root" "project root" \
  copy_to proj . "$selection"
expect_error "refuse copy through symlink to project root" "project root" \
  copy_to proj link-self "$selection"
expect_ok "copy into artefact_path" copy_to proj dist "$selection"
copied="$(cd -- proj/dist && ls -A)"
if [ "$copied" = "$expected" ]; then
  pass "artefact_path holds the selected distributions"
else
  fail "unexpected artefact_path content: $copied"
fi
mkdir -p proj/trap
ln -s ../notes.txt proj/trap/fixture-0.0.1.tar.gz
expect_error "refuse to write through symlink" "non-regular file" \
  copy_to proj trap "$selection"
mkdir -p proj/hardlink
ln proj/notes.txt proj/hardlink/fixture-0.0.1.tar.gz
expect_ok "replace hard-linked target" copy_to proj hardlink "$selection"
if cmp -s "$selection/fixture-0.0.1.tar.gz" \
  proj/hardlink/fixture-0.0.1.tar.gz; then
  pass "hard-linked target replaced with the distribution"
else
  fail "hard-linked target not replaced"
fi
leftover="$(find proj/hardlink -name '.*' -print)"
[ -z "$leftover" ] || fail "temporary files left behind: $leftover"

# A distribution name near the 255-byte component limit must still
# fit through the temporary file
long_selection="$(mktemp -d "$outside/long.XXXXXX")"
long_name="fixture-0.0.1-$(printf 'a%.0s' {1..219})-py3-none-any.whl"
[ "${#long_name}" -eq 250 ] || fail "long name is ${#long_name} bytes"
printf 'wheel\n' > "$long_selection/$long_name"
expect_ok "copy 250-byte distribution name" \
  copy_to proj long "$long_selection"
if cmp -s "$long_selection/$long_name" "proj/long/$long_name"; then
  pass "250-byte distribution copied"
else
  fail "250-byte distribution not copied"
fi

# The project must be byte-for-byte unchanged, other than the copies
# added under proj/dist, proj/hardlink and proj/long
after="$(snapshot | grep -v -e ' proj/dist/' -e ' proj/hardlink/' \
  -e ' proj/long/')"
if [ "$before" = "$after" ]; then
  pass "project files unchanged"
else
  fail "project files changed"
  diff <(echo "$before") <(echo "$after") || true
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed ❌"
  exit 1
fi
echo "All tests passed ✅"
