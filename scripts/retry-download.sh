#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Decide what follows a failed download of the build artefact by name.
#
# Usage: retry-download.sh <attempt> <download_dir> <artefact_name>
#
# GitHub's artefact service can briefly fail to list an artefact the
# same job has just uploaded, which the download reports as
# "Artifact not found for name" or "No artifacts found for ID". A
# composite action sees only the download step's outcome, not its
# error, so the download directory stands in for the reason: a miss
# leaves it empty, while an error raised after extraction, such as a
# digest mismatch, leaves files in it.
#
# After a failed attempt that left <download_dir> empty, waits and
# writes 'retry=true' to $GITHUB_OUTPUT, until attempt <max_attempts>.
# Fails at once when the failed attempt left anything in
# <download_dir>, and fails naming the artefact after the last attempt.

set -euo pipefail

# action.yaml repeats the download by name this many times
max_attempts=5
# Seconds to wait after attempts 1 to 4: 30 seconds in all
delays=(2 4 8 16)

fail() {
  echo "::error::$* ❌"
  exit 1
}

if [ "$#" -ne 3 ]; then
  fail "usage: retry-download.sh <attempt> <download_dir> <artefact_name>"
fi
attempt="$1"
download_dir="$2"
name="$3"

case "$attempt" in
  '' | *[!0-9]*) fail "attempt is not a number: $attempt" ;;
esac
if [ "$attempt" -lt 1 ] || [ "$attempt" -gt "$max_attempts" ]; then
  fail "attempt $attempt is outside 1 to $max_attempts"
fi
if [ -L "$download_dir" ] || [ ! -d "$download_dir" ]; then
  fail "not a directory: $download_dir"
fi

if [ -n "$(ls -A -- "$download_dir")" ]; then
  fail "Download of artefact '$name' failed after writing files;" \
    "not retrying"
fi
if [ "$attempt" -eq "$max_attempts" ]; then
  fail "Artefact '$name' not found after $max_attempts attempts"
fi

delay="${delays[$((attempt - 1))]}"
echo "Artefact '$name' not found on attempt $attempt of" \
  "$max_attempts; retrying in ${delay}s"
sleep "$delay"
echo "retry=true" >> "${GITHUB_OUTPUT:?}"
