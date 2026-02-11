#!/bin/bash

# ------------------------------------------------------
# Logic: Parse Params and Run Scan
# ------------------------------------------------------

# ------------------------------------------------------
# FUNCTION DEFINITIONS
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
  fi
  
  echo "${params}"
}

# Function to convert cx-flow parameters with --severity to --filter format
# if --cx-flow.filterSeverity --cx-flow.filterCategory --severity=High -> --filter severity=High
# Modifies SCAN_PARAMS directly
process_cx_flow_severity() {
  if [[ "${SCAN_PARAMS}" =~ --severity=([^[:space:]]+) ]]; then
    local severity_value="${BASH_REMATCH[1]}"
    # Remove quotes if present
    severity_value="${severity_value//\"/}"
    
    # Remove --severity parameter
    SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed -E 's/--severity=[^[:space:]]+//')
    # Remove --cx-flow.filterSeverity if present
    SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/--cx-flow\.filterSeverity//g')
    # Remove --cx-flow.filterCategory if present
    SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/--cx-flow\.filterCategory[^ ]*//g')
    
    # Add --filter severity=<value>
    SCAN_PARAMS="${SCAN_PARAMS} --filter severity=${severity_value}"
    SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
  fi
}

# Function to extract --merge-id value and remove it from params
# Modifies SCAN_PARAMS directly and sets global variable MERGE_ID_VALUE
process_merge_id() {
  MERGE_ID_VALUE=""
  
  if [[ "${SCAN_PARAMS}" =~ --merge-id=([^[:space:]]+) ]]; then
    MERGE_ID_VALUE="${BASH_REMATCH[1]}"
    # Remove quotes if present
    MERGE_ID_VALUE="${MERGE_ID_VALUE//\"/}"
    # Remove --merge-id from params
    SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed -E 's/--merge-id=[^[:space:]]+//')
    SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
  fi
}

# Function to remove deprecated checkmarx.* parameters
remove_checkmarx_params() {
  local params="$1"
  
  if [[ "${params}" =~ checkmarx\. ]]; then
    echo "⚠️  Warning: Parameters starting with 'checkmarx.' are deprecated in Checkmarx One (AST CLI) and will be removed." >&2
    params=$(echo "${params}" | sed -E 's/--checkmarx\.[^[:space:]]*//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
  fi
  
  echo "${params}"
}

# ------------------------------------------------------
# MAIN SCRIPT EXECUTION STARTS HERE
# ------------------------------------------------------

# Parse global params (applied to all commands)
if [ -n "${GLOBAL_PARAMS}" ]; then
  eval "global_arr=(${GLOBAL_PARAMS})"
else
  global_arr=()
fi

# Parse scan-specific params
if [ -n "${SCAN_PARAMS}" ]; then
  # Remove --namespace if present (no direct equivalent in AST CLI)
  SCAN_PARAMS=$(echo "${SCAN_PARAMS}" | sed 's/--namespace=[^[:space:]]*//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

  # Remove deprecated checkmarx.* parameters
  SCAN_PARAMS=$(remove_checkmarx_params "${SCAN_PARAMS}")

  # Export --repo-name to environment variable for Checkmarx One (AST CLI) to pick up
  SCAN_PARAMS=$(process_repo_name "${SCAN_PARAMS}")

  # Extract --merge-id and remove it from SCAN_PARAMS
  process_merge_id
  
  # Convert cx-flow style parameters with --severity to --filter severity=<value>
  process_cx_flow_severity

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

# Collect all tags into tag_list
tag_list=()

# Add merge-id tag if present
if [ -n "${MERGE_ID_VALUE}" ]; then
  tag_list+=("merge-id:${MERGE_ID_VALUE}")
fi

# Add Application ID tag if provided
if [ -n "${APP_ID}" ]; then
  tag_list+=("app:${APP_ID}")
fi

# Add Team Name tag if provided
if [ -n "${TEAM_NAME}" ]; then
  tag_list+=("team:${TEAM_NAME}")
fi

# Combine all tags into final --tags parameter if there are any tags
if [ ${#tag_list[@]} -gt 0 ]; then
  # Join array elements with comma
  tags_value=$(IFS=,; echo "${tag_list[*]}")
  customized_scan_params+=("--tags" "${tags_value}")
fi

# Prepare Bug Tracker Format if provided
if [ -n "${BUG_TRACKER_FORMAT}" ]; then
  customized_scan_params+=("--report-format" "${BUG_TRACKER_FORMAT}")
fi

if [ "${INCREMENTAL_SCAN}" = "true" ] || [ "${INCREMENTAL_SCAN}" = "True" ]; then
  customized_scan_params+=("--sast-incremental")
fi

# Prepare Threshold if provided
if [ -n "${THRESHOLD}" ]; then
  customized_scan_params+=("--threshold" "${THRESHOLD}")
else
  # Set minimum threshold if BREAK_BUILD is true
  if [ "${BREAK_BUILD}" = "true" ] || [ "${BREAK_BUILD}" = "True" ]; then
    customized_scan_params+=("--threshold" "\"sast-high:1;sast-medium:1;sast-low:1\"")
  fi
fi

# Enable debug mode if specified
if [ "${DEBUG}" = "true" ] || [ "${DEBUG}" = "True" ]; then
  customized_scan_params+=("--debug")
fi

# Add debug logs
echo "Executing scan with the following parameters:"
echo "  Project Name: ${PROJECT_NAME}"
echo "  Source Directory: ${SOURCE_DIR}"
echo "  Branch: ${BRANCH}"
echo "  Customized Scan Params: ${customized_scan_params[@]}"
echo "  Combined Scan Params: ${combined_scan_params[@]}"

# Execute Scan
/app/bin/cx scan create --project-name "${PROJECT_NAME}" -s "${SOURCE_DIR}" --branch "${BRANCH#refs/heads/}" --scan-info-format json --agent "Github Action" "${customized_scan_params[@]}" "${combined_scan_params[@]}" | tee -i "$output_file"
exitCode=${PIPESTATUS[0]}

# Extract Scan ID
scanId=(`grep -E '"(ID)":"((\\"|[^"])*)"' "$output_file" | cut -d',' -f1 | cut -d':' -f2 | tr -d '"'`)

# Output for GitHub Actions
echo "cxcli=$(cat "$output_file" | tr -d '\r\n')" >> $GITHUB_OUTPUT
