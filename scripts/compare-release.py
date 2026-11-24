# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Compare the selected distributions with the files a release holds.

Usage: python3 -I compare-release.py <selection_dir> <upload_dir>
       <index_url> <name> <version>

Asks the package index at <index_url> (for example https://pypi.org)
which files release <version> of project <name> holds, through the
JSON API at ``<index_url>/pypi/<name>/<version>/json``, and compares
each selected distribution's filename and SHA-256 digest with them.
Copies into the empty <upload_dir> only the selected files the release
does not yet hold, so an interrupted, partially published release can
be completed by a rerun. The release is:

- absent: it holds none of the selected files; all are copied;
- complete: it holds every selected file with the same digest; none
  are copied;
- partial: it holds some selected files with the same digest and lacks
  the rest; only the missing files are copied;
- conflicting: it holds a selected filename with another digest; fails
  without copying anything;
- unknown: the index answer is unreadable, malformed or describes
  another release; fails without copying anything.

On success, writes ``state``, ``upload_count`` and ``present_count``
to ``$GITHUB_OUTPUT`` when set. Plain HTTP is accepted only for a
loopback host, which the tests use. Uses only the Python standard
library.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from http.client import HTTPResponse
from pathlib import Path
from typing import cast

MAX_RESPONSE_BYTES = 32 * 1024 * 1024
TIMEOUT_SECONDS = 30
MAX_REDIRECTS = 5
REDIRECT_CODES = {301, 302, 303, 307, 308}
LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ReleaseError(Exception):
    """The release cannot be compared, or conflicts with the selection."""


def _load_canonical_version() -> Callable[[str], str | None]:
    """Reuse the PEP 440 normalisation of verify-distributions.py."""
    path = Path(__file__).resolve().with_name("verify-distributions.py")
    spec = importlib.util.spec_from_file_location("verify_distributions", path)
    if spec is None or spec.loader is None:
        raise ReleaseError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return cast("Callable[[str], str | None]", module.canonical_version)


def canonical_name(name: str) -> str:
    """Return a project name normalised as PEP 503 describes."""
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256_of(path: Path) -> str:
    """Return the hex SHA-256 digest of a file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def check_index_url(index_url: str) -> str:
    """Return index_url without a trailing slash, if its scheme is safe."""
    parts = urllib.parse.urlsplit(index_url)
    secure = parts.scheme == "https"
    loopback = parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS
    if not parts.hostname or not (secure or loopback):
        raise ReleaseError(f"index URL must use https: {index_url}")
    return index_url.rstrip("/")


def _opener() -> urllib.request.OpenerDirector:
    """Return an opener that reports redirects instead of following them."""
    opener = urllib.request.OpenerDirector()
    for handler in (
        urllib.request.ProxyHandler(),
        urllib.request.HTTPHandler(),
        urllib.request.HTTPSHandler(),
        urllib.request.HTTPDefaultErrorHandler(),
        urllib.request.HTTPErrorProcessor(),
    ):
        opener.add_handler(handler)
    return opener


def fetch_release(url: str) -> object | None:
    """Return the parsed JSON for url, or None when the index answers 404.

    Follows a redirect only to the origin of the original request.
    """
    opener = _opener()
    origin = urllib.parse.urlsplit(url)[:2]
    body = b""
    for _ in range(MAX_REDIRECTS + 1):
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            opened = cast("HTTPResponse", opener.open(request, timeout=TIMEOUT_SECONDS))
            with opened as response:
                body = response.read(MAX_RESPONSE_BYTES + 1)
            break
        except urllib.error.HTTPError as exc:
            location = exc.headers.get("Location")
            if exc.code == 404:
                return None
            if exc.code not in REDIRECT_CODES or not location:
                raise ReleaseError(f"index answered HTTP {exc.code} for {url}") from exc
            target = urllib.parse.urljoin(url, location)
            if urllib.parse.urlsplit(target)[:2] != origin:
                raise ReleaseError(
                    f"index redirected to another origin: {target}"
                ) from exc
            url = target
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise ReleaseError(f"cannot read {url}: {exc}") from exc
    else:
        raise ReleaseError(f"index redirected more than {MAX_REDIRECTS} times")
    if len(body) > MAX_RESPONSE_BYTES:
        raise ReleaseError(f"index response for {url} is too large")
    try:
        data = cast("object", json.loads(body.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReleaseError(f"index response for {url} is not JSON: {exc}") from exc
    # None stands for a 404 to the caller; JSON null must not pass as one
    if data is None:
        raise ReleaseError(f"index response for {url} is JSON null")
    return data


def remote_files(
    data: object,
    name: str,
    version: str,
    canonical_version: Callable[[str], str | None],
) -> dict[str, str]:
    """Return {filename: sha256} for the release the JSON describes."""
    if not isinstance(data, dict):
        raise ReleaseError("index response is not a JSON object")
    payload = cast("dict[str, object]", data)
    info = payload.get("info")
    urls = payload.get("urls")
    if not isinstance(info, dict) or not isinstance(urls, list):
        raise ReleaseError("index response lacks 'info' or 'urls'")
    info = cast("dict[str, object]", info)
    found_name, found_version = info.get("name"), info.get("version")
    if not isinstance(found_name, str) or not isinstance(found_version, str):
        raise ReleaseError("index response lacks the release name or version")
    if (
        canonical_name(found_name) != name
        or canonical_version(found_version) != version
    ):
        raise ReleaseError(
            f"index answered for {found_name} {found_version},"
            + f" not {name} {version}"
        )
    files: dict[str, str] = {}
    for entry in cast("list[object]", urls):
        if not isinstance(entry, dict):
            raise ReleaseError("index lists a file that is not a JSON object")
        entry = cast("dict[str, object]", entry)
        filename = entry.get("filename")
        digests = entry.get("digests")
        digest = (
            cast("dict[str, object]", digests).get("sha256")
            if isinstance(digests, dict)
            else None
        )
        if not isinstance(filename, str) or not filename:
            raise ReleaseError("index lists a file without a filename")
        if not isinstance(digest, str) or not _SHA256_RE.match(digest):
            raise ReleaseError(f"index lists {filename} without a SHA-256 digest")
        if files.get(filename, digest) != digest:
            raise ReleaseError(f"index lists {filename} with several digests")
        files[filename] = digest
    return files


def compare(
    selection_dir: Path,
    upload_dir: Path,
    index_url: str,
    name: str,
    version: str,
) -> tuple[str, int, int]:
    """Stage the missing files; return (state, upload_count, present_count)."""
    canonical_version = _load_canonical_version()
    if not name or canonical_name(name) != name:
        raise ReleaseError(f"project name is not normalised: {name!r}")
    if canonical_version(version) != version:
        raise ReleaseError(f"version is not normalised: {version!r}")
    for directory in (selection_dir, upload_dir):
        if directory.is_symlink() or not directory.is_dir():
            raise ReleaseError(f"not a directory: {directory}")
    if any(upload_dir.iterdir()):
        raise ReleaseError(f"upload directory is not empty: {upload_dir}")

    local: dict[str, str] = {}
    for entry in sorted(selection_dir.iterdir()):
        if not stat.S_ISREG(entry.lstat().st_mode):
            raise ReleaseError(f"{entry.name}: not a regular file")
        local[entry.name] = sha256_of(entry)
    if not local:
        raise ReleaseError(f"no distributions in {selection_dir}")

    quoted = "/".join(urllib.parse.quote(p, safe="") for p in (name, version))
    url = f"{check_index_url(index_url)}/pypi/{quoted}/json"
    print(f"Reading release files from: {url}")
    data = fetch_release(url)
    remote = (
        {} if data is None else remote_files(data, name, version, canonical_version)
    )

    conflicts = [f for f, d in local.items() if f in remote and remote[f] != d]
    if conflicts:
        details = "\n  ".join(
            f"{f}: selected {local[f]}, index holds {remote[f]}" for f in conflicts
        )
        raise ReleaseError(
            f"{name} {version} already holds different files of the same name:"
            + f"\n  {details}"
            + "\nA rebuild rarely reproduces the published files byte for"
            + " byte. To complete a partial release, use 'Re-run failed jobs'"
            + " so this job publishes the first attempt's artefacts again;"
            + " 'Re-run all jobs' or a new run for the tag builds new files."
        )

    missing = [f for f in local if f not in remote]
    for filename, digest in local.items():
        status = "missing; will upload" if filename in missing else "already present"
        print(f"{filename}: {status} (sha256 {digest})")
    for filename in sorted(set(remote) - set(local)):
        print(f"{filename}: on the index, not in the selection; left as is")
    for filename in missing:
        _ = shutil.copy2(selection_dir / filename, upload_dir / filename)

    present = len(local) - len(missing)
    if not missing:
        state = "complete"
    elif present:
        state = "partial"
    else:
        state = "absent"
    return state, len(missing), present


def main(argv: list[str]) -> int:
    """Run the comparison from the command line."""
    if len(argv) != 6:
        print(
            "Error: usage: compare-release.py <selection_dir> <upload_dir>"
            + " <index_url> <name> <version> ❌",
            file=sys.stderr,
        )
        return 2
    try:
        state, upload_count, present_count = compare(
            Path(argv[1]), Path(argv[2]), argv[3], argv[4], argv[5]
        )
    except ReleaseError as exc:
        print(f"Error: {exc} ❌", file=sys.stderr)
        print("Nothing will be uploaded ❌", file=sys.stderr)
        return 1
    print(
        f"Release state: {state};"
        + f" {present_count} already present, {upload_count} to upload ✅"
    )
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            _ = handle.write(
                f"state={state}\nupload_count={upload_count}\n"
                + f"present_count={present_count}\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
