<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 📦 Publish Python Project to PyPI

Publishes a Python project to PyPI, the Python Package Index.

## pypi-publish-action

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: 'Publish to PyPI'
    uses: lfreleng-actions/pypi-publish-action@main
    with:
      environment: 'development'
      attestations: true
```

<!-- markdownlint-enable MD046 -->

### Multi-Platform Builds

For projects with platform-specific wheels (x64, ARM64, Python 3.10+),
use the `artefact_pattern` input to download all artefacts:

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - name: 'Publish to PyPI'
    uses: lfreleng-actions/pypi-publish-action@main
    with:
      environment: 'production'
      tag: 'v1.0.0'
      artefact_pattern: 'python-package-*'
      attestations: true
```

<!-- markdownlint-enable MD046 -->

This downloads all artefacts matching the pattern and merges them into one
download directory for publishing.

## Distribution Selection

The action never deletes files from your repository or project:

1. It downloads the build artefacts into a new, empty directory under
   `$RUNNER_TEMP`, outside the source tree.
2. It copies the regular `*.whl` and `*.tar.gz` files at the top level of
   that download into a new, empty selection directory, and publishes that
   selection. It ignores other files and subdirectories. A symlink,
   directory or other non-regular entry named like a distribution fails
   the run, as does a download with no wheel or sdist in it.
3. It copies the selected distributions to `path_prefix/artefact_path`
   (default `dist`) for later steps in your job. It adds or replaces
   files with those names and touches nothing else there. It writes each
   file under a temporary name and renames it into place, so it never
   writes into an existing file that a hard link shares with another path.
4. It removes the selection directory when it finishes.

The uploader runs in a container that mounts the workspace and nothing
else, so the selection directory is a hidden `.pypi-publish-dist.*`
directory at the workspace root, which the action creates and removes.

`artefact_path` must be a relative path without `..`. The action rejects
it, before downloading anything, when it resolves (following symlinks) to
the workspace root, the project root (`path_prefix`), a parent of the
project root, or a location outside the workspace.

## Release Verification

Before it copies anything to `artefact_path`, queries the package index,
selects or retrieves a credential, or uploads, the action reads the core
metadata (`METADATA` in a wheel, the top-level `PKG-INFO` in an sdist) of
every selected distribution, without extracting it. The run fails, naming
the expected and actual project and version, when the selection:

- holds no wheel or sdist, or holds any other entry;
- holds a distribution with a missing or repeated `Metadata-Version`,
  `Name` or `Version` field, or with an invalid name or version;
- holds a distribution whose checked metadata is not the file the
  uploader, Twine 7.0.0, would read: a wheel with another `METADATA`
  member Twine reads first, or an sdist with a repeated `PKG-INFO` or
  more than one top-level directory;
- holds a distribution of another project, compared after
  [PEP 503](https://peps.python.org/pep-0503/) normalisation, so
  `my_project`, `My.Project` and `my-project` match;
- holds a distribution of any version other than `tag`, compared as
  normalised [PEP 440](https://peps.python.org/pep-0440/) versions.

`tag` must be a valid PEP 440 version. The action accepts a leading `v`
or `V`: `v2.0.0` and `2.0.0` both request release `2.0.0`. Spellings that
normalise to the same version, such as `2.0.0-RC1` and `2.0.0rc1`, match.
Normalisation keeps trailing zeros: `2.0` does not match a `2.0.0`
distribution.

Next, still before any of those steps, the action validates the complete
metadata of every selected distribution with `twine check`. It installs
Twine 7.0.0, the version the uploader runs, into a temporary virtual
environment from the hash-locked
[`scripts/twine-requirements.txt`](scripts/twine-requirements.txt), so
metadata Twine would reject at upload, such as an unrecognised field or
an invalid `Requires-Python`, fails the run before the action chooses
or retrieves any credential.

The package index check and the summary link use the verified project
name and version. Every upload step also runs `twine check` on the
selection before uploading (`verify-metadata: true`).

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                     | Required | Description                                                |
| ------------------------ | -------- | ---------------------------------------------------------- |
| path_prefix              | False    | Directory location containing project code (default: '.')  |
| environment              | False    | Mandatory environment, e.g. development, production        |
| tag                      | True     | Tag for this build/release                                 |
| artefact_path            | False    | Where to copy the published distributions (default: dist)  |
| artefact_pattern         | False    | Glob pattern to download and merge build artefacts         |
| one_password_item        | False    | 1Password vault credential for PyPI publishing             |
| op_service_account_token | False    | 1Password service account credential to access vault       |
| pypi_credential          | False    | PyPI API credential from GitHub secrets                    |
| trusted_publishing       | False    | Controls trusted publishing behaviour (auto/true/false)    |
| publish_disable          | False    | Disables the final publishing step that uploads packages   |
| attestations             | False    | Enables GitHub support for artefact attestations           |
| no_checkout              | False    | Do not checkout local repository; used for testing         |

<!-- markdownlint-enable MD013 -->

## Implementation Details

Uses the upstream actions:

<!-- markdownlint-disable MD013 -->

- [1password/load-secrets-action](https://github.com/1password/load-secrets-action)
- [modeseven-lfreleng-actions/gh-action-pypi-publish](https://github.com/modeseven-lfreleng-actions/gh-action-pypi-publish)

The second action above is a modified/forked version of another action:

- [pypa/gh-action-pypi-publish](https://github.com/pypa/gh-action-pypi-publish)

<!-- markdownlint-enable MD013 -->

## Python on the Runner

The action needs `python3` on the job's `PATH`; GitHub-hosted runners
provide one. Three steps use that interpreter, with the repository you
publish checked out as the working directory:

<!-- markdownlint-disable MD013 -->

| Step                                     | Sub-action                                                                                          | What it runs                                                                                                             |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `Extract project/repository naming`      | [lfreleng-actions/build-metadata-action](https://github.com/lfreleng-actions/build-metadata-action) | `python3 -I -` to read `pyproject.toml` or `setup.py`, when `python3` is on `PATH`                                       |
| `Verify distributions match the release` | None                                                                                                | `python3 -I scripts/verify-distributions.py`, with no third-party packages, to read the selected distributions' metadata |
| `Check distribution metadata`            | None                                                                                                | `python3 -I -m venv`, then `pip install --require-hashes` of `scripts/twine-requirements.txt` and `twine check`          |

<!-- markdownlint-enable MD013 -->

The `Check distribution metadata` step needs Python 3.10 or later
with the `venv` module and its bundled `pip`, and downloads the pinned
wheels from the package index `pip` uses, `pypi.org` and
`files.pythonhosted.org` by default; a job behind an egress allow-list
must permit those hosts.

The `Checking package index for build/release` step, which runs
[lfreleng-actions/pypi-version-check-action](https://github.com/lfreleng-actions/pypi-version-check-action),
does not use the job's `python3` or `pip`. It installs uv and a
uv-managed Python 3.13 under `$RUNNER_TEMP`, and queries the package
index with that interpreter, outside the workspace. uv downloads the
interpreter from `releases.astral.sh`, so a job behind an egress
allow-list must permit that host. The upload step does not use the
job's `python3` either: `gh-action-pypi-publish` runs in a container
with its own Python.

The publishing job holds the publishing credentials (the OIDC token for
Trusted Publishing, or the API token), so start it from a clean
interpreter. Before calling this action, do not install the project
you publish, or anything else from the checkout, into that interpreter,
and do not add a checkout directory to `PATH` or `PYTHONPATH`.

The recommended layout calls this action in its own publishing job,
separate from the job that builds the project; the action downloads the
build artefacts that job uploaded, as in the usage examples above.

## Authentication Methods

Publishes using three different authentication methods.

In order of preference:

- [Trusted Publishing](https://docs.pypi.org/trusted-publishers/) (Uses an
OIDC token)
- Static credential retrieved from 1Password vault using a service account
- A static credential from GitHub secrets

### Trusted Publishing Input

When `trusted_publishing` is `auto` or `true`, the calling workflow job
**must** grant `id-token: write` permission for the OIDC token exchange to
succeed, and `contents: read` so the default `actions/checkout` step can run:

<!-- markdownlint-disable MD046 -->

```yaml
jobs:
  publish:
    runs-on: 'ubuntu-latest'
    permissions:
      contents: read
      id-token: write  # IMPORTANT: mandatory for trusted publishing
    steps:
      - name: 'Publish to PyPI'
        uses: lfreleng-actions/pypi-publish-action@main
        with:
          environment: 'production'
          tag: 'v1.0.0'
          trusted_publishing: 'true'
```

<!-- markdownlint-enable MD046 -->

The `trusted_publishing` input controls how the action selects its
authentication method:

<!-- markdownlint-disable MD013 -->

| Value   | Behaviour                                                                                                                                        |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `auto`  | Default. The action selects trusted publishing when the package already exists in the index. Falls back to credential-based methods otherwise.   |
| `true`  | Always use trusted publishing, even for first-time publishes. Use this when you pre-configure trusted publishing in the PyPI web portal.         |
| `false` | Never use trusted publishing. Always use credential-based methods (1Password or GitHub secret).                                                  |

<!-- markdownlint-enable MD013 -->

### Pre-Configured Trusted Publishing

<!-- markdownlint-disable MD013 -->

PyPI now supports configuring trusted publishers **before** a package has
ever had a release. When you pre-configure trusted publishing for a
new project on PyPI (or Test PyPI), set `trusted_publishing: 'true'` to
allow the first publish to use OIDC authentication directly, without
requiring a static API key.

<!-- markdownlint-enable MD013 -->

```yaml
- name: 'Publish to PyPI'
  uses: lfreleng-actions/pypi-publish-action@main
  with:
    environment: 'production'
    tag: 'v1.0.0'
    trusted_publishing: 'true'
```
