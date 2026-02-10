#!/bin/bash

# ------------------------------------------------------
# Logic: Parse Params and Run Scan
# ------------------------------------------------------

# Function to extract and export repo-name parameter
process_repo_name() {
  local params="$1"
  
  if [[ "${params}" =~ --repo-name=([^[:space:]]+) ]]; then
    echo "⚠️  Warning: The --repo-name parameter is deprecated. Please use the 'repo_name' input instead." >&2
    local repo_name_value="${BASH_REMATCH[1]}"
    # Remove quotes if present
    repo_name_value="${repo_name_value//\"/}"
    export CX_REPO_NAME="${repo_name_value}"
    # Remove --repo-name from params to avoid duplication
    params=$(echo "${params}" | sed -E 's/--repo-name=[^[:space:]]+//')
    params=$(echo "${params}" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    # Add log for debugging
    echo "⚠️  Exported CX_REPO_NAME=${CX_REPO_NAME}" >&2
  fi
  
  echo "${params}"
}

# Function to convert --severity parameter to --threshold format
# This is a simplified mapping and may need to be adjusted based on specific requirements
# if --severity=High -> --threshold "sast-medium=0;sast-low=0"
# if --severity=High,Medium -> --threshold "sast-low=0"
# if --severity=Medium -> --threshold "sast-high=0;sast-low=0"
# if --severity=Medium,Low -> --threshold "sast-high=0"
process_severity() {
  local params="$1"
  
  if [[ "${params}" =~ --severity=([^[:space:]]+) ]]; then
    # Users are recommended to use the new --threshold parameter directly
    echo "⚠️  Warning: The --severity parameter is deprecated. Please use --threshold which provides more granular control instead." >&2
    local severity_value="${BASH_REMATCH[1]}"
    # Remove quotes if present
    severity_value="${severity_value//\"/}"
    
    # Determine threshold based on severity value
    local threshold=""
    case "${severity_value}" in
      "High")
        threshold="--threshold sast-medium=0;sast-low=0"
        ;;
      "High,Medium"|"High, Medium")
        threshold="--threshold sast-low=0"
        ;;
      "Medium")
        threshold="--threshold sast-high=0;sast-low=0"
        ;;
      "Medium,Low"|"Medium, Low")
        threshold="--threshold sast-high=0"
        ;;
    esac
    
    # Replace --severity with --threshold in SCAN_PARAMS
    if [ -n "${threshold}" ]; then
      params=$(echo "${params}" | sed -E 's/--severity=[^[:space:]]+//')
      params="${params} ${threshold}"
      params=$(echo "${params}" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
      # Add log for debugging
      echo "⚠️  Converted --severity=${severity_value} to ${threshold}" >&2
    fi
  fi
  
  echo "${params}"
}

# Function to convert --merge-id to custom tag format
process_merge_id() {
  local params="$1"
  
  if [[ "${params}" =~ --merge-id=([^[:space:]]+) ]]; then
    local merge_id_value="${BASH_REMATCH[1]}"
    # Remove quotes if present
    merge_id_value="${merge_id_value//\"/}"
    # Replace --merge-id with --tag=merge:<value>
    params=$(echo "${params}" | sed -E 's/--merge-id=[^[:space:]]+/--tag=merge-id:'"${merge_id_value}"'/')
    # Add log for debugging
    echo "⚠️  Converted --merge-id=${merge_id_value} to --tag=merge-id:${merge_id_value}" >&2
  fi
  
  echo "${params}"
}

# Function to remove deprecated checkmarx.* parameters
remove_checkmarx_params() {
  local params="$1"
  
  if [[ "${params}" =~ checkmarx\. ]]; then
    echo "⚠️  Warning: Parameters starting with 'checkmarx.' are deprecated in Checkmarx One (AST CLI) and will be removed." >&2
    params=$(echo "${params}" | sed -E 's/--checkmarx\.[^[:space:]]*//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    # Add log for debugging
    echo "⚠️  Removed deprecated checkmarx.* parameters." >&2
  fi
  
  echo "${params}"
}

### MAIN SCRIPT EXECUTION STARTS HERE

# Parse global params (applied to all commands)
if [ -n "${GLOBAL_PARAMS}" ]; then
  eval "global_arr=(${GLOBAL_PARAMS})"
else
  global_arr=()
fi

# Parse scan-specific params
if [ -n "${SCAN_PARAMS}" ]; then
  # # Remove --namespace if present (no direct equivalent in AST CLI)
  # SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/--namespace=[^[:space:]]*//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

  # # Export --repo-name to environment variable for Checkmarx One (AST CLI) to pick up
  # SCAN_PARAMS=$(process_repo_name "${SCAN_PARAMS}")

  # # Convert cx-flow style parameters to Checkmarx One (AST CLI) format
  # SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/--cx-flow\.filterSeverity/--filter severity/g')
  
  # # Remove --cx-flow.filterCategory if present (no direct equivalent in AST CLI)
  # SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/--cx-flow\.filterCategory[^ ]*//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

  # Convert --merge-id to custom tag format
  SCAN_PARAMS=$(process_merge_id "${SCAN_PARAMS}")
  
  # # Convert --severity parameter to --threshold format
  # SCAN_PARAMS=$(process_severity "${SCAN_PARAMS}")

  # Remove deprecated checkmarx.* parameters
  SCAN_PARAMS=$(remove_checkmarx_params "${SCAN_PARAMS}")
  
  eval "scan_arr=(${SCAN_PARAMS})"
else
  scan_arr=()
fi

# Backward compatibility: Support ADDITIONAL_PARAMS
if [ -n "${ADDITIONAL_PARAMS}" ] && [ -z "${SCAN_PARAMS}" ]; then
  echo "⚠️  ADDITIONAL_PARAMS is deprecated. Please use SCAN_PARAMS instead." >&2
  eval "scan_arr=(${ADDITIONAL_PARAMS})"
fi

# Combine global + scan-specific params
combined_scan_params=("${global_arr[@]}" "${scan_arr[@]}")

# Add log for debugging
echo "⚠️  Final combined scan parameters: ${combined_scan_params[*]}" >&2

# Prepare customized scan options
customized_scan_params=()

# Prepare Scan Type(s) if provided
if [ -n "${SCANNER}" ]; then
  customized_scan_params+=("--scan-types" "${SCANNER}")
fi

# Prepare Zip Include filter if provided
if [ -n "${ZIP_INCLUDE}" ]; then
  customized_scan_params+=("--file-include" "${ZIP_INCLUDE}")
fi

# Prepare Zip Exclude filter if provided
# Convert the comma-separated list into the required format
# e.g., pattern1,pattern2 -> !pattern1,!pattern2
# or "*.log,!*.tmp,!*.cache" -> "!*.log,!*.tmp,!*.cache"
if [ -n "${ZIP_EXCLUDE}" ]; then
  modified_exclude="${ZIP_EXCLUDE//,/,!}"
  modified_exclude="!${modified_exclude}"
  customized_scan_params+=("--file-filter" "${modified_exclude}")
fi

# Prepare Application ID if provided
if [ -n "${APP_ID}" ]; then
  customized_scan_params+=("--tag=app:${APP_ID}")
fi

# Prepare Bug Tracker Format if provided
if [ -n "${BUG_TRACKER_FORMAT}" ]; then
  customized_scan_params+=("--report-format" "${BUG_TRACKER_FORMAT}")
fi

# Execute Scan
/app/bin/cx scan create --project-name "${PROJECT_NAME}" -s "${SOURCE_DIR}" --branch "${BRANCH#refs/heads/}" --scan-info-format json --agent "Github Action" "${customized_scan_params[@]}" "${combined_scan_params[@]}" | tee -i "$output_file"
exitCode=${PIPESTATUS[0]}

# Extract Scan ID
scanId=(`grep -E '"(ID)":"((\\"|[^"])*)"' "$output_file" | cut -d',' -f1 | cut -d':' -f2 | tr -d '"'`)

# Output for GitHub Actions
echo "cxcli=$(cat "$output_file" | tr -d '\r\n')" >> $GITHUB_OUTPUT
