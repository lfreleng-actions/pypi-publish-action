# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Verify that selected distributions belong to the requested release.

Usage: python3 -I verify-distributions.py <selection_dir> <name> <tag>

Reads the core metadata of every wheel (``*.whl``) and sdist
(``*.tar.gz``) in <selection_dir> without extracting anything. Fails
when the directory holds no distribution, holds anything else, or
holds a distribution whose metadata is missing, invalid or ambiguous,
or whose project name or version differs from the expected release.
The metadata checked must be the member the pinned uploader, twine
7.0.0, would read: a wheel or sdist where twine would pick another
member, or with a repeated metadata member, fails.

Project names compare after PEP 503 normalisation. Versions compare as
normalised PEP 440 versions; a leading ``v`` or ``V`` on <tag> is
accepted, as PEP 440 normalisation permits. On success, writes the
verified ``name`` and ``version`` to ``$GITHUB_OUTPUT`` when set.

Uses only the Python standard library.
"""

from __future__ import annotations

import os
import re
import stat
import sys
import tarfile
import zipfile
from email.message import Message
from email.parser import HeaderParser
from email.policy import compat32
from pathlib import Path

# Core metadata is small; refuse to read an oversized member
MAX_METADATA_BYTES = 16 * 1024 * 1024

# PEP 440 Appendix B, with the leading 'v' PEP 440 normalisation allows
_VERSION_RE = re.compile(
    r"""
    ^\s*v?
    (?:(?P<epoch>[0-9]+)!)?
    (?P<release>[0-9]+(?:\.[0-9]+)*)
    (?P<pre>
        [-_.]?
        (?P<pre_l>alpha|a|beta|b|preview|pre|c|rc)
        [-_.]?
        (?P<pre_n>[0-9]+)?
    )?
    (?P<post>
        (?:-(?P<post_n1>[0-9]+))
        |
        (?:
            [-_.]?
            (?P<post_l>post|rev|r)
            [-_.]?
            (?P<post_n2>[0-9]+)?
        )
    )?
    (?P<dev>
        [-_.]?
        (?P<dev_l>dev)
        [-_.]?
        (?P<dev_n>[0-9]+)?
    )?
    (?:\+(?P<local>[a-z0-9]+(?:[-_.][a-z0-9]+)*))?
    \s*$
    """,
    re.VERBOSE | re.IGNORECASE,
)

_PRE_LABELS = {
    "alpha": "a",
    "a": "a",
    "beta": "b",
    "b": "b",
    "c": "rc",
    "pre": "rc",
    "preview": "rc",
    "rc": "rc",
}

# Core metadata name rule (PEP 508 identifier)
_NAME_RE = re.compile(r"^([A-Z0-9]|[A-Z0-9][A-Z0-9._-]*[A-Z0-9])$", re.IGNORECASE)
_METADATA_VERSION_RE = re.compile(r"^[12]\.[0-9]+$")
_WHEEL_METADATA_RE = re.compile(r"^[^/]+\.dist-info/METADATA$")
_SDIST_METADATA_RE = re.compile(r"^[^/]+/PKG-INFO$")


class DistributionError(Exception):
    """A distribution cannot be read or its metadata is invalid."""


def canonical_name(name: str) -> str:
    """Return a project name normalised as PEP 503 describes."""
    return re.sub(r"[-_.]+", "-", name).lower()


def canonical_version(version: str) -> str | None:
    """Return the normalised PEP 440 form of version, or None if invalid."""
    match = _VERSION_RE.match(version)
    if match is None:
        return None
    parts: list[str] = []
    epoch = int(match.group("epoch") or 0)
    if epoch:
        parts.append(f"{epoch}!")
    parts.append(".".join(str(int(n)) for n in match.group("release").split(".")))
    if match.group("pre"):
        label = _PRE_LABELS[match.group("pre_l").lower()]
        parts.append(f"{label}{int(match.group('pre_n') or 0)}")
    if match.group("post"):
        number = match.group("post_n1") or match.group("post_n2") or 0
        parts.append(f".post{int(number)}")
    if match.group("dev"):
        parts.append(f".dev{int(match.group('dev_n') or 0)}")
    if match.group("local"):
        segments = re.split(r"[-_.]", match.group("local").lower())
        parts.append(
            "+" + ".".join(str(int(s)) if s.isdigit() else s for s in segments)
        )
    return "".join(parts)


def _single(members: list[str], kind: str, path: Path) -> str:
    if len(members) != 1:
        found = ", ".join(members) if members else "none"
        raise DistributionError(
            f"{path.name}: expected one {kind} metadata file, found {found}"
        )
    return members[0]


def _uploader_wheel_member(archive: zipfile.ZipFile, path: Path) -> str | None:
    """Return the member twine 7.0.0 reads as a wheel's metadata.

    Twine takes every member whose name contains METADATA, orders them
    by path depth and then by path, and reads the first one holding
    Metadata-Version. The verified metadata must be that member.
    """
    candidates = sorted(
        (len(parts), parts)
        for parts in (n.split("/") for n in archive.namelist() if "METADATA" in n)
    )
    for _, parts in candidates:
        name = "/".join(parts)
        if archive.getinfo(name).file_size > MAX_METADATA_BYTES:
            raise DistributionError(f"{path.name}: oversized {name}")
        if b"Metadata-Version" in archive.read(name):
            return name
    return None


def read_wheel_metadata(path: Path) -> bytes:
    """Return the METADATA bytes of a wheel."""
    try:
        with zipfile.ZipFile(path) as archive:
            names = [n for n in archive.namelist() if _WHEEL_METADATA_RE.match(n)]
            member = archive.getinfo(_single(names, "wheel", path))
            if member.is_dir() or member.file_size > MAX_METADATA_BYTES:
                raise DistributionError(f"{path.name}: unusable {member.filename}")
            uploaded = _uploader_wheel_member(archive, path)
            if uploaded is not None and uploaded != member.filename:
                found = f"{uploaded}, not {member.filename}"
                raise DistributionError(f"{path.name}: uploader would read {found}")
            return archive.read(member)
    except (zipfile.BadZipFile, OSError, EOFError) as exc:
        raise DistributionError(f"{path.name}: not a valid wheel: {exc}") from exc


def read_sdist_metadata(path: Path) -> bytes:
    """Return the top-level PKG-INFO bytes of an sdist."""
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            # Keep repeated members: twine reads the last of them
            members = [
                m for m in archive.getmembers() if _SDIST_METADATA_RE.match(m.name)
            ]
            _ = _single([m.name for m in members], "sdist", path)
            member = members[0]
            if not member.isfile() or member.size > MAX_METADATA_BYTES:
                raise DistributionError(f"{path.name}: unusable {member.name}")
            # Twine 7.0.0 reads PKG-INFO under the members' common root
            try:
                root = os.path.commonpath(archive.getnames())
            except ValueError:
                root = ""
            if member.name != root.rstrip("/") + "/PKG-INFO":
                where = "a single top-level directory"
                raise DistributionError(f"{path.name}: {member.name} not under {where}")
            handle = archive.extractfile(member)
            if handle is None:
                raise DistributionError(f"{path.name}: unreadable {member.name}")
            return handle.read()
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise DistributionError(f"{path.name}: not a valid sdist: {exc}") from exc


def parse_metadata(path: Path, raw: bytes) -> tuple[str, str]:
    """Validate core metadata; return its (Name, normalised Version)."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise DistributionError(f"{path.name}: metadata is not UTF-8") from exc
    headers: Message[str, str] = HeaderParser(policy=compat32).parsestr(text)
    fields: dict[str, str] = {}
    for field in ("Metadata-Version", "Name", "Version"):
        values: list[str] = headers.get_all(field, [])
        if len(values) != 1 or not values[0].strip():
            raise DistributionError(
                f"{path.name}: metadata needs exactly one {field} field"
            )
        fields[field] = values[0].strip()
    if not _METADATA_VERSION_RE.match(fields["Metadata-Version"]):
        raise DistributionError(
            f"{path.name}: unsupported Metadata-Version {fields['Metadata-Version']!r}"
        )
    if not _NAME_RE.match(fields["Name"]):
        raise DistributionError(f"{path.name}: invalid Name {fields['Name']!r}")
    version = canonical_version(fields["Version"])
    if version is None:
        raise DistributionError(f"{path.name}: invalid Version {fields['Version']!r}")
    return fields["Name"], version


def verify(selection_dir: Path, expected_name: str, tag: str) -> tuple[str, str]:
    """Verify the selection; return the verified (name, version)."""
    want_name = canonical_name(expected_name.strip())
    want_version = canonical_version(tag)
    if not want_name:
        raise DistributionError("no expected project name given")
    if want_version is None:
        raise DistributionError(f"tag {tag!r} is not a valid PEP 440 version")

    errors: list[str] = []
    count = 0
    for entry in sorted(selection_dir.iterdir()):
        mode = entry.lstat().st_mode
        if entry.name.endswith(".whl"):
            reader = read_wheel_metadata
        elif entry.name.endswith(".tar.gz"):
            reader = read_sdist_metadata
        else:
            errors.append(f"{entry.name}: not a wheel or sdist")
            continue
        if not stat.S_ISREG(mode):
            errors.append(f"{entry.name}: not a regular file")
            continue
        count += 1
        try:
            name, version = parse_metadata(entry, reader(entry))
        except DistributionError as exc:
            errors.append(str(exc))
            continue
        if canonical_name(name) != want_name or version != want_version:
            found = f"{canonical_name(name)} {version}"
            errors.append(
                f"{entry.name}: expected {want_name} {want_version}, found {found}"
            )
        else:
            print(f"Verified: {entry.name} ({want_name} {want_version}) ✅")
    if count == 0:
        errors.append("no wheel (*.whl) or sdist (*.tar.gz) distributions")
    if errors:
        raise DistributionError(
            f"selection does not match {want_name} {want_version}:\n  "
            + "\n  ".join(errors)
        )
    return want_name, want_version


def main(argv: list[str]) -> int:
    """Run the verification from the command line."""
    if len(argv) != 4:
        print(
            "Error: usage: verify-distributions.py <selection_dir> <name> <tag> ❌",
            file=sys.stderr,
        )
        return 2
    selection_dir = Path(argv[1])
    if selection_dir.is_symlink() or not selection_dir.is_dir():
        print(f"Error: not a directory: {selection_dir} ❌", file=sys.stderr)
        return 1
    try:
        name, version = verify(selection_dir, argv[2], argv[3])
    except DistributionError as exc:
        print(f"Error: {exc} ❌", file=sys.stderr)
        return 1
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            _ = handle.write(f"name={name}\nversion={version}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
