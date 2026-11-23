#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Copy the selected distributions to the caller's distribution
# location, PATH_PREFIX/ARTEFACT_PATH, as earlier releases left them
# there.
#
# Usage: copy-distributions.sh <selection_dir>
#
# Validates the destination first (validate-artefact-path.sh). Only
# adds or replaces regular files with the selected names; refuses
# to write through a symlink or over a non-regular file, and never
# deletes anything. Each file is written to a new temporary file in
# the destination and renamed over its target, so the rename
# replaces the directory entry instead of writing into an existing
# inode that another path, such as a hard link, may share. The
# temporary name has a short fixed prefix, not the distribution's
# name, so a name near the filesystem's length limit still fits.

set -euo pipefail

fail() {
  echo "Error: $* ❌" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  fail "usage: copy-distributions.sh <selection_dir>"
fi
selection_dir="$1"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
destination="$(bash "$script_dir/validate-artefact-path.sh")"
mkdir -p -- "$destination"

shopt -s nullglob dotglob
entries=("$selection_dir"/*)

# Check every target before copying, so a refusal leaves no partial copy
for entry in "${entries[@]}"; do
  target="$destination/$(basename -- "$entry")"
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    fail "refusing to overwrite non-regular file: $target"
  fi
done
tmp=""
trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
for entry in "${entries[@]}"; do
  name="$(basename -- "$entry")"
  tmp="$(mktemp -- "$destination/.dist.XXXXXX")"
  cp -p -- "$entry" "$tmp"
  mv -f -T -- "$tmp" "$destination/$name"
  tmp=""
done
