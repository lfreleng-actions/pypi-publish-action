#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Copy the distributions to publish from a download directory into an
# empty selection directory.
#
# Usage: select-distributions.sh <download_dir> <selection_dir>
#
# Only top-level regular files named '*.whl' or '*.tar.gz' are
# selected. An entry with one of those names that is a symlink, a
# directory or any other non-regular file fails the selection; other
# entries are excluded and reported. Fails when nothing is selected.
# Never deletes or modifies anything in either directory beyond
# adding the selected copies to <selection_dir>.

set -euo pipefail

fail() {
  echo "Error: $* ❌" >&2
  exit 1
}

if [ "$#" -ne 2 ]; then
  fail "usage: select-distributions.sh <download_dir> <selection_dir>"
fi
download_dir="$1"
selection_dir="$2"

for dir in "$download_dir" "$selection_dir"; do
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    fail "not a directory: $dir"
  fi
done
if [ -n "$(ls -A -- "$selection_dir")" ]; then
  fail "selection directory is not empty: $selection_dir"
fi

shopt -s nullglob dotglob
count=0
for entry in "$download_dir"/*; do
  name="$(basename -- "$entry")"
  case "$name" in
    *.whl | *.tar.gz)
      if [ -L "$entry" ] || [ ! -f "$entry" ]; then
        fail "distribution is not a regular file: $name"
      fi
      cp -p -- "$entry" "$selection_dir/$name"
      echo "Selected for upload: $name"
      count=$((count + 1))
      ;;
    *)
      echo "Excluded (not a wheel or sdist): $name"
      ;;
  esac
done

if [ "$count" -eq 0 ]; then
  fail "no wheel (*.whl) or sdist (*.tar.gz) distributions to publish"
fi
