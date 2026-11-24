#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for the per-file release comparison that lets a
# rerun complete a partially published release. Runs against a mock
# package index on a loopback port; needs no credentials and no
# access to PyPI or TestPyPI. Each case lists what the uploader would
# be given, the content of the upload directory, without uploading.
#
# Usage: bash tests/test-compare-release.sh

set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
compare_script="$repo_root/scripts/compare-release.py"
make_script="$repo_root/tests/make-distribution.py"
mock_script="$repo_root/tests/mock-index.py"

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

scratch="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2> /dev/null || true
    wait "$server_pid" 2> /dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

root="$scratch/index"
mkdir -p "$root"
python3 -I "$mock_script" "$root" "$scratch/port" 2> /dev/null &
server_pid=$!
for _ in $(seq 1 100); do
  [ -s "$scratch/port" ] && break
  sleep 0.1
done
[ -s "$scratch/port" ] || {
  echo "mock index did not start ❌"
  exit 1
}
base="http://127.0.0.1:$(cat "$scratch/port")"

make() { python3 -I "$make_script" "$@" > /dev/null; }
digest() { sha256sum -- "$1" | cut -d' ' -f1; }

# Build a selection for a project; prints the selection directory
new_selection() {
  local dir
  dir="$(mktemp -d "$scratch/sel.XXXXXX")"
  make wheel "$dir" "$1" 2.0.0
  make sdist "$dir" "$1" 2.0.0
  echo "$dir"
}

# Write the JSON API answer for a release: <index> <name> <version>
# <info_version> [<filename>=<sha256> ...]
publish_json() {
  local index="$1" name="$2" version="$3" info_version="$4"
  shift 4
  mkdir -p "$root/$index/pypi/$name/$version"
  python3 -I -c '
import json, sys
name, version, *files = sys.argv[1:]
urls = [
    {"filename": f, "digests": {"sha256": d, "md5": "0" * 32}}
    for f, d in (item.split("=", 1) for item in files)
]
print(json.dumps({"info": {"name": name, "version": version}, "urls": urls}))
' "$name" "$info_version" "$@" > "$root/$index/pypi/$name/$version/json"
}

# Run a comparison: <index> <selection> <name>; sets $out, $status,
# $upload (what the uploader would be given) and $state
run_compare() {
  local index="$1" selection="$2" name="$3" upload_dir output
  upload_dir="$(mktemp -d "$scratch/upload.XXXXXX")"
  output="$(mktemp "$scratch/output.XXXXXX")"
  status=0
  out="$(GITHUB_OUTPUT="$output" python3 -I "$compare_script" \
    "$selection" "$upload_dir" "$base/$index" "$name" 2.0.0 2>&1)" ||
    status=$?
  upload="$(find "$upload_dir" -mindepth 1 -printf '%f\n' | sort |
    tr '\n' ' ')"
  state="$(sed -n 's/^state=//p' "$output")"
  echo "  uploader would be given: [ ${upload}]"
}

expect_state() {
  local desc="$1" want_state="$2" want_upload="$3"
  if [ "$status" -ne 0 ]; then
    fail "$desc (exit $status): $out"
  elif [ "$state" != "$want_state" ]; then
    fail "$desc (state '$state', not '$want_state'): $out"
  elif [ "$upload" != "$want_upload" ]; then
    fail "$desc (upload '$upload', not '$want_upload')"
  else
    pass "$desc"
  fi
}

expect_refused() {
  local desc="$1" pattern="$2"
  if [ "$status" -eq 0 ]; then
    fail "$desc (unexpected success): $out"
  elif [ -n "$upload" ]; then
    fail "$desc (files staged for upload: $upload)"
  elif [[ "$out" != *"$pattern"* ]]; then
    fail "$desc (wrong error): $out"
  else
    pass "$desc"
  fi
}

# Production and test index settings differ only in the index URL;
# run every case against both and expect the same result
for index in pypi.org test.pypi.org; do
  echo "--- $index"

  sel="$(new_selection demo-absent)"
  wheel="demo_absent-2.0.0-py3-none-any.whl"
  sdist="demo_absent-2.0.0.tar.gz"
  run_compare "$index" "$sel" demo-absent
  expect_state "[$index] absent release uploads every file" absent \
    "$wheel $sdist "

  sel="$(new_selection demo-complete)"
  wheel="demo_complete-2.0.0-py3-none-any.whl"
  sdist="demo_complete-2.0.0.tar.gz"
  publish_json "$index" demo-complete 2.0.0 2.0.0 \
    "$wheel=$(digest "$sel/$wheel")" "$sdist=$(digest "$sel/$sdist")"
  run_compare "$index" "$sel" demo-complete
  expect_state "[$index] complete identical release uploads nothing" \
    complete ""

  sel="$(new_selection demo-partial)"
  wheel="demo_partial-2.0.0-py3-none-any.whl"
  sdist="demo_partial-2.0.0.tar.gz"
  publish_json "$index" demo-partial 2.0.0 2.0.0 \
    "$wheel=$(digest "$sel/$wheel")" \
    "demo_partial-2.0.0-cp312-cp312-manylinux_2_28_x86_64.whl=$(printf '%064d' 1)"
  run_compare "$index" "$sel" demo-partial
  expect_state "[$index] partial release uploads only the missing file" \
    partial "$sdist "
  if [[ "$out" == *"not in the selection; left as is"* ]]; then
    pass "[$index] remote file outside the selection is reported"
  else
    fail "[$index] remote file outside the selection not reported: $out"
  fi

  sel="$(new_selection demo-conflict)"
  wheel="demo_conflict-2.0.0-py3-none-any.whl"
  publish_json "$index" demo-conflict 2.0.0 2.0.0 \
    "$wheel=$(printf '%064d' 0)"
  run_compare "$index" "$sel" demo-conflict
  expect_refused "[$index] filename with another digest fails before upload" \
    "different files of the same name"
  if [[ "$out" == *"Re-run failed jobs"* ]]; then
    pass "[$index] conflict error names the 'Re-run failed jobs' route"
  else
    fail "[$index] conflict error lacks the 'Re-run failed jobs' route: $out"
  fi

  sel="$(new_selection demo-malformed)"
  mkdir -p "$root/$index/pypi/demo-malformed/2.0.0"
  printf '{"info": ' > "$root/$index/pypi/demo-malformed/2.0.0/json"
  run_compare "$index" "$sel" demo-malformed
  expect_refused "[$index] malformed JSON fails closed" "is not JSON"

  sel="$(new_selection demo-shape)"
  mkdir -p "$root/$index/pypi/demo-shape/2.0.0"
  printf '[]\n' > "$root/$index/pypi/demo-shape/2.0.0/json"
  run_compare "$index" "$sel" demo-shape
  expect_refused "[$index] JSON of the wrong shape fails closed" \
    "not a JSON object"

  sel="$(new_selection demo-null)"
  mkdir -p "$root/$index/pypi/demo-null/2.0.0"
  printf 'null\n' > "$root/$index/pypi/demo-null/2.0.0/json"
  run_compare "$index" "$sel" demo-null
  expect_refused "[$index] JSON null fails closed, not as absent" \
    "is JSON null"

  sel="$(new_selection demo-nodigest)"
  publish_json "$index" demo-nodigest 2.0.0 2.0.0 \
    "demo_nodigest-2.0.0.tar.gz=not-a-digest"
  run_compare "$index" "$sel" demo-nodigest
  expect_refused "[$index] file without a SHA-256 digest fails closed" \
    "without a SHA-256 digest"

  sel="$(new_selection demo-twice)"
  sdist="demo_twice-2.0.0.tar.gz"
  publish_json "$index" demo-twice 2.0.0 2.0.0 \
    "$sdist=$(digest "$sel/$sdist")" "$sdist=$(printf '%064d' 0)"
  run_compare "$index" "$sel" demo-twice
  expect_refused "[$index] filename listed with two digests fails closed" \
    "with several digests"

  sel="$(new_selection demo-other)"
  publish_json "$index" demo-other 2.0.0 2.0
  run_compare "$index" "$sel" demo-other
  expect_refused "[$index] answer for another version fails closed" \
    "index answered for demo-other 2.0, not demo-other 2.0.0"

  sel="$(new_selection demo-error)"
  mkdir -p "$root/$index/pypi/demo-error/2.0.0"
  echo 503 > "$root/$index/pypi/demo-error/2.0.0/json.status"
  run_compare "$index" "$sel" demo-error
  expect_refused "[$index] index server error fails closed" "HTTP 503"

  sel="$(new_selection demo-moved)"
  wheel="demo_moved-2.0.0-py3-none-any.whl"
  sdist="demo_moved-2.0.0.tar.gz"
  mkdir -p "$root/$index/pypi/demo-moved/2.0.0"
  echo "/$index/pypi/Demo_Moved/2.0.0/json" \
    > "$root/$index/pypi/demo-moved/2.0.0/json.redirect"
  publish_json "$index" Demo_Moved 2.0.0 2.0.0 \
    "$wheel=$(digest "$sel/$wheel")"
  run_compare "$index" "$sel" demo-moved
  expect_state "[$index] same-origin redirect is followed" partial "$sdist "

  sel="$(new_selection demo-away)"
  mkdir -p "$root/$index/pypi/demo-away/2.0.0"
  echo "http://localhost:1/pypi/demo-away/2.0.0/json" \
    > "$root/$index/pypi/demo-away/2.0.0/json.redirect"
  run_compare "$index" "$sel" demo-away
  expect_refused "[$index] redirect to another origin fails closed" \
    "redirected to another origin"

  sel="$(new_selection demo-loop)"
  mkdir -p "$root/$index/pypi/demo-loop/2.0.0"
  echo "/$index/pypi/demo-loop/2.0.0/json" \
    > "$root/$index/pypi/demo-loop/2.0.0/json.redirect"
  run_compare "$index" "$sel" demo-loop
  expect_refused "[$index] redirect loop fails closed" \
    "redirected more than"
done

echo "--- unreadable index and arguments"
sel="$(new_selection demo-absent)"
upload="$(mktemp -d "$scratch/upload.XXXXXX")"
check_refused() {
  local desc="$1" pattern="$2"
  shift 2
  if out="$(python3 -I "$compare_script" "$@" 2>&1)"; then
    fail "$desc (unexpected success): $out"
  elif [[ "$out" != *"$pattern"* ]]; then
    fail "$desc (wrong error): $out"
  elif [ -n "$(ls -A -- "$upload")" ]; then
    fail "$desc (files staged for upload)"
  else
    pass "$desc"
  fi
}
check_refused "unreachable index fails closed" "cannot read" \
  "$sel" "$upload" "http://127.0.0.1:1" demo-absent 2.0.0
check_refused "plain HTTP to a remote host is refused" "must use https" \
  "$sel" "$upload" "http://pypi.invalid" demo-absent 2.0.0
check_refused "unnormalised project name is refused" "not normalised" \
  "$sel" "$upload" "$base/pypi.org" Demo_Absent 2.0.0
check_refused "unnormalised version is refused" "not normalised" \
  "$sel" "$upload" "$base/pypi.org" demo-absent v2.0.0
touch "$upload/stray"
if out="$(python3 -I "$compare_script" "$sel" "$upload" \
  "$base/pypi.org" demo-absent 2.0.0 2>&1)"; then
  fail "non-empty upload directory accepted: $out"
elif [[ "$out" == *"is not empty"* ]] &&
  [ "$(ls -A -- "$upload")" = "stray" ]; then
  pass "non-empty upload directory is refused"
else
  fail "non-empty upload directory (wrong error or files staged): $out"
fi

echo "--- action.yaml wiring"
action="$repo_root/action.yaml"
line_of() {
  grep -n -F -- "- name: '$1" "$action" | head -n1 | cut -d: -f1 || true
}
compare_line="$(line_of 'Compare selection with the release')"
if [ -z "$compare_line" ]; then
  fail "comparison step not found in action.yaml"
else
  for step in 'Determine publishing method' 'Retrieve Credential' \
    'Publish PyPI'; do
    later="$(line_of "$step")"
    if [ -n "$later" ] && [ "$later" -gt "$compare_line" ]; then
      pass "comparison runs before '$step'"
    else
      fail "comparison does not run before '$step'"
    fi
  done
fi
uploads="$(grep -c 'packages-dir:' "$action" || true)"
# shellcheck disable=SC2016 # matches the literal expression
staged="$(grep -c -F \
  'packages-dir: "${{ steps.staging.outputs.upload_packages_dir }}"' \
  "$action" || true)"
if [ "$uploads" -gt 0 ] && [ "$uploads" = "$staged" ]; then
  pass "every upload step publishes only the staged missing files"
else
  fail "$((uploads - staged)) upload step(s) bypass the upload directory"
fi
if grep -q 'version_match' "$action"; then
  fail "action.yaml still decides on the version-level match"
else
  pass "action.yaml no longer decides on the version-level match"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed ❌"
  exit 1
fi
echo "All tests passed ✅"
