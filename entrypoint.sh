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

# Set API URLs
set_api_url() {
  if [ -n "$INPUT_API_URL" ]; then
    api_url="$INPUT_API_URL"
    app_url=$(echo "$INPUT_API_URL" | sed 's/api\./app./g')
  else
    api_url="https://api.bluebricks.co"
    app_url="https://app.bluebricks.co"
  fi
  export api_url
  export app_url
}

# Initialize API URLs
set_api_url

make_api_request() {
  FULL_URL=$api_url$1
  TEMP_FILE=$(mktemp)
  HTTP_CODE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer ${INPUT_API_KEY}" \
    -o "$TEMP_FILE" "$FULL_URL")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "::warning::API request to $1 failed with HTTP $HTTP_CODE" >&2
    rm "$TEMP_FILE"
    return 0
  fi
  cat "$TEMP_FILE"
  rm "$TEMP_FILE"
}

# Extract plan information from command output
extract_plan_info() {
  plan_url=$(echo "$result" | grep -o 'https://app[^[:space:]]*/plans/[0-9a-f-]*' | head -1 || echo "")
  plan_id=$(echo "$plan_url" | awk -F'/' '{print $NF}')
  echo "Extracted plan ID: $plan_id"

  if [ -n "$plan_id" ]; then
    echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
    echo "plan_url=$plan_url" >> "$GITHUB_OUTPUT"
    artifacts_plan_ids="$(make_api_request /api/v1/deployment/$plan_id | jq -r '[.children[] | "\(.name):\(.deployment)"] | join(",")')"
    echo "Extracted artifact IDs: $artifacts_plan_ids"
    echo "artifacts_plan_ids=$artifacts_plan_ids" >> "$GITHUB_OUTPUT"
  else
    echo "plan_id=" >> "$GITHUB_OUTPUT"
    echo "plan_url=" >> "$GITHUB_OUTPUT"
    echo "artifacts_plan_ids=" >> "$GITHUB_OUTPUT"
  fi
}

# Handle command exit status
handle_command_exit() {
  local exit_code=$1
  if [ "$exit_code" -ne 0 ]; then
    error_message="Command execution failed with exit code $exit_code: ${CMD[*]}"
    echo "::error::$error_message"
    echo "error=\"$error_message\"" >> "$GITHUB_OUTPUT"
  else
    echo "error=" >> "$GITHUB_OUTPUT"
  fi
}

# Set has_changes output
set_has_changes_output() {
  if echo "$result" | grep -q "Updated Blueprints:"; then
    echo "has_changes=true" >> "$GITHUB_OUTPUT"
  else
    echo "has_changes=false" >> "$GITHUB_OUTPUT"
  fi
}

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
    # Handle install command arguments
    if [ -n "$INPUT_PACKAGE" ]; then
      # Install a specific package
      CMD+=("$INPUT_PACKAGE")
    elif [ -n "$INPUT_FILE" ]; then
      # Install from a manifest file
      CMD+=(-f "$INPUT_FILE")
    fi
    
    # Add common install options if specified
    if [ -n "$INPUT_COLLECTION" ]; then
      CMD+=(--collection "$INPUT_COLLECTION")
    elif [ -n "$INPUT_ENV" ]; then
      echo "::warning::Input 'env' is deprecated, use 'collection' instead"
      CMD+=(--collection "$INPUT_ENV")
    fi
    [ "$INPUT_PLAN_ONLY" == "true" ] && CMD+=(--plan-only)
    [ -n "$INPUT_SET_SLUG" ] && CMD+=(--set-slug "$INPUT_SET_SLUG")
    ;;
  bprint|bp)
    if [ "$INPUT_SUBCOMMAND" == "publish" ]; then
      if [ -z "$INPUT_SRC" ]; then
        echo "Error: src is required for bprint publish"
        exit 1
      fi
      CMD+=(--src "$INPUT_SRC")
    elif [ "$INPUT_SUBCOMMAND" == "bump" ]; then
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
script --return -q -c "${CMD[*]}" 2>&1 | tee "$tmpfile"
CMD_EXIT_CODE=${PIPESTATUS[0]}
result=$(cat "$tmpfile")
rm "$tmpfile"

# Log the entire command output for debugging
echo "Command output: $result"

echo "Command exit code: $CMD_EXIT_CODE"

# Set the exit code as an output
echo "exit_code=$CMD_EXIT_CODE" >> "$GITHUB_OUTPUT"

# Handle command exit status
handle_command_exit "$CMD_EXIT_CODE"

# Process command output based on command type
case "$INPUT_COMMAND" in
  updateci)
    # Set has_changes output
    set_has_changes_output
    
    # Extract the changes summary.
    # This assumes the summary is between "Update Report:" and "Dependency Graph:"
    changes_summary=$(echo "$result" | sed -n '/Update Report:/,/Dependency Graph:/p' | sed '1d;$d')
    {
      echo "changes_summary<<EOF"
      echo "$changes_summary"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
    
    # Extract the dependency graph.
    # This assumes the dependency graph starts with "Dependency Graph:" and continues to the end.
    dependency_graph=$(echo "$result" | sed -n '/Dependency Graph:/,$p' | sed '1d')
    {
      echo "dependency_graph<<EOF"
      echo "$dependency_graph"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
    ;;
    
  install)
    # Extract plan information
    extract_plan_info
    
    ;;

  bprint|bp)
    echo "$result" >> "$GITHUB_STEP_SUMMARY"
    ;;
  *)
    # For other commands, set has_changes output
    set_has_changes_output
    ;;
esac

# Exit with the same code as the command
exit $CMD_EXIT_CODE
