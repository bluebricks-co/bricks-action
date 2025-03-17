# Bricks CLI Action

This GitHub Action manages Bricks CLI operations for Infrastructure as Code, enabling seamless deployment of blueprints, management of environments, and more.

## New Feature: Install Command with Matrix Support

The action now supports the `bricks install -f` command with enhanced functionality for production environments:

- **Deployment Plans**: Generate and display detailed deployment plans before execution
- **PR Comments**: Automatically comment deployment plans on Pull Requests for visibility
- **Matrix Execution**: Process multiple deployment files in parallel
- **Change Detection**: Automatically track changed deployment files in PRs

## Usage

### Basic Installation

```yaml
- name: Deploy Blueprint with Bricks
  uses: bluebricks-dev/bricks-action@main
  with:
    command: install
    file: ./manifests/deployment.yaml
    env: production
    api-key: ${{ secrets.BRICKS_API_KEY }}
```

### Plan-Only Mode

```yaml
- name: Create Deployment Plan
  uses: bluebricks-dev/bricks-action@main
  with:
    command: install
    file: ./manifests/deployment.yaml
    env: staging
    plan-only: true
    api-key: ${{ secrets.BRICKS_API_KEY }}
```

### Matrix Workflow for Multiple Deployments

For processing multiple deployment files in parallel, use the matrix workflow pattern:

```yaml
jobs:
  # Detect changes in deployments folder
  changes:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.set-matrix.outputs.matrix }}
      any_changes: ${{ steps.set-matrix.outputs.any_changes }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
        with:
          fetch-depth: 0

      - name: Get changed files
        id: changed-files
        run: |
          CHANGED_FILES=$(git diff --name-only ${{ github.event.pull_request.base.sha }} ${{ github.sha }} -- deployments/ | grep -E '\.ya?ml$' || echo "")
          echo "CHANGED_FILES=$CHANGED_FILES" >> $GITHUB_ENV

      - name: Set matrix
        id: set-matrix
        run: |
          if [[ -z "$CHANGED_FILES" ]]; then
            echo "matrix=[]" >> $GITHUB_OUTPUT
            echo "any_changes=false" >> $GITHUB_OUTPUT
          else
            FILES_JSON=$(echo "$CHANGED_FILES" | jq -R -s -c 'split("\n") | map(select(length > 0))')
            echo "matrix=${FILES_JSON}" >> $GITHUB_OUTPUT
            echo "any_changes=true" >> $GITHUB_OUTPUT
          fi

  # Create deployment plans
  bricks-plan:
    needs: changes
    if: needs.changes.outputs.any_changes == 'true'
    runs-on: ubuntu-latest
    strategy:
      matrix:
        file: ${{ fromJson(needs.changes.outputs.matrix) }}
      fail-fast: false
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Create Bricks deployment plan
        uses: bluebricks-dev/bricks-action@main
        with:
          command: install
          file: ${{ matrix.file }}
          env: staging
          plan-only: true
          api-key: ${{ secrets.BRICKS_API_KEY }}
```

See the full example in [matrix-workflow-example.yml](./matrix-workflow-example.yml).

## Inputs

The following inputs are available for the action:

| Input | Description | Required | Default |
|-------|-------------|----------|--------|
| `command` | Primary Bricks command | Yes | |
| `subcommand` | Subcommand for the primary command | No | |
| `file` | Path to YAML manifest file for install command | No | |
| `env` | Environment slug as deployment target | No | |
| `plan-only` | Create deployment plan without executing | No | `false` |
| `set-slug` | Set deployment slug | No | |
| `api-key` | Bricks API key for authentication | Yes | |
| `api-url` | Bricks API URL | No | `https://api.bluebricks.co` |
| `props` | JSON string of properties | No | |
| `props-file` | Path to JSON properties file | No | |
| `config-file` | Path to Bricks config file | No | `$HOME/.bricks/config.yaml` |
| `flags` | Additional flags for the command | No | |

## Outputs

| Output | Description |
|--------|-------------|
| `has_changes` | Boolean indicating whether changes were detected |
| `changes_summary` | Formatted summary of version changes |
| `dependency_graph` | Visual representation of dependency relationships |
| `deployment_plan` | Detailed deployment plan for install command |
| `plan_id` | Unique identifier for the generated plan |
| `error` | Error message if the command failed |

## PR Comments

When used in a PR context, the action will automatically comment with:

1. **Deployment Plan**: A detailed breakdown of resources to be created, updated, or deleted
2. **Change Summary**: A summary of any version changes to artifacts or blueprints
3. **Validation Warnings**: Any issues detected in the plan

## Setup Instructions

1. Store your Bricks API key as a GitHub secret (e.g., `BRICKS_API_KEY`)
2. Create deployment manifest files in your repository (e.g., in a `deployments/` folder)
3. Set up the workflow file as shown in the examples above
4. Configure your environments in the Bricks platform

## Best Practices

- Use `plan-only: true` for PRs to review changes before deployment
- Organize manifests in a dedicated folder (e.g., `deployments/`)
- Use descriptive filenames for deployments (e.g., `postgres-production.yaml`)
- Set reasonable limits on parallel jobs with `max-parallel` to avoid rate limiting
- Consider separate workflows for staging and production environments
