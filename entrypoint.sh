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
    if [ "$INPUT_PLAN_ONLY" == "true" ]; then
      # Extract deployment plan JSON from the output
      deployment_plan=$(echo "$result" | sed -n '/{/,/}/p' | tr -d '\n' | grep -o '{.*}' || echo "")
      if [ -n "$deployment_plan" ]; then
        # Properly format the JSON for GitHub Output
        escaped_plan=$(echo "$deployment_plan" | jq -c . 2>/dev/null || echo "{}")
        {
          echo "deployment_plan<<EOF"
          echo "$escaped_plan"
          echo "EOF"
        } >> "$GITHUB_OUTPUT"
      else
        echo "deployment_plan={}" >> "$GITHUB_OUTPUT"
      fi
    else
      # Extract plan ID and URL using a simple function to avoid repetition
      extract_plan_info() {
        # Debug: Print a more comprehensive view of the result to see the actual output format
        echo "DEBUG: Command output snippet (first 1000 chars):"
        echo "$result" | head -c 1000
        
        # Also print any lines containing 'plan', 'uuid', or 'installation log' for better debugging
        echo "
DEBUG: Lines containing key patterns:"
        echo "$result" | grep -i -E 'plan|uuid|installation log|deploy' | head -10 || echo "No matching lines found"
        
        # Extract the full URL if present - try multiple patterns
        # First try the standard URL pattern for both app.bricks-dev.com and app.bluebricks.co
        plan_url=$(echo "$result" | grep -o 'https://app[^[:space:]]*/plans/[0-9a-f-]*' | head -1 || echo "")
        
        # If that fails, try looking for any URL with 'installation log at'
        if [ -z "$plan_url" ]; then
          installation_log_url=$(echo "$result" | grep -o 'installation log at [^[:space:]]*' | sed 's/installation log at //' | head -1 || echo "")
          if [ -n "$installation_log_url" ]; then
            plan_url="$installation_log_url"
            echo "Found plan URL from 'installation log at' pattern: $plan_url"
          fi
        fi
        
        # Extract just the UUID using multiple patterns in order of specificity
        # 1. From the URL if we found one
        if [ -n "$plan_url" ]; then
          plan_id=$(echo "$plan_url" | awk -F'/' '{print $NF}')
          echo "Found plan ID from URL: $plan_id"
        else
          # 2. Try multiple installation log patterns with increasingly flexible matching
          # First try the exact pattern with 'installation log at'
          plan_id=$(echo "$result" | grep -o 'installation log at [^[:space:]]*' | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' || echo "")
          
          # If that fails, try looking for any UUID pattern in the output
          if [ -z "$plan_id" ]; then
            plan_id=$(echo "$result" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | head -1 || echo "")
            if [ -n "$plan_id" ]; then
              echo "Found plan ID by searching for UUID pattern: $plan_id"
            fi
          fi
          
          if [ -n "$plan_id" ]; then
            echo "Found plan ID from installation log: $plan_id"
          else
            # 3. Try partial URL pattern with more flexible matching
            plan_id=$(echo "$result" | grep -o 'plans/[0-9a-f-]*[-]*[0-9a-f]*' | awk -F'/' '{print $NF}' | head -1 || echo "")
            
            if [ -n "$plan_id" ]; then
              echo "Found plan ID from partial URL: $plan_id"
            else
              # 4. Try looking for UUID in specific contexts
              plan_id=$(echo "$result" | grep -i -E '(plan|deployment|uuid)[^a-zA-Z0-9]*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})' | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | head -1 || echo "")
              
              if [ -n "$plan_id" ]; then
                echo "Found plan ID from contextual UUID pattern: $plan_id"
              else
                # 5. Last resort: direct UUID pattern match anywhere in output
                plan_id=$(echo "$result" | grep -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || echo "")
              
                if [ -n "$plan_id" ]; then
                  # Extract just the UUID from any surrounding text
                  plan_id=$(echo "$plan_id" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}')
                  echo "Found plan ID from direct UUID match: $plan_id"
                fi
            fi
          fi
          
          # If we found a UUID but not a URL, construct a default URL
          if [ -n "$plan_id" ] && [ -z "$plan_url" ]; then
            # Determine the base URL from API URL or use default
            if [ -n "$INPUT_API_URL" ]; then
              # Convert api.domain to app.domain
              base_url=$(echo "$INPUT_API_URL" | sed 's/api\./app./g')
              plan_url="$base_url/plans/$plan_id"
            else
              plan_url="https://app.bluebricks.co/plans/$plan_id"
            fi
          fi
        fi
      }
      
      # Call the function to extract plan info
      extract_plan_info
      
      # Set API URL for further operations
      if [ -n "$INPUT_API_URL" ]; then
        api_url="$INPUT_API_URL"
      else
        api_url="https://api.bluebricks.co"
      fi
      
      if [ -n "$plan_id" ]; then
        # We found a valid plan ID
        echo "Plan ID found: $plan_id"
        echo "plan_id=$plan_id" >> "$GITHUB_OUTPUT"
        
        # Set the plan URL as output
        echo "plan_url=$plan_url" >> "$GITHUB_OUTPUT"
        
        # Create a summary for the plan
        {
          echo "plan_summary<<EOF"
          echo "Deployment plan created: $plan_url"
          echo "Plan ID: $plan_id"
          echo "EOF"
        } >> "$GITHUB_OUTPUT"
        
        echo "Fetching SVG visualization for plan $plan_id from $api_url..."
        # Get the SVG from the API, handle errors gracefully
        svg_response=$(curl -s "$api_url/api/v1/deployment/$plan_id/image" -H "Authorization: Bearer $BRICKS_API_KEY")
        
        # Check if we got a valid SVG response
        if [[ "$svg_response" == *"<svg"* ]]; then
          # Base64 encode the SVG for embedding in markdown
          svg_base64=$(echo "$svg_response" | base64)
          echo "plan_svg=$svg_base64" >> "$GITHUB_OUTPUT"
          echo "Successfully fetched SVG visualization"
        else
          echo "::warning::Failed to fetch SVG visualization: API returned invalid response"
        fi
      else
        # No plan ID found - log a warning
        echo "::warning::No plan ID found in command output."
        echo "plan_id=" >> "$GITHUB_OUTPUT"
        echo "plan_url=" >> "$GITHUB_OUTPUT"
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
