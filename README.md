# Bricks CLI GitHub Action

> [GitHub Action](https://github.com/features/actions) for running [Bricks CLI](https://docs.bluebricks.co/bluebricks-documentation/bricks-cli/commands-reference) commands in your workflows

[![GitHub Release](https://img.shields.io/github/release/bluebricks-co/bricks-action.svg?logo=github)](https://github.com/bluebricks-co/bricks-action/releases/latest)
[![License](https://img.shields.io/github/license/bluebricks-co/bricks-action)](LICENSE)
![](docs/images/bricks-action.png)

---

## Table of Contents

- [Overview](#overview)
- [Usage](#usage)
  - [Example: Update Artifacts and Blueprints](#example-update-artifacts-and-blueprints)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Prerequisites](#prerequisites)
- [Customization](#customization)
- [All Bricks CLI Commands](#all-bricks-cli-commands)
- [License](#license)

---

## Overview

The Bricks CLI GitHub Action lets you run any Bricks CLI command directly within your GitHub Actions workflows. It provides a seamless way to automate tasks like version bumping, blueprint updates, and artifact publishing as part of your CI/CD process.  
For the full list of available Bricks CLI commands, please see the [Bricks CLI Commands Reference](https://docs.bluebricks.co/bluebricks-documentation/bricks-cli/commands-reference).

---

## Usage

### Example: Update Artifacts and Blueprints

This example workflow triggers on pull request events and pull request reviews. It uses the `updateci` command to detect changes, update artifact versions, and adjust blueprints accordingly.

```yaml
name: Update Artifacts and Blueprints on PR

on:
  pull_request:
    types: [opened, synchronize, reopened]
  pull_request_review:
    types: [submitted]

permissions:
  id-token: write
  contents: write
  pull-requests: write

jobs:
  updateci:
    runs-on: ubuntu-latest
    if: |
      (github.event_name == 'pull_request') ||
      (github.event_name == 'pull_request_review' && github.event.review.state == 'approved')

    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
          ref: ${{ github.event.pull_request.head.ref }}  # PR branch

      - name: Run updateci Command
        uses: bluebricks-co/bricks-action@v1.0.0
        with:
          command: 'updateci'
          artifacts-folder: 'bluebricks/packages'
          blueprints-folder: 'bluebricks/blueprints'
          artifact-bump: 'patch'
          blueprint-bump: 'patch'
          base: '${{ github.base_ref }}'
          api-key: ${{ secrets.BRICKS_API_KEY }}
          flags: ${{ github.event_name == 'pull_request' && '--dry' || '' }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Inputs

### Global Input

- **`command`**  
  **Required.** The Bricks CLI command to execute.  
  _Note:_ All commands available in Bricks CLI are supported. See the [Bricks CLI Commands Reference](https://docs.bluebricks.co/bluebricks-documentation/bricks-cli/commands-reference) for details.

#### For the `updateci` Command

| Input               | Type    | Default                    | Description                                                   |
|---------------------|---------|----------------------------|---------------------------------------------------------------|
| `artifacts-folder`  | String  | `bluebricks/artifacts`     | Path to the artifacts folder.                                 |
| `blueprints-folder` | String  | `bluebricks/blueprints`    | Path to the blueprints folder.                                |
| `artifact-bump`     | String  | `patch`                    | Version bump type for artifacts.                              |
| `blueprint-bump`    | String  | `patch`                    | Version bump type for blueprints.                             |
| `output`            | String  | `ascii`                    | Output format for dependency graph (`ascii` or `json`).       |
| `api-key`           | String  | —                          | **Required.** Your Bricks API key for authentication.         |
| `flags`             | String  | —                          | Additional flags to pass to the Bricks CLI command (e.g., `--dry`). |

---

## Outputs

For the `updateci` command, the following outputs are available:

| Output              | Description                                                       |
|---------------------|-------------------------------------------------------------------|
| `has_changes`       | Boolean indicating whether any changes were applied.              |
| `changes_summary`   | Summary of the changes made to artifacts and blueprints.          |
| `dependency_graph`  | Dependency graph in the specified format.                         |

---

## Prerequisites

1. **Bricks API Key**  
   - **Requirement:** A valid Bricks API key is required to authenticate with the Bricks service and perform version bumps, blueprint updates, and publishing operations.  
   - **How to Generate:** Follow the steps outlined in the [official Bluebricks documentation](https://docs.bluebricks.co/bluebricks-documentation/api/long-lived-api-tokens).  
   - **Tip:** Store your API key securely in your GitHub repository secrets as `BRICKS_API_KEY`.

2. **GitHub Token**  
   - **Requirement:** The action leverages GitHub's built-in `GITHUB_TOKEN` to perform Git operations such as commits and pushes.  
   - **Setup:** Ensure that your workflow has the necessary permissions (e.g., `contents: write`, `pull-requests: write`).

3. **Repository Organization**  
   - Structure your repository with designated directories for artifacts and blueprints (e.g., `bluebricks/packages` and `bluebricks/blueprints`).  
   - Prepare a Bricks configuration file (e.g., `config-dev.yaml`) with your project-specific settings.

---

## Customization

Configuration priority for Bricks CLI options is as follows:

1. **GitHub Action Input Flags**  
2. **Environment Variables**  
3. **Bricks Configuration File**  
4. **Default Values**

You can customize any aspect of your Bricks CLI commands by combining inputs, environment variables, and configuration files. For further details, please refer to the [Bricks CLI Commands Reference](https://docs.bluebricks.co/bluebricks-documentation/bricks-cli/commands-reference).

---

## All Bricks CLI Commands

This action supports the full suite of Bricks CLI commands. Whether you need to bump versions, update blueprints, publish artifacts, or perform any other supported operation, simply pass the desired command via the `command` input.  
For a complete list and details, see the [Bricks CLI Commands Reference](https://docs.bluebricks.co/bluebricks-documentation/bricks-cli/commands-reference).

---

## License

This project is licensed under the [Apache License](LICENSE).

---

By following the instructions above, you can easily integrate the Bricks CLI GitHub Action into your workflows to automate your infrastructure-as-code tasks with confidence and ease.
