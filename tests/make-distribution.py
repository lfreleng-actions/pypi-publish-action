# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Build a minimal wheel or sdist for tests, using the standard library.

Usage: python3 make-distribution.py <wheel|sdist> <out_dir> <name> <version>
       [--omit=FIELD ...] [--no-metadata] [--extra=PATH,NAME,VERSION ...]
       [--header=LINE ...]

Prints the path of the file it writes. --omit leaves a core metadata
field out; --no-metadata leaves the metadata file out entirely; --extra
adds, ahead of the real metadata, a member at PATH holding metadata for
NAME and VERSION; --header appends LINE, such as 'Field: value', to the
real metadata's headers.
"""

from __future__ import annotations

import io
import re
import sys
import tarfile
import zipfile
from pathlib import Path


def metadata(
    name: str, version: str, omit: list[str], headers: list[str] | None = None
) -> bytes:
    """Return core metadata for the fixture."""
    fields = {"Metadata-Version": "2.1", "Name": name, "Version": version}
    lines = [f"{k}: {v}" for k, v in fields.items() if k not in omit]
    lines += headers or []
    return ("\n".join(lines) + "\n\nFixture distribution.\n").encode()


def main(argv: list[str]) -> int:
    """Write the requested fixture distribution."""
    positional = [a for a in argv[1:] if not a.startswith("--")]
    options = [a for a in argv[1:] if a.startswith("--")]
    omit = [a.removeprefix("--omit=") for a in options if a.startswith("--omit=")]
    no_metadata = "--no-metadata" in options
    headers = [
        a.removeprefix("--header=") for a in options if a.startswith("--header=")
    ]
    extras = [
        a.removeprefix("--extra=").split(",")
        for a in options
        if a.startswith("--extra=")
    ]
    unknown = [
        a
        for a in options
        if a != "--no-metadata"
        and not a.startswith(("--omit=", "--extra=", "--header="))
    ]
    if (
        len(positional) != 4
        or positional[0] not in ("wheel", "sdist")
        or unknown
        or any(len(e) != 3 for e in extras)
    ):
        print(__doc__, file=sys.stderr)
        return 2
    kind, out_dir, name, version = positional

    stem = f"{re.sub(r'[-_.]+', '_', name).lower()}-{version}"
    # A list, not a dict, so a repeated member path stays repeated
    members = [(p, metadata(n, v, [])) for p, n, v in extras]
    if kind == "wheel":
        path = Path(out_dir) / f"{stem}-py3-none-any.whl"
        members.insert(0, ("fixture/__init__.py", b'"""Fixture."""\n'))
        if not no_metadata:
            members.append(
                (
                    f"{stem}.dist-info/METADATA",
                    metadata(name, version, omit, headers),
                )
            )
        with zipfile.ZipFile(path, "w") as archive:
            for member, data in members:
                archive.writestr(member, data)
    else:
        path = Path(out_dir) / f"{stem}.tar.gz"
        members.insert(0, (f"{stem}/setup.cfg", b"[metadata]\n"))
        if not no_metadata:
            members.append((f"{stem}/PKG-INFO", metadata(name, version, omit, headers)))
        with tarfile.open(path, "w:gz") as archive:
            for member, data in members:
                info = tarfile.TarInfo(member)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
