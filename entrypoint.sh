#!/bin/bash
set -e

# Validate credentials
if [ ! -f "$HOME/.bricks/credentials.yaml" ]; then
  echo "Error: Bricks credentials file not found"
  exit 1
fi

# Validate required input
if [ -z "$INPUT_COMMAND" ]; then
  echo "Error: command input is required"
  exit 1
fi

# Build the command as an array
CMD=("bricks" "$INPUT_COMMAND")

# Append subcommand if provided
if [ -n "$INPUT_SUBCOMMAND" ]; then
  CMD+=("$INPUT_SUBCOMMAND")
fi

# Append command-specific flags
case "$INPUT_COMMAND" in
  updateci)
    CMD+=(--artifacts-folder "$INPUT_ARTIFACTS_FOLDER")
    CMD+=(--blueprints-folder "$INPUT_BLUEPRINTS_FOLDER")
    CMD+=(--artifact-bump "$INPUT_ARTIFACT_BUMP")
    CMD+=(--blueprint-bump "$INPUT_BLUEPRINT_BUMP")
    CMD+=(--output "$INPUT_OUTPUT")
    CMD+=(--base "$INPUT_BASE")
    CMD+=(--head "$INPUT_HEAD")
    ;;
  install)
    # Handle install command specific flags
    [ -n "$INPUT_FILE" ] && CMD+=(--file "$INPUT_FILE")
    [ -n "$INPUT_ENV" ] && CMD+=(--env "$INPUT_ENV")
    [ -n "$INPUT_SET_SLUG" ] && CMD+=(--set-slug "$INPUT_SET_SLUG")
    [ "$INPUT_PLAN_ONLY" == "true" ] && CMD+=(--plan-only)
    ;;
  publish|bp)
    if [ -z "$INPUT_SRC" ]; then
      echo "Error: src is required for publish command"
      exit 1
    fi
    CMD+=(--src "$INPUT_SRC")
    ;;
  bprint)
    if [ "$INPUT_SUBCOMMAND" == "bump" ]; then
      case "$INPUT_BUMP_TYPE" in
        major) CMD+=(--major) ;;
        minor) CMD+=(--minor) ;;
        patch) CMD+=(--patch) ;;
      esac
    fi
    ;;
  *)
    # Additional commands can be handled here if needed
    ;;
esac

# Append additional generic flags if provided
[ -n "$INPUT_VERSION" ]     && CMD+=(--version "$INPUT_VERSION")
[ -n "$INPUT_PROPS" ]       && CMD+=(--props "$INPUT_PROPS")
[ -n "$INPUT_PROPS_FILE" ]  && CMD+=(--props-file "$INPUT_PROPS_FILE")
[ -n "$INPUT_LOG_LEVEL" ]   && CMD+=(--log-level "$INPUT_LOG_LEVEL")
[ -n "$INPUT_CONFIG" ]      && CMD+=(--config "$INPUT_CONFIG")

# Handle global flags (e.g., --dry) passed via INPUT_FLAGS.
if [ -n "$INPUT_FLAGS" ]; then
  # This loop will split the flags by whitespace and append them individually.
  for flag in $INPUT_FLAGS; do
    CMD+=("$flag")
  done
fi

echo "Executing: ${CMD[*]}"
echo "----------------------------------------"
# Capture the output of the bricks command and print it to stdout.
tmpfile=$(mktemp)
"${CMD[@]}" 2>&1 | tee "$tmpfile"
result=$(cat "$tmpfile")
rm "$tmpfile"

# Determine if changes occurred (this example uses a simple grep on "Updated Blueprints:")
if echo "$result" | grep -q "Updated Blueprints:"; then
  echo "has_changes=true" >> "$GITHUB_OUTPUT"
else
  echo "has_changes=false" >> "$GITHUB_OUTPUT"
fi

# Extract the changes summary.
# This example assumes the summary is between "Update Report:" and "Dependency Graph:"
changes_summary=$(echo "$result" | sed -n '/Update Report:/,/Dependency Graph:/p' | sed '1d;$d')
{
  echo "changes_summary<<EOF"
  echo "$changes_summary"
  echo "EOF"
} >> "$GITHUB_OUTPUT"

# Extract the dependency graph.
# This example assumes the dependency graph starts with "Dependency Graph:" and continues to the end.
dependency_graph=$(echo "$result" | sed -n '/Dependency Graph:/,$p' | sed '1d')
{
  echo "dependency_graph<<EOF"
  echo "$dependency_graph"
  echo "EOF"
} >> "$GITHUB_OUTPUT"

# Handle specific outputs for the install command
if [ "$INPUT_COMMAND" == "install" ]; then
  # Extract the deployment plan (for install command with --plan-only)
  if [ "$INPUT_PLAN_ONLY" == "true" ]; then
    # Extract deployment plan JSON from the output
    deployment_plan=$(echo "$result" | grep -o '{"plan":".*"}' || echo "")
    if [ -n "$deployment_plan" ]; then
      {
        echo "deployment_plan<<EOF"
        echo "$deployment_plan"
        echo "EOF"
      } >> "$GITHUB_OUTPUT"
    fi

    # Extract plan ID from the output
    plan_id=$(echo "$result" | grep -o 'https://app.bricks-dev.com/plans/[0-9a-f-]*' | awk -F'/' '{print $NF}' || echo "")
    if [ -n "$plan_id" ]; then
      echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
    fi
  else
    # Extract deployment ID from the output
    deployment_id=$(echo "$result" | grep -o 'https://app.bricks-dev.com/deployments/[0-9a-f-]*' | awk -F'/' '{print $NF}' || echo "")
    if [ -n "$deployment_id" ]; then
      echo "deployment_id=$deployment_id" >> "$GITHUB_OUTPUT"
      
      # Also extract plan ID from regular deployment output
      plan_id=$(echo "$result" | grep -o 'https://app.bricks-dev.com/plans/[0-9a-f-]*' | awk -F'/' '{print $NF}' || echo "")
      if [ -n "$plan_id" ]; then
        echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
      fi
      
      # Fetch the SVG visualization if we have a deployment ID and API URL
      if [ -n "$INPUT_API_URL" ]; then
        api_url="$INPUT_API_URL"
      else
        api_url="https://api.bluebricks.dev"
      fi
      
      echo "Fetching SVG visualization for deployment $deployment_id from $api_url..."
      
      # Get the SVG from the API, handle errors gracefully
      svg_response=$(curl -s "$api_url/v1/deployments/$deployment_id/svg" -H "Authorization: Bearer $BRICKS_API_KEY")
      
      if [[ "$svg_response" == *"<svg"* ]]; then
        # Base64 encode the SVG for embedding in markdown
        svg_base64=$(echo "$svg_response" | base64)
        echo "deployment_svg=$svg_base64" >> "$GITHUB_OUTPUT"
        echo "Successfully fetched SVG visualization"
      else
        echo "Failed to fetch SVG visualization: $svg_response"
      fi
    fi
  fi
fi

# Handle error output if applicable.
# For this example, we assume there's no error; otherwise, adjust accordingly.
error_message=""
echo "error=$error_message" >> "$GITHUB_OUTPUT"
