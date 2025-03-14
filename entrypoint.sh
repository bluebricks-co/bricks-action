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
  publish|bp)
    if [ -z "$INPUT_SRC" ]; then
      echo "Error: src is required for publish command"
      exit 1
    fi
    CMD+=(--src "$INPUT_SRC")
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
    [ -n "$INPUT_ENV" ] && CMD+=(--env "$INPUT_ENV")
    [ "$INPUT_PLAN_ONLY" == "true" ] && CMD+=(--plan-only)
    [ -n "$INPUT_SET_SLUG" ] && CMD+=(--set-slug "$INPUT_SET_SLUG")
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
CMD_EXIT_CODE=${PIPESTATUS[0]}
result=$(cat "$tmpfile")
rm "$tmpfile"

# Log the entire command output for debugging
echo "Command output: $result"

# Set the exit code as an output
echo "exit_code=$CMD_EXIT_CODE" >> "$GITHUB_OUTPUT"

# Check if the command failed and handle error appropriately
if [ $CMD_EXIT_CODE -ne 0 ]; then
  echo "::error::Command execution failed with exit code $CMD_EXIT_CODE: ${CMD[*]}"
  echo "error=\"Command execution failed with exit code $CMD_EXIT_CODE: ${CMD[*]}\"" >> "$GITHUB_OUTPUT"
fi

# Process command output based on command type
case "$INPUT_COMMAND" in
  updateci)
    # Determine if changes occurred
    if echo "$result" | grep -q "Updated Blueprints:"; then
      echo "has_changes=true" >> "$GITHUB_OUTPUT"
    else
      echo "has_changes=false" >> "$GITHUB_OUTPUT"
    fi
    
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
    # Handle install command specific outputs
    function extract_plan_info() {
      echo "Starting plan info extraction"
      
      # Extract the full URL if present - try multiple patterns
      plan_url=$(echo "$result" | grep -o 'https://app[^[:space:]]*/plans/[0-9a-f-]*' | head -1 || echo "")
      echo "Extracted plan URL: $plan_url"
        
        # If that fails, try looking for any URL with 'installation log at'
        if [ -z "$plan_url" ]; then
          installation_log_url=$(echo "$result" | grep -o 'installation log at [^[:space:]]*' | sed 's/installation log at //' | head -1 || echo "")
          if [ -n "$installation_log_url" ]; then
            plan_url="$installation_log_url"
          fi
        fi
        echo "Final plan URL: $plan_url"
      
        # Extract just the UUID using multiple patterns in order of specificity
        if [ -n "$plan_url" ]; then
          plan_id=$(echo "$plan_url" | awk -F'/' '{print $NF}')
        else
          plan_id=$(echo "$result" | grep -o 'installation log at [^[:space:]]*' | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' || echo "")
          if [ -z "$plan_id" ]; then
            plan_id=$(echo "$result" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | head -1 || echo "")
            if [ -n "$plan_id" ]; then
              if [ -n "$INPUT_API_URL" ]; then
                base_url=$(echo "$INPUT_API_URL" | sed 's/api\./app./g')
                plan_url="$base_url/plans/$plan_id"
              else
                plan_url="https://app.bluebricks.co/plans/$plan_id"
              fi
            fi
          fi
        fi
        echo "Extracted plan ID: $plan_id"
      
        if [ -n "$plan_id" ]; then
          echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
          echo "plan_url=$plan_url" >> "$GITHUB_OUTPUT"
          {
            echo "plan_summary<<EOF"
            echo "Deployment plan created: $plan_url" >> "$GITHUB_STEP_SUMMARY"
            echo "Plan ID: $plan_id"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"
        else
          echo "plan_id=" >> "$GITHUB_OUTPUT"
          echo "plan_url=" >> "$GITHUB_OUTPUT"
        fi
      } plan info extraction"

      # Extract the full URL if present - try multiple patterns
      plan_url=$(echo "$result" | grep -o 'https://app[^[:space:]]*/plans/[0-9a-f-]*' | head -1 || echo "")
      echo "Extracted plan URL: $plan_url"
      
      # If that fails, try looking for any URL with 'installation log at'
      if [ -z "$plan_url" ]; then
        installation_log_url=$(echo "$result" | grep -o 'installation log at [^[:space:]]*' | sed 's/installation log at //' | head -1 || echo "")
        if [ -n "$installation_log_url" ]; then
          plan_url="$installation_log_url"
        fi
      fi
      echo "Final plan URL: $plan_url"

      # Extract just the UUID using multiple patterns in order of specificity
      if [ -n "$plan_url" ]; then
        plan_id=$(echo "$plan_url" | awk -F'/' '{print $NF}')
      else
        plan_id=$(echo "$result" | grep -o 'installation log at [^[:space:]]*' | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' || echo "")
        if [ -z "$plan_id" ]; then
          plan_id=$(echo "$result" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | head -1 || echo "")
          if [ -n "$plan_id" ]; then
            if [ -n "$INPUT_API_URL" ]; then
              base_url=$(echo "$INPUT_API_URL" | sed 's/api\./app./g')
              plan_url="$base_url/plans/$plan_id"
            else
              plan_url="https://app.bluebricks.co/plans/$plan_id"
            fi
          fi
        fi
      fi
      echo "Extracted plan ID: $plan_id"

      if [ -n "$plan_id" ]; then
        echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
        echo "plan_url=$plan_url" >> "$GITHUB_OUTPUT"
        {
          echo "plan_summary<<EOF"
          echo "Deployment plan created: $plan_url" >> "$GITHUB_STEP_SUMMARY"
          echo "Plan ID: $plan_id"
          echo "EOF"
        } >> "$GITHUB_OUTPUT"
      else
        echo "plan_id=" >> "$GITHUB_OUTPUT"
        echo "plan_url=" >> "$GITHUB_OUTPUT"
      fi
    }
    
    # Call the function to extract plan info
    extract_plan_info

    # Check for auto-approve logic
    # If no explicit approval logic is found, ensure that the plan is not auto-approved unless specified
    if [ "$INPUT_PLAN_ONLY" != "true" ]; then
      echo "::notice::Proceeding Plan Only."
    fi

    # Fetch SVG visualization for plan
    if [ -n "$plan_id" ]; then
      if [ -n "$INPUT_API_URL" ]; then
        api_url="$INPUT_API_URL"
      else
        api_url="https://api.bluebricks.co"
      fi
      
      svg_response=$(curl -s "$api_url/api/v1/deployment/$plan_id/image" -H "Authorization: Bearer $BRICKS_API_KEY")
      
      if [[ "$svg_response" == *"<svg"* ]]; then
        svg_base64=$(echo "$svg_response" | base64)
        echo "plan_svg=$svg_base64" >> "$GITHUB_OUTPUT"
        echo "![Deployment SVG](data:image/svg+xml;base64,$svg_base64)" >> "$GITHUB_STEP_SUMMARY"
      else
        echo "::warning::Failed to fetch SVG visualization: API returned invalid response"
      fi
    fi
    ;;
    
  *)
    # For other commands, just set default outputs
    # Determine if changes occurred (this is the original behavior)
    if echo "$result" | grep -q "Updated Blueprints:"; then
      echo "has_changes=true" >> "$GITHUB_OUTPUT"
    else
      echo "has_changes=false" >> "$GITHUB_OUTPUT"
    fi
    ;;
esac

# If we've reached this point and the command was successful, ensure we have a clean error output
if [ $CMD_EXIT_CODE -eq 0 ]; then
  echo "error=" >> "$GITHUB_OUTPUT"
fi

# Exit with the same code as the command
exit $CMD_EXIT_CODE
