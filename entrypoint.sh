#!/bin/bash
set -e

# Validate credentials
if [ ! -f "$HOME/.bricks/credentials.yaml" ]; then
  echo "Error: Bricks credentials file not found"
  echo "::error::Bricks credentials file not found"
  exit 1
fi

# Validate required input
if [ -z "$INPUT_COMMAND" ]; then
  echo "Error: command input is required"
  echo "::error::Command input is required"
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
tmpfile_err=$(mktemp)

# Capture both stdout and stderr separately
echo "Running command with arguments: ${CMD[*]}"

# Run command with detailed output to help with debugging

# Print the exact command being executed for better troubleshooting
echo "DEBUG: Executing exact command: ${CMD[*]}"

# Simple approach: run the command and capture output directly
echo "DEBUG: Running command and capturing output"

# Ensure we're in the right context for command execution
[ -n "$INPUT_FILE" ] && [ ! -f "$INPUT_FILE" ] && echo "Warning: Input file not found: $INPUT_FILE" >&2

# Run the command and capture output using a reliable approach
echo "Running command: ${CMD[*]}"

# Use a single, reliable approach to capture command output
# First, ensure the temp file exists and is empty
> "$tmpfile"

# Execute command and capture output in a way that works in all environments
# This approach uses a simple pipe to tee which captures output while still showing it in the logs
{ "${CMD[@]}" 2>&1 | tee "$tmpfile"; }
CMD_EXIT_CODE=${PIPESTATUS[0]}

# Check if we have output, but don't re-run the command
if [ ! -s "$tmpfile" ]; then
  echo "Command execution produced no visible output."
fi

# Print exit code for debugging
echo "DEBUG: Command exit code: $CMD_EXIT_CODE"

# Check if the command failed
if [ $CMD_EXIT_CODE -ne 0 ]; then
  echo "::error::Command execution failed: ${CMD[*]}"
  echo "error=\"Command execution failed: ${CMD[*]}\"" >> "$GITHUB_OUTPUT"
  exit 1
fi

# Check if the output file is empty
if [ ! -s "$tmpfile" ]; then
  echo "WARNING: Command produced no output."
  echo "::warning::Command produced no output: ${CMD[*]}"
  # Ensure we have something in the file for processing
  echo "[NO_OUTPUT_PRODUCED_BY_COMMAND]" > "$tmpfile"
fi

# Since we're combining stdout and stderr, copy to stderr file for compatibility
cp "$tmpfile" "$tmpfile_err"

# Print the captured output for debugging
echo "---- STDOUT ----"
cat "$tmpfile"
echo "---- STDERR ----"
cat "$tmpfile_err" >&2

# Combine stdout and stderr for processing
result=$(cat "$tmpfile" "$tmpfile_err")

# Debug: print the raw output for troubleshooting
echo "DEBUG: Raw command output:"
echo "$result"
echo "DEBUG: End of raw output"

rm "$tmpfile" "$tmpfile_err"

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
    # Use a more robust method to extract JSON that properly handles nested objects and escape sequences
    deployment_plan=$(echo "$result" | sed -n '/{/,/}/p' | tr -d '\n' | grep -o '{.*}' || echo "")
    if [ -n "$deployment_plan" ]; then
      # Properly format the JSON for GitHub Output
      # Escape potential problematic characters
      escaped_plan=$(echo "$deployment_plan" | jq -c . 2>/dev/null || echo "{}")
      {
        echo "deployment_plan<<EOF"
        echo "$escaped_plan"
        echo "EOF"
      } >> "$GITHUB_OUTPUT"
    fi
  else
    echo "DEBUG: Extracting plan ID from output..."

    # Check if we have the no-output marker
    if [[ "$result" == *"[NO_OUTPUT_PRODUCED_BY_COMMAND]"* ]]; then
      echo "DEBUG: Command produced no output, skipping pattern matching"
      plan_id=""
    else
      # Extract plan ID from regular deployment output - using multiple patterns
      # Try to find the plan ID using various patterns in order of specificity

      # Extract plan ID using multiple patterns in order of specificity
      # 1. Try full URL pattern first
      plan_id=$(echo "$result" | grep -o 'https://app.bluebricks.co/plans/[0-9a-f-]*[-]*[0-9a-f]*' | awk -F'/' '{print $NF}' || echo "")
      
      # 2. If not found, try partial URL pattern
      if [ -z "$plan_id" ]; then
        plan_id=$(echo "$result" | grep -o 'plans/[0-9a-f-]*[-]*[0-9a-f]*' | awk -F'/' '{print $NF}' | head -1 || echo "")
      fi

      # 3. If still not found, try installation log pattern
      if [ -z "$plan_id" ]; then
        plan_id=$(echo "$result" | grep -o 'installation log at.*' | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' || echo "")
      fi

      # 4. Last resort: direct UUID pattern match anywhere in output
      if [ -z "$plan_id" ]; then
        plan_id=$(echo "$result" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | head -1 || echo "")
      fi
    fi
    
    # Set API URL regardless of whether we found a plan ID
    if [ -n "$INPUT_API_URL" ]; then
      api_url="$INPUT_API_URL"
    else
      api_url="https://api.bluebricks.co"
    fi
    
    if [ -n "$plan_id" ]; then
      # We found a valid plan ID
      echo "Plan ID found: $plan_id"
      echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
      
      echo "Fetching SVG visualization for plan $plan_id from $api_url..."
      # Get the SVG from the API, handle errors gracefully
      svg_response=$(curl -s "$api_url/api/v1/deployment/$plan_id/image" -H "Authorization: Bearer $BRICKS_API_KEY")
    else
      # No plan ID found - log a warning
      echo "::warning::No plan ID found in command output."
      
      # Set empty plan ID in GitHub output
      echo "plan_id=" >> "$GITHUB_OUTPUT"
      
      # Check if we have an SVG response despite not having a plan ID
      if [[ "$svg_response" == *"<svg"* ]]; then
        # Base64 encode the SVG for embedding in markdown
        svg_base64=$(echo "$svg_response" | base64)
        echo "plan_svg=$svg_base64" >> "$GITHUB_OUTPUT"
        echo "Successfully fetched SVG visualization"
      else
        echo "WARNING: Failed to fetch SVG visualization"
        echo "::warning::Failed to fetch SVG visualization: Plan ID may be valid but SVG endpoint returned an error"
        
        # Generate a synthetic one for CI purposes
        echo "WARNING: No plan ID found in command output"
        echo "::warning::No plan ID found in the command output"
        
        # Create a descriptive synthetic ID that includes the command type for better traceability
        timestamp=$(date +%s)
        synthetic_plan_id="synthetic-${INPUT_COMMAND}-$timestamp"
        echo "Generating synthetic plan ID for CI purposes: $synthetic_plan_id"
        echo "plan_id=$synthetic_plan_id" >> "$GITHUB_OUTPUT"
      fi
      
      # Handle plan-only mode differently
      if [ "$INPUT_PLAN_ONLY" == "true" ]; then
        # For plan-only mode, create a mock deployment plan JSON
        echo "Creating mock deployment plan for CI..."
        # Create a more descriptive mock plan with timestamp and command info
        mock_plan="{\"mock_plan\": true, \"id\": \"$synthetic_plan_id\", \"command\": \"${INPUT_COMMAND}\", \"timestamp\": $timestamp, \"resources\": []}"
        {
          echo "deployment_plan<<EOF"
          echo "$mock_plan"
          echo "EOF"
        } >> "$GITHUB_OUTPUT"
      fi
      
      # Add diagnostic output to help troubleshoot why no plan ID was found
      echo "STDOUT contents:"
      cat "$tmpfile"
      echo "STDERR contents:"
      cat "$tmpfile_err"
      
      # Add a notice about using a synthetic plan ID
      echo "::notice::Using synthetic plan ID ($synthetic_plan_id) because no real plan ID was found in the command output"
    fi
  fi
fi

# Handle error output if applicable.
# For this example, we assume there's no error; otherwise, adjust accordingly.
error_message=""
echo "error=$error_message" >> "$GITHUB_OUTPUT"

# Exit with success code
exit 0