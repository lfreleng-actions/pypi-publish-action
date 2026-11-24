#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for the retry of the artefact download by name.
# A stand-in replaces the download step, so a miss needs neither
# credentials nor GitHub's timing; a stand-in 'sleep' records waits.
#
# Usage: bash tests/test-retry-download.sh

set -euo pipefail
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
retry_script="$repo_root/scripts/retry-download.sh"
action_file="$repo_root/action.yaml"

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

sleep_log="$scratch/sleep.log"
export SLEEP_LOG="$sleep_log"
sleep() { echo "$1" >> "$SLEEP_LOG"; }
export -f sleep

# Stand-in for one download attempt: 'ok' downloads and succeeds,
# 'miss' fails without writing, 'error' fails after writing a file
fake_download() {
  local result="$1" dir="$2"
  case "$result" in
    ok)
      echo 'wheel' > "$dir/demo-1.0.0-py3-none-any.whl"
      ;;
    miss)
      return 1
      ;;
    error)
      echo 'wheel' > "$dir/demo-1.0.0-py3-none-any.whl"
      return 1
      ;;
  esac
}

# Mirror the steps in action.yaml: each attempt runs only when the
# check after the previous failed attempt asked for a retry
run_downloads() {
  local dir attempt=1 result output
  dir="$(mktemp -d "$scratch/download.XXXXXX")"
  : > "$sleep_log"
  for result in "$@"; do
    if fake_download "$result" "$dir"; then
      echo "downloaded on attempt $attempt"
      return 0
    fi
    output="$(mktemp "$scratch/output.XXXXXX")"
    GITHUB_OUTPUT="$output" bash "$retry_script" \
      "$attempt" "$dir" demo-project || return 1
    if ! grep -qx 'retry=true' "$output"; then
      echo "attempt $attempt failed without asking for a retry"
      return 1
    fi
    attempt=$((attempt + 1))
  done
  echo "attempts ran out without a result"
  return 1
}

expect_ok() {
  local desc="$1" pattern="$2" waits="$3"
  shift 3
  if out="$("$@" 2>&1)" && [[ "$out" == *"$pattern"* ]] \
    && [ "$(paste -sd' ' "$sleep_log")" = "$waits" ]; then
    pass "$desc"
  else
    fail "$desc: $out; waits: $(paste -sd' ' "$sleep_log")"
  fi
}

expect_error() {
  local desc="$1" pattern="$2" waits="$3"
  shift 3
  if out="$("$@" 2>&1)"; then
    fail "$desc (unexpected success): $out"
  elif [[ "$out" == *"$pattern"* ]] \
    && [ "$(paste -sd' ' "$sleep_log")" = "$waits" ]; then
    pass "$desc"
  else
    fail "$desc (wrong error): $out; waits: $(paste -sd' ' "$sleep_log")"
  fi
}

expect_ok "first attempt downloads without waiting" \
  "downloaded on attempt 1" "" run_downloads ok
expect_ok "retry after misses, then download" \
  "downloaded on attempt 3" "2 4" run_downloads miss miss ok
expect_ok "download on the last attempt" \
  "downloaded on attempt 5" "2 4 8 16" \
  run_downloads miss miss miss miss ok
expect_error "fail after the last attempt" \
  "::error::Artefact 'demo-project' not found after 5 attempts" \
  "2 4 8 16" run_downloads miss miss miss miss miss
expect_error "no retry when the failure left files" \
  "failed after writing files; not retrying" "" run_downloads error ok
expect_error "no retry for a later failure that left files" \
  "failed after writing files; not retrying" "2" \
  run_downloads miss error ok

: > "$sleep_log"
empty="$(mktemp -d "$scratch/empty.XXXXXX")"
check() { GITHUB_OUTPUT="$scratch/unused" bash "$retry_script" "$@"; }
expect_error "reject attempt zero" "outside 1 to 5" "" check 0 "$empty" x
expect_error "reject attempt past the last" "outside 1 to 5" "" \
  check 6 "$empty" x
expect_error "reject a non-numeric attempt" "not a number" "" \
  check one "$empty" x
expect_error "reject a missing directory" "not a directory" "" \
  check 1 "$scratch/missing" x
ln -s "$empty" "$scratch/link"
expect_error "reject a symlinked directory" "not a directory" "" \
  check 1 "$scratch/link" x

# action.yaml must repeat the download as often as the script allows
max_attempts="$(sed -n 's/^max_attempts=\([0-9]*\)$/\1/p' "$retry_script")"
downloads="$(grep -c "^      id: download-[0-9]*$" "$action_file" || true)"
checks="$(grep -c "^      id: retry-[0-9]*$" "$action_file" || true)"
if [ -n "$max_attempts" ] && [ "$downloads" = "$max_attempts" ] \
  && [ "$checks" = "$max_attempts" ]; then
  pass "action.yaml holds $max_attempts download attempts"
else
  fail "action.yaml holds $downloads downloads and $checks checks;" \
    "the script allows ${max_attempts:-?} attempts"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed ❌"
  exit 1
fi
echo "All retry tests passed ✅"
