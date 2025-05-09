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
jobs:
  pypi-publish:
    name: 'Upload release to PyPI'
    runs-on: 'ubuntu-latest'
    environment:
      name: 'production'
    permissions:
      id-token: write  # IMPORTANT: this permission is mandatory for trusted publishing
    steps:
    - name: 'Publish to PyPI'
      uses: lfreleng-actions/pypi-publish-action@main
      with:
        environment: 'production'
        attestations: true
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                     | Required | Description                                              |
| ------------------------ | -------- | -------------------------------------------------------- |
| environment              | False    | Mandatory environment, e.g. development, production      |
| tag                      | False    | Tag for this build/release                               |
| artefact_path            | False    | Path/location of build artefacts                         |
| one_password_item        | False    | 1Password vault credential for PyPI publishing           |
| op_service_account_token | False    | 1Password service account credential to access vault     |
| pypi_credential          | False    | PyPI API credential from GitHub secrets                  |
| publish_disable          | False    | Disables the final publishing step that uploads packages |
| attesations              | False    | Enables GitHub support for artefact attestations         |
| no_checkout              | False    | Don't perform a checkout of the local repository         |

<!-- markdownlint-enable MD013 -->

## Permissions

This action needs the following permissions:

```yaml
permissions:
  id-token: write  # IMPORTANT: this permission is mandatory for trusted publishing
```

## Implementation Details

Uses the upstream actions:

- [1password/load-secrets-action](https://github.com/1password/load-secrets-action)
- [pypa/gh-action-pypi-publish](https://github.com/pypa/gh-action-pypi-publish)

## Authentication Methods

Publishes using three different authentication methods.

In order of preference:

- [Trusted Publishing][Trusted Publishing] (Uses an OIDC token)
- Static credential retrieved from 1Password vault using a service account
- A static credential from GitHub secrets

Note: the first/initial publishing step cannot leverage Trusted Publishing

The first time a given repository gets published to PyPI, a static API key
is necessary. After this, setup trusted publishing for the project in the
PyPI web portal.

[Trusted Publishing]: https://docs.pypi.org/trusted-publishers/
