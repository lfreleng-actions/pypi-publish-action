#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Validate the caller's distribution location, PATH_PREFIX/ARTEFACT_PATH.
#
# Rejects an empty, absolute or '..' value, and any destination that
# resolves (following symlinks) to the workspace, the project root, a
# parent of the project root, or a location outside the workspace.
# The destination need not exist yet. On success, prints the resolved
# absolute destination path.
#
# Environment: PATH_PREFIX (default '.'), ARTEFACT_PATH,
# GITHUB_WORKSPACE (default: current directory).

set -euo pipefail

fail() {
  echo "Error: $* ❌" >&2
  exit 1
}

path_prefix="${PATH_PREFIX:-.}"
artefact_path="${ARTEFACT_PATH:-}"

if [ -z "$artefact_path" ]; then
  fail "artefact_path must not be empty"
fi
case "$artefact_path" in
  /*) fail "artefact_path must be a relative path" ;;
  *..*) fail "artefact_path must not contain '..'" ;;
esac
if [ ! -d "$path_prefix" ]; then
  fail "invalid path/prefix to project directory"
fi

# 'cd --' stops a leading '-' in a path being read as an option
workspace="$(cd -- "${GITHUB_WORKSPACE:-$PWD}" && pwd -P)"
project="$(cd -- "$path_prefix" && pwd -P)"

# Walk up to the deepest existing directory, remembering the
# components below it that do not exist yet. Any existing entry on the
# way that is not a directory (a file, or a dangling symlink) is
# rejected, so a later 'mkdir -p' cannot follow it.
probe="$path_prefix/$artefact_path"
missing=""
while [ ! -d "$probe" ]; do
  if [ -e "$probe" ] || [ -L "$probe" ]; then
    fail "artefact destination is not a directory: $probe"
  fi
  name="$(basename -- "$probe")"
  if [ "$name" != "." ]; then
    missing="$name${missing:+/$missing}"
  fi
  probe="$(dirname -- "$probe")"
done
resolved="$(cd -- "$probe" && pwd -P)${missing:+/$missing}"

case "$resolved/" in
  "$workspace"/*) ;;
  *) fail "artefact destination escapes the workspace: $resolved" ;;
esac
if [ "$resolved" = "$workspace" ]; then
  fail "artefact_path must not resolve to the workspace root"
fi
case "$project/" in
  "$resolved"/*)
    fail "artefact_path must not resolve to the project root" \
      "or one of its parent directories: $resolved"
    ;;
esac

echo "$resolved"
