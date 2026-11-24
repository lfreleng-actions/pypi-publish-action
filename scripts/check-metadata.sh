#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Validate the complete metadata of every selected distribution with
# the same Twine the uploader runs, before any credential is used.
#
# Usage: check-metadata.sh <selection_dir>
#
# Installs the hash-locked Twine in twine-requirements.txt into a
# temporary virtual environment created with 'python3 -I -m venv', runs
# 'twine check' on every entry in <selection_dir>, and removes the
# environment. Fails when the install fails or Twine rejects any
# distribution: an unrecognised or malformed metadata field, an
# invalid field value, or a description that does not render.

set -euo pipefail

fail() {
  echo "Error: $* ❌" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: check-metadata.sh <selection_dir>"
selection_dir="$1"
if [ -L "$selection_dir" ] || [ ! -d "$selection_dir" ]; then
  fail "not a directory: $selection_dir"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
requirements="$script_dir/twine-requirements.txt"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/twine-check.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

if ! python3 -I -m venv "$work/venv" > "$work/venv.log" 2>&1; then
  cat "$work/venv.log" >&2
  fail "cannot create a virtual environment with 'python3 -I -m venv'"
fi
python="$work/venv/bin/python"
if ! "$python" -I -m pip install --quiet --disable-pip-version-check \
  --no-input --require-hashes --only-binary :all: --no-deps \
  -r "$requirements" > "$work/pip.log" 2>&1; then
  cat "$work/pip.log" >&2
  fail "cannot install the pinned Twine from $requirements"
fi

shopt -s nullglob dotglob
entries=("$selection_dir"/*)
[ "${#entries[@]}" -gt 0 ] || fail "no distributions in $selection_dir"

if ! "$python" -I -m twine check "${entries[@]}"; then
  fail "Twine rejected the metadata of a selected distribution"
fi
echo "Metadata of every selected distribution passed 'twine check' ✅"
