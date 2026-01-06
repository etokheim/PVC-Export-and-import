#!/bin/bash

###############################################################################
# PVC Import Script for Kubernetes
# 
# Imports data from folders, tar, or tar.gz archives into Kubernetes 
# PersistentVolumeClaims. Supports multiple sources and can create new PVCs.
#
# Usage: ./pv-import.sh [-v] <source> [source2 ...]
#
# Author: Auto-generated script
# Version: 1.0
###############################################################################

# Exit on error, but allow functions to handle errors gracefully
set -e
# Enable nounset for better variable checking
set -u

# Script version
SCRIPT_VERSION="1.0"

# Get script directory for log file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}" .sh)

# Global variables
SUCCESSFUL_IMPORTS=()
FAILED_IMPORTS=()
VERBOSE=false
KUBECTL_CMD=""  # Will be set by detect_kubectl()
INTERRUPTED=false  # Track if script was interrupted
LOG_FILE=""  # Will be set when logging is initialized

# Log directories
LOG_DIR="${SCRIPT_DIR}/logs"
POD_LOG_DIR="${SCRIPT_DIR}/logs/pod_logs"

# Import job tracking arrays (populated during user prompts)
declare -a IMPORT_SOURCES=()
declare -a IMPORT_PVC_NAMES=()
declare -a IMPORT_NAMESPACES=()
declare -a IMPORT_SOURCE_TYPES=()  # "folder", "tar", "tar.gz"
declare -a IMPORT_DATA_MODES=()    # "overwrite", "merge", "clear"
declare -a IMPORT_CREATE_PVC=()    # "true" or "false"
declare -a IMPORT_STORAGE_CLASSES=()
declare -a IMPORT_PVC_SIZES=()

# Initialize log file and directories
init_log_file() {
  local timestamp=$(date +"%Y%m%d-%H%M%S")
  
  # Create log directories
  mkdir -p "${LOG_DIR}" 2>/dev/null || {
    echo "⚠️  Warning: Cannot create log directory at ${LOG_DIR}, using script directory" >&2
    LOG_DIR="${SCRIPT_DIR}"
    POD_LOG_DIR="${SCRIPT_DIR}/pod_logs"
  }
  mkdir -p "${POD_LOG_DIR}" 2>/dev/null || {
    echo "⚠️  Warning: Cannot create pod log directory at ${POD_LOG_DIR}" >&2
    POD_LOG_DIR=""
  }
  
  LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}-${timestamp}.log"
  touch "${LOG_FILE}" || {
    echo "⚠️  Warning: Cannot create log file at ${LOG_FILE}, continuing without logging" >&2
    LOG_FILE=""
    return 1
  }
  # Write initial log entry
  {
    echo "=========================================="
    echo "PVC Import Script - Log Started"
    echo "=========================================="
    echo "Timestamp: $(date)"
    echo "Script: ${BASH_SOURCE[0]}"
    echo "PID: $$"
    echo "User: $(whoami)"
    echo "Log file: ${LOG_FILE}"
    echo "Pod logs: ${POD_LOG_DIR}"
    echo ""
  } >> "${LOG_FILE}" 2>/dev/null || true
  return 0
}

# Save pod logs before deletion
save_pod_logs() {
  local pod_name=$1
  local namespace=$2
  local pvc_name=${3:-"unknown"}
  
  if [ -z "${POD_LOG_DIR}" ] || [ -z "${pod_name}" ] || [ -z "${namespace}" ]; then
    return 0
  fi
  
  # Check if pod exists
  if ! ${KUBECTL_CMD} get pod "${pod_name}" -n "${namespace}" &>/dev/null; then
    log debug "Pod ${pod_name} not found, skipping log save"
    return 0
  fi
  
  local timestamp=$(date +"%Y%m%d-%H%M%S")
  local log_file="${POD_LOG_DIR}/${namespace}-${pvc_name}-${pod_name}-${timestamp}.log"
  
  log debug "Saving pod logs to ${log_file}"
  
  {
    echo "=========================================="
    echo "Pod Log Export"
    echo "=========================================="
    echo "Pod:       ${pod_name}"
    echo "Namespace: ${namespace}"
    echo "PVC:       ${pvc_name}"
    echo "Timestamp: $(date)"
    echo ""
    echo "=========================================="
    echo "Pod Status"
    echo "=========================================="
    ${KUBECTL_CMD} get pod "${pod_name}" -n "${namespace}" -o wide 2>&1 || echo "(Failed to get pod status)"
    echo ""
    echo "=========================================="
    echo "Pod Description"
    echo "=========================================="
    ${KUBECTL_CMD} describe pod "${pod_name}" -n "${namespace}" 2>&1 || echo "(Failed to describe pod)"
    echo ""
    echo "=========================================="
    echo "Pod Events"
    echo "=========================================="
    ${KUBECTL_CMD} get events -n "${namespace}" --field-selector "involvedObject.name=${pod_name}" --sort-by='.lastTimestamp' 2>&1 || echo "(No events found)"
    echo ""
    echo "=========================================="
    echo "Container Logs"
    echo "=========================================="
    ${KUBECTL_CMD} logs "${pod_name}" -n "${namespace}" --tail=1000 2>&1 || echo "(No logs available)"
    echo ""
    echo "=========================================="
    echo "End of Pod Log Export"
    echo "=========================================="
  } > "${log_file}" 2>&1
  
  log_output "📋 Pod logs saved to: ${log_file}"
}

# Logging function - writes to both console and log file
log() {
  local level=$1
  shift
  local message="$@"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local level_upper=$(echo "${level}" | tr '[:lower:]' '[:upper:]')
  local log_entry="[${timestamp}] [${level_upper}] ${message}"
  
  # Write to log file if initialized
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    echo "${log_entry}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
  
  # Write to console (respect verbose setting)
  if [ "${VERBOSE}" = "true" ] || [ "${level}" != "debug" ]; then
    echo "${message}"
  fi
}

# Function to log output that should go to both console and log (for important messages)
log_output() {
  local message="$@"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  
  # Write to log file if initialized
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    echo "[${timestamp}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
  
  # Always write to console
  echo "${message}"
}

# Function to log command output (captures both stdout and stderr)
log_command() {
  local command="$@"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  
  # Log the command being executed
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    echo "[${timestamp}] Executing: ${command}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
  
  # Execute command and capture output
  if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    eval "${command}" 2>&1 | tee -a "${LOG_FILE}" || return $?
  else
    eval "${command}" || return $?
  fi
}

# Spinner animation characters
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPINNER_IDX=0

# Get next spinner character
get_spinner() {
  local char="${SPINNER_CHARS:$SPINNER_IDX:1}"
  SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_CHARS} ))
  echo "$char"
}

# Format bytes to human readable
format_bytes() {
  local bytes=${1:-0}
  # Ensure it's a number
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    bytes=0
  fi
  if [ "$bytes" -ge 1073741824 ]; then
    awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
  elif [ "$bytes" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
  elif [ "$bytes" -ge 1024 ]; then
    awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
  else
    echo "${bytes} B"
  fi
}

# Format speed (bytes per second) to human readable
format_speed() {
  local bps=${1:-0}
  # Ensure it's a number
  if ! [[ "$bps" =~ ^[0-9]+$ ]]; then
    bps=0
  fi
  if [ "$bps" -ge 1073741824 ]; then
    awk "BEGIN {printf \"%.2f GB/s\", $bps/1073741824}"
  elif [ "$bps" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.2f MB/s\", $bps/1048576}"
  elif [ "$bps" -ge 1024 ]; then
    awk "BEGIN {printf \"%.2f KB/s\", $bps/1024}"
  else
    echo "${bps} B/s"
  fi
}

# Format seconds to human readable time
format_time() {
  local seconds=${1:-0}
  # Ensure it's a number
  if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    seconds=0
  fi
  if [ "$seconds" -ge 3600 ]; then
    printf "%dh %dm %ds" $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
  elif [ "$seconds" -ge 60 ]; then
    printf "%dm %ds" $((seconds/60)) $((seconds%60))
  else
    printf "%ds" "$seconds"
  fi
}

# Cleanup function for individual PVC import
cleanup_pvc() {
  local pod_name=$1
  local namespace=$2
  local import_pid=$3
  local temp_error_file=$4
  local pvc_name=${5:-"unknown"}
  
  if [ -n "${pod_name}" ] && [ -n "${namespace}" ]; then
    # Kill background import process if running
    if [ -n "${import_pid}" ] && kill -0 "${import_pid}" 2>/dev/null; then
      log debug "Killing background import process ${import_pid}"
      kill "${import_pid}" 2>/dev/null || true
      wait "${import_pid}" 2>/dev/null || true
    fi
    # Save pod logs before deletion
    save_pod_logs "${pod_name}" "${namespace}" "${pvc_name}"
    log debug "Deleting pod ${pod_name} in namespace ${namespace}"
    ${KUBECTL_CMD} delete pod "${pod_name}" -n "${namespace}" --ignore-not-found=true 2>/dev/null || true
  fi
  # Clean up temp error file if it exists
  if [ -n "${temp_error_file}" ] && [ -f "${temp_error_file}" ]; then
    rm -f "${temp_error_file}" 2>/dev/null || true
  fi
}

# Global cleanup function
cleanup() {
  # Only run cleanup once
  if [ "${CLEANUP_DONE:-false}" = "true" ]; then
    return
  fi
  CLEANUP_DONE=true
  
  # Mark as interrupted to stop processing remaining imports
  INTERRUPTED=true
  
  # Clean up any remaining pods from current import
  if [ -n "${CURRENT_POD_NAME:-}" ] && [ -n "${CURRENT_NAMESPACE:-}" ]; then
    echo ""
    echo "🛑 Interrupt received. Stopping all imports..."
    echo "🧹 Cleaning up current pod..."
    cleanup_pvc "${CURRENT_POD_NAME}" "${CURRENT_NAMESPACE}" "${CURRENT_IMPORT_PID:-}" "${CURRENT_TEMP_ERROR_FILE:-}" "${CURRENT_PVC_NAME:-}"
  fi
}

# Handle interrupt signals (Ctrl+C)
handle_interrupt() {
  echo ""
  echo "🛑 Interrupted by user"
  cleanup
  exit 130
}

# Set trap for cleanup on exit, and interrupt handler for INT/TERM
trap cleanup EXIT
trap handle_interrupt INT TERM

# Detect kubectl command (microk8s kubectl or regular kubectl)
detect_kubectl() {
  # Try microk8s kubectl first (preferred)
  if command -v microk8s &> /dev/null && microk8s kubectl version --client &>/dev/null; then
    KUBECTL_CMD="microk8s kubectl"
    log debug "Using microk8s kubectl"
    return 0
  fi
  
  # Fall back to standard kubectl
  if command -v kubectl &> /dev/null && kubectl version --client &>/dev/null; then
    KUBECTL_CMD="kubectl"
    log debug "Using standard kubectl"
    return 0
  fi
  
  # Neither found
  return 1
}

# Detect OS for package manager
detect_package_manager() {
  if command -v apt-get &> /dev/null; then
    echo "apt"
  elif command -v yum &> /dev/null; then
    echo "yum"
  elif command -v dnf &> /dev/null; then
    echo "dnf"
  elif command -v brew &> /dev/null; then
    echo "brew"
  elif command -v pacman &> /dev/null; then
    echo "pacman"
  else
    echo "unknown"
  fi
}

# Get install command for a dependency
get_install_command() {
  local dep=$1
  local pkg_mgr=$(detect_package_manager)
  
  case $pkg_mgr in
    apt)
      case $dep in
        pv) echo "sudo apt-get install -y pv" ;;
        jq) echo "sudo apt-get install -y jq" ;;
        *) echo "" ;;
      esac
      ;;
    yum)
      case $dep in
        pv) echo "sudo yum install -y pv" ;;
        jq) echo "sudo yum install -y jq" ;;
        *) echo "" ;;
      esac
      ;;
    dnf)
      case $dep in
        pv) echo "sudo dnf install -y pv" ;;
        jq) echo "sudo dnf install -y jq" ;;
        *) echo "" ;;
      esac
      ;;
    brew)
      case $dep in
        pv) echo "brew install pv" ;;
        jq) echo "brew install jq" ;;
        *) echo "" ;;
      esac
      ;;
    pacman)
      case $dep in
        pv) echo "sudo pacman -S --noconfirm pv" ;;
        jq) echo "sudo pacman -S --noconfirm jq" ;;
        *) echo "" ;;
      esac
      ;;
    *)
      echo ""
      ;;
  esac
}

# Global array for pending dependency installations
PENDING_INSTALLS=()

# Check dependencies and prompt for installation (but don't install yet)
check_and_prompt_dependencies() {
  local missing_deps=()
  
  # Check for pv (optional but recommended)
  if ! command -v pv &> /dev/null; then
    missing_deps+=("pv")
  fi
  
  # Check for jq (required)
  if ! command -v jq &> /dev/null; then
    missing_deps+=("jq")
  fi
  
  # Check for kubectl (required)
  if ! detect_kubectl; then
    missing_deps+=("kubectl")
  fi
  
  # If no missing dependencies, we're done
  if [ ${#missing_deps[@]} -eq 0 ]; then
    return 0
  fi
  
  # Prompt for each missing dependency
  if [ -t 0 ]; then
    echo ""
    echo "📦 Dependency Check"
    echo "=========================================="
    for dep in "${missing_deps[@]}"; do
      local install_cmd=""
      local is_required=false
      local description=""
      
      case $dep in
        pv)
          description="Pipe viewer - provides progress bars during import (recommended)"
          is_required=false
          install_cmd=$(get_install_command "pv")
          ;;
        jq)
          description="JSON processor - required for parsing Kubernetes output"
          is_required=true
          install_cmd=$(get_install_command "jq")
          ;;
        kubectl)
          description="Kubernetes command-line tool - required for accessing cluster"
          is_required=true
          install_cmd=""
          ;;
      esac
      
      echo ""
      if [ "$is_required" = "true" ]; then
        echo "❌ Missing required dependency: ${dep}"
      else
        echo "⚠️  Missing optional dependency: ${dep}"
      fi
      echo "   ${description}"
      
      if [ -n "${install_cmd}" ]; then
        echo "   Install command: ${install_cmd}"
        while true; do
          read -p "   Install ${dep} now? (Y/n): " INSTALL_CHOICE
          INSTALL_CHOICE=$(echo "${INSTALL_CHOICE}" | tr '[:upper:]' '[:lower:]')
          if [ -z "${INSTALL_CHOICE}" ] || [ "${INSTALL_CHOICE}" = "y" ] || [ "${INSTALL_CHOICE}" = "yes" ]; then
            PENDING_INSTALLS+=("${dep}|${install_cmd}")
            echo "   ✓ ${dep} will be installed before import starts"
            break
          elif [ "${INSTALL_CHOICE}" = "n" ] || [ "${INSTALL_CHOICE}" = "no" ]; then
            if [ "$is_required" = "true" ]; then
              echo ""
              echo "❌ Error: ${dep} is required. Cannot continue without it."
              echo "   Please install ${dep} manually and run the script again."
              exit 1
            else
              echo "   ⚠️  Continuing without ${dep} (progress indication will be limited)"
              break
            fi
          else
            echo "   Please enter 'y' or 'n'"
          fi
        done
      else
        # kubectl - special handling
        echo ""
        echo "   kubectl cannot be installed automatically."
        echo "   Please install kubectl manually:"
        echo "     Option 1 - MicroK8s:"
        echo "       See: https://microk8s.io/docs/getting-started"
        echo "     Option 2 - Standard kubectl:"
        echo "       See: https://kubernetes.io/docs/tasks/tools/"
        echo ""
        echo "   After installing kubectl, run this script again."
        exit 1
      fi
    done
  else
    # Non-interactive mode - check if any REQUIRED dependencies are missing
    local required_missing=false
    for dep in "${missing_deps[@]}"; do
      if [ "$dep" = "jq" ] || [ "$dep" = "kubectl" ]; then
        required_missing=true
        break
      fi
    done
    
    if [ "$required_missing" = "true" ]; then
      echo "❌ Error: Missing required dependencies in non-interactive mode"
      echo ""
      for dep in "${missing_deps[@]}"; do
        case $dep in
          pv)
            echo "   (Optional) Install pv: $(get_install_command "pv")"
            ;;
          jq)
            echo "   (Required) Install jq: $(get_install_command "jq")"
            ;;
          kubectl)
            echo "   (Required) Install kubectl manually (see Kubernetes documentation)"
            ;;
        esac
      done
      exit 1
    else
      # Only optional dependencies missing (pv)
      echo "ℹ️  Non-interactive mode: optional dependency 'pv' not installed"
      echo "   Progress indication will be limited. Install pv for better progress bars:"
      echo "   $(get_install_command "pv")"
      echo ""
    fi
  fi
}

# Install any pending dependencies (called after all prompts are done)
install_pending_dependencies() {
  if [ ${#PENDING_INSTALLS[@]} -eq 0 ]; then
    return 0
  fi
  
  echo ""
  echo "=========================================="
  echo "📥 Installing dependencies..."
  echo "=========================================="
  
  for install_req in "${PENDING_INSTALLS[@]}"; do
    local dep=$(echo "${install_req}" | cut -d'|' -f1)
    local cmd=$(echo "${install_req}" | cut -d'|' -f2-)
    
    echo ""
    echo "Installing ${dep}..."
    if eval "${cmd}"; then
      echo "✓ ${dep} installed successfully"
    else
      echo "❌ Failed to install ${dep}"
      echo "   Please install it manually and run the script again."
      exit 1
    fi
  done
  
  echo ""
  echo "✓ All dependencies installed successfully"
  echo ""
  
  # Re-check dependencies to verify installation
  if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq installation failed verification"
    exit 1
  fi
  
  if ! detect_kubectl; then
    echo "❌ Error: kubectl not found after installation check"
    exit 1
  fi
}

# Determine source type (folder, tar, tar.gz)
get_source_type() {
  local source=$1
  
  if [ -d "${source}" ]; then
    echo "folder"
  elif [ -f "${source}" ]; then
    # Check file extension
    if [[ "${source}" == *.tar.gz ]] || [[ "${source}" == *.tgz ]]; then
      echo "tar.gz"
    elif [[ "${source}" == *.tar ]]; then
      echo "tar"
    else
      # Try to detect by file content
      local file_type=$(file -b "${source}" 2>/dev/null || echo "")
      if [[ "${file_type}" == *"gzip"* ]]; then
        echo "tar.gz"
      elif [[ "${file_type}" == *"tar"* ]] || [[ "${file_type}" == *"POSIX tar"* ]]; then
        echo "tar"
      else
        echo "unknown"
      fi
    fi
  else
    echo "not_found"
  fi
}

# Get source size in bytes
get_source_size() {
  local source=$1
  local source_type=$2
  
  case "${source_type}" in
    folder)
      # Get actual folder size (handle both Linux and macOS)
      if command -v du &> /dev/null; then
        # Try GNU du first (Linux -b for bytes), fallback to BSD du (macOS -k for KB)
        local size_bytes
        size_bytes=$(du -sb "${source}" 2>/dev/null | awk '{print $1}')
        if [ -z "${size_bytes}" ] || [ "${size_bytes}" = "0" ]; then
          # Fallback for macOS: du -sk gives KB, multiply by 1024
          size_bytes=$(du -sk "${source}" 2>/dev/null | awk '{print $1 * 1024}')
        fi
        echo "${size_bytes:-0}"
      else
        echo "0"
      fi
      ;;
    tar)
      # For tar, approximate uncompressed size (slightly larger than file)
      local file_size=$(stat -f%z "${source}" 2>/dev/null || stat -c%s "${source}" 2>/dev/null || echo "0")
      echo "${file_size}"
      ;;
    tar.gz)
      # For gzipped tar, estimate uncompressed size (typically 3-10x larger)
      # Use gzip -l if available for better estimate
      local uncompressed_size=$(gzip -l "${source}" 2>/dev/null | tail -1 | awk '{print $2}' || echo "0")
      if [ "${uncompressed_size}" = "0" ] || [ -z "${uncompressed_size}" ]; then
        # Fallback: estimate as 5x compressed size
        local file_size=$(stat -f%z "${source}" 2>/dev/null || stat -c%s "${source}" 2>/dev/null || echo "0")
        echo "$((file_size * 5))"
      else
        echo "${uncompressed_size}"
      fi
      ;;
    *)
      echo "0"
      ;;
  esac
}

# Parse source filename to extract suggested namespace and PVC name
# Expected format: [namespace]-[pvc-name].tar.gz or [namespace]-[pvc-name].tar or folder name
parse_source_name() {
  local source=$1
  local source_type=$2
  
  # Get basename without extension
  local basename=$(basename "${source}")
  
  # Remove extensions
  basename="${basename%.tar.gz}"
  basename="${basename%.tgz}"
  basename="${basename%.tar}"
  
  # Try to split by first hyphen (namespace-pvcname format)
  # This is tricky because PVC names can contain hyphens
  # We'll try to match against existing namespaces
  
  echo "${basename}"
}

# Suggest PVC size based on source size (with some padding)
suggest_pvc_size() {
  local source_size_bytes=$1
  
  # Add 20% padding and round up to nearest Gi
  local padded_size=$((source_size_bytes * 120 / 100))
  local size_gi=$((padded_size / 1073741824))
  
  # Minimum 1Gi
  if [ "${size_gi}" -lt 1 ]; then
    size_gi=1
  fi
  
  # Round up to nice numbers
  if [ "${size_gi}" -le 5 ]; then
    size_gi=$((((size_gi + 0) / 1) * 1))  # Keep as is for small sizes
  elif [ "${size_gi}" -le 20 ]; then
    size_gi=$((((size_gi + 4) / 5) * 5))  # Round to nearest 5
  elif [ "${size_gi}" -le 100 ]; then
    size_gi=$((((size_gi + 9) / 10) * 10))  # Round to nearest 10
  else
    size_gi=$((((size_gi + 49) / 50) * 50))  # Round to nearest 50
  fi
  
  echo "${size_gi}Gi"
}

# Get list of available storage classes
get_storage_classes() {
  ${KUBECTL_CMD} get storageclasses -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort
}

# Get default storage class
get_default_storage_class() {
  ${KUBECTL_CMD} get storageclasses -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name' | \
    head -1
}

# Get list of available namespaces
get_namespaces() {
  ${KUBECTL_CMD} get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort
}

# Get list of PVCs in a namespace
get_pvcs_in_namespace() {
  local namespace=$1
  ${KUBECTL_CMD} get pvc -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort
}

# Check if PVC exists
pvc_exists() {
  local pvc_name=$1
  local namespace=$2
  
  ${KUBECTL_CMD} get pvc "${pvc_name}" -n "${namespace}" &>/dev/null
}

# Check if namespace exists
namespace_exists() {
  local namespace=$1
  
  ${KUBECTL_CMD} get namespace "${namespace}" &>/dev/null
}

# Get PVC info
get_pvc_info() {
  local pvc_name=$1
  local namespace=$2
  
  ${KUBECTL_CMD} get pvc "${pvc_name}" -n "${namespace}" -o json 2>/dev/null
}

# Check for pods using a PVC (for ReadWriteOnce conflict detection)
get_pods_using_pvc() {
  local pvc_name=$1
  local namespace=$2
  
  ${KUBECTL_CMD} get pods -n "${namespace}" -o json 2>/dev/null | \
    jq -r --arg pvc "${pvc_name}" \
    '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName==$pvc) | 
    "\(.metadata.name) [\(.status.phase)]"' 2>/dev/null || echo ""
}

# Validate tar archive
validate_tar_archive() {
  local source=$1
  local source_type=$2
  
  case "${source_type}" in
    tar)
      tar -tf "${source}" >/dev/null 2>&1
      return $?
      ;;
    tar.gz)
      tar -tzf "${source}" >/dev/null 2>&1
      return $?
      ;;
    *)
      return 0
      ;;
  esac
}

# Prompt user to select from a numbered list
# Returns the selected item
select_from_list() {
  local prompt=$1
  shift
  local items=("$@")
  local count=${#items[@]}
  
  if [ ${count} -eq 0 ]; then
    echo ""
    return 1
  fi
  
  echo ""
  echo "${prompt}"
  local i=1
  for item in "${items[@]}"; do
    echo "  ${i}) ${item}"
    i=$((i + 1))
  done
  echo ""
  
  while true; do
    read -p "  Enter number (1-${count}): " selection
    if [[ "${selection}" =~ ^[0-9]+$ ]] && [ "${selection}" -ge 1 ] && [ "${selection}" -le ${count} ]; then
      echo "${items[$((selection - 1))]}"
      return 0
    else
      echo "  Please enter a number between 1 and ${count}"
    fi
  done
}

# Prompt for PVC target configuration for a single source
prompt_for_target() {
  local source=$1
  local source_type=$2
  local source_size=$3
  local index=$4
  
  echo ""
  echo "=========================================="
  echo "📁 Source ${index}: ${source}"
  echo "=========================================="
  echo "  Type: ${source_type}"
  echo "  Size: $(format_bytes ${source_size})"
  echo ""
  
  # Parse source name for defaults
  local parsed_name=$(parse_source_name "${source}" "${source_type}")
  local suggested_namespace="default"
  local suggested_pvc_name="${parsed_name}"
  
  # Try to extract namespace from parsed name (format: namespace-pvcname)
  # Check if the part before first hyphen is an existing namespace
  local potential_ns=$(echo "${parsed_name}" | cut -d'-' -f1)
  if namespace_exists "${potential_ns}"; then
    suggested_namespace="${potential_ns}"
    # Remove namespace prefix from PVC name
    suggested_pvc_name=$(echo "${parsed_name}" | cut -d'-' -f2-)
  fi
  
  # Get available namespaces for selection
  local namespaces=($(get_namespaces))
  
  # Prompt for namespace
  echo "📍 Select target namespace:"
  echo "   Suggested: ${suggested_namespace}"
  echo ""
  echo "   Available namespaces:"
  local ns_idx=1
  for ns in "${namespaces[@]}"; do
    local marker=""
    if [ "${ns}" = "${suggested_namespace}" ]; then
      marker=" (suggested)"
    fi
    echo "     ${ns_idx}) ${ns}${marker}"
    ns_idx=$((ns_idx + 1))
  done
  echo ""
  
  local target_namespace=""
  while true; do
    read -p "   Enter namespace name or number [${suggested_namespace}]: " ns_input
    if [ -z "${ns_input}" ]; then
      target_namespace="${suggested_namespace}"
      break
    elif [[ "${ns_input}" =~ ^[0-9]+$ ]] && [ "${ns_input}" -ge 1 ] && [ "${ns_input}" -le ${#namespaces[@]} ]; then
      target_namespace="${namespaces[$((ns_input - 1))]}"
      break
    elif namespace_exists "${ns_input}"; then
      target_namespace="${ns_input}"
      break
    else
      echo "   ⚠️  Namespace '${ns_input}' does not exist."
      read -p "   Create namespace '${ns_input}'? (y/N): " create_ns
      if [[ "${create_ns}" =~ ^[Yy]$ ]]; then
        target_namespace="${ns_input}"
        # Mark that we need to create this namespace
        NAMESPACES_TO_CREATE+=("${ns_input}")
        break
      fi
    fi
  done
  echo "   ✓ Namespace: ${target_namespace}"
  echo ""
  
  # Prompt for PVC name
  local target_pvc=""
  local create_pvc="false"
  local storage_class=""
  local pvc_size=""
  
  # Get existing PVCs in the namespace
  local existing_pvcs=($(get_pvcs_in_namespace "${target_namespace}"))
  
  echo "📦 Enter target PVC name:"
  if [ ${#existing_pvcs[@]} -gt 0 ]; then
    echo "   Existing PVCs in '${target_namespace}':"
    local pvc_idx=1
    for pvc in "${existing_pvcs[@]}"; do
      local marker=""
      if [ "${pvc}" = "${suggested_pvc_name}" ]; then
        marker=" (suggested)"
      fi
      echo "     ${pvc_idx}) ${pvc}${marker}"
      pvc_idx=$((pvc_idx + 1))
    done
    echo ""
  else
    echo "   (No existing PVCs in namespace '${target_namespace}')"
    echo ""
  fi
  
  while true; do
    read -p "   PVC name or number [${suggested_pvc_name}]: " pvc_input
    if [ -z "${pvc_input}" ]; then
      target_pvc="${suggested_pvc_name}"
    elif [[ "${pvc_input}" =~ ^[0-9]+$ ]] && [ ${#existing_pvcs[@]} -gt 0 ] && [ "${pvc_input}" -ge 1 ] && [ "${pvc_input}" -le ${#existing_pvcs[@]} ]; then
      # User entered a number - select from existing PVCs
      target_pvc="${existing_pvcs[$((pvc_input - 1))]}"
    else
      target_pvc="${pvc_input}"
    fi
    
    # Validate PVC name (Kubernetes naming rules)
    if ! [[ "${target_pvc}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
      echo "   ❌ Invalid PVC name. Must be lowercase alphanumeric with hyphens, starting and ending with alphanumeric."
      continue
    fi
    
    # Check if PVC exists
    if pvc_exists "${target_pvc}" "${target_namespace}"; then
      echo "   ✓ PVC '${target_pvc}' exists in namespace '${target_namespace}'"
      create_pvc="false"
      
      # Get PVC info
      local pvc_info=$(get_pvc_info "${target_pvc}" "${target_namespace}")
      local pvc_status=$(echo "${pvc_info}" | jq -r '.status.phase // "unknown"')
      local pvc_capacity=$(echo "${pvc_info}" | jq -r '.spec.resources.requests.storage // "unknown"')
      local pvc_access_mode=$(echo "${pvc_info}" | jq -r '.spec.accessModes[0] // "unknown"')
      
      echo "     Status: ${pvc_status}"
      echo "     Capacity: ${pvc_capacity}"
      echo "     Access Mode: ${pvc_access_mode}"
      break
    else
      echo "   ⚠️  PVC '${target_pvc}' does not exist in namespace '${target_namespace}'"
      read -p "   Create new PVC? (Y/n): " create_choice
      if [[ -z "${create_choice}" ]] || [[ "${create_choice}" =~ ^[Yy]$ ]]; then
        create_pvc="true"
        
        # Get storage classes
        local storage_classes=($(get_storage_classes))
        local default_sc=$(get_default_storage_class)
        
        if [ ${#storage_classes[@]} -eq 0 ]; then
          echo "   ❌ No storage classes available in the cluster"
          echo "   Please create a storage class first or use an existing PVC"
          continue
        fi
        
        # Prompt for storage class
        echo ""
        echo "   📀 Select storage class:"
        local sc_idx=1
        for sc in "${storage_classes[@]}"; do
          local marker=""
          if [ "${sc}" = "${default_sc}" ]; then
            marker=" (default)"
          fi
          echo "     ${sc_idx}) ${sc}${marker}"
          sc_idx=$((sc_idx + 1))
        done
        echo ""
        
        while true; do
          local sc_default="${default_sc:-${storage_classes[0]}}"
          read -p "   Storage class [${sc_default}]: " sc_input
          if [ -z "${sc_input}" ]; then
            storage_class="${sc_default}"
            break
          elif [[ "${sc_input}" =~ ^[0-9]+$ ]] && [ "${sc_input}" -ge 1 ] && [ "${sc_input}" -le ${#storage_classes[@]} ]; then
            storage_class="${storage_classes[$((sc_input - 1))]}"
            break
          else
            # Check if it's a valid storage class name
            local found=false
            for sc in "${storage_classes[@]}"; do
              if [ "${sc}" = "${sc_input}" ]; then
                storage_class="${sc_input}"
                found=true
                break
              fi
            done
            if [ "${found}" = "true" ]; then
              break
            else
              echo "   Please enter a valid storage class name or number"
            fi
          fi
        done
        echo "   ✓ Storage class: ${storage_class}"
        
        # Prompt for PVC size
        local suggested_size=$(suggest_pvc_size ${source_size})
        echo ""
        read -p "   PVC size [${suggested_size}]: " size_input
        if [ -z "${size_input}" ]; then
          pvc_size="${suggested_size}"
        else
          pvc_size="${size_input}"
        fi
        echo "   ✓ PVC size: ${pvc_size}"
        
        break
      else
        echo "   Please enter a different PVC name"
      fi
    fi
  done
  
  echo ""
  
  # Store the configuration
  IMPORT_SOURCES+=("${source}")
  IMPORT_PVC_NAMES+=("${target_pvc}")
  IMPORT_NAMESPACES+=("${target_namespace}")
  IMPORT_SOURCE_TYPES+=("${source_type}")
  IMPORT_CREATE_PVC+=("${create_pvc}")
  IMPORT_STORAGE_CLASSES+=("${storage_class}")
  IMPORT_PVC_SIZES+=("${pvc_size}")
}

# Prompt for data handling mode (overwrite, merge, clear)
prompt_data_handling() {
  local index=$1
  local pvc_name="${IMPORT_PVC_NAMES[$index]}"
  local namespace="${IMPORT_NAMESPACES[$index]}"
  local create_pvc="${IMPORT_CREATE_PVC[$index]}"
  
  if [ "${create_pvc}" = "true" ]; then
    # New PVC, no need to ask about existing data
    IMPORT_DATA_MODES+=("clear")
    return 0
  fi
  
  echo ""
  echo "📋 Data handling for ${namespace}/${pvc_name}:"
  echo "   1) Merge - Add files without removing existing data"
  echo "   2) Clear - Remove all existing data before import"
  echo ""
  
  while true; do
    read -p "   Select option [1]: " mode_input
    case "${mode_input}" in
      ""| 1)
        IMPORT_DATA_MODES+=("merge")
        echo "   ✓ Mode: Merge (preserve existing data)"
        break
        ;;
      2)
        IMPORT_DATA_MODES+=("clear")
        echo "   ✓ Mode: Clear (remove existing data first)"
        break
        ;;
      *)
        echo "   Please enter 1 or 2"
        ;;
    esac
  done
}

# Check for ReadWriteOnce conflicts
check_rwo_conflicts() {
  local index=$1
  local pvc_name="${IMPORT_PVC_NAMES[$index]}"
  local namespace="${IMPORT_NAMESPACES[$index]}"
  local create_pvc="${IMPORT_CREATE_PVC[$index]}"
  
  if [ "${create_pvc}" = "true" ]; then
    # New PVC, no conflicts possible
    return 0
  fi
  
  # Get PVC info
  local pvc_info=$(get_pvc_info "${pvc_name}" "${namespace}")
  local access_mode=$(echo "${pvc_info}" | jq -r '.spec.accessModes[0] // "unknown"')
  
  if [ "${access_mode}" != "ReadWriteOnce" ] && [ "${access_mode}" != "RWO" ]; then
    return 0
  fi
  
  # Check for pods using this PVC
  local pods_using_pvc=$(get_pods_using_pvc "${pvc_name}" "${namespace}")
  
  if [ -n "${pods_using_pvc}" ]; then
    echo ""
    echo "⚠️  ReadWriteOnce Conflict Detected!"
    echo "   PVC '${pvc_name}' is mounted by:"
    echo "${pods_using_pvc}" | sed 's/^/     /'
    echo ""
    echo "   The import pod may fail to start while these pods are running."
    echo "   Consider stopping these pods temporarily."
    echo ""
    
    read -p "   Continue anyway? (y/N): " continue_choice
    if [[ ! "${continue_choice}" =~ ^[Yy]$ ]]; then
      return 1
    fi
  fi
  
  return 0
}

# Validate all sources before import
validate_all_sources() {
  echo ""
  echo "=========================================="
  echo "🔍 Validating sources..."
  echo "=========================================="
  
  local all_valid=true
  local i=0
  
  for source in "${IMPORT_SOURCES[@]}"; do
    local source_type="${IMPORT_SOURCE_TYPES[$i]}"
    
    echo ""
    echo "  Validating: ${source}"
    
    case "${source_type}" in
      folder)
        if [ -d "${source}" ] && [ -r "${source}" ]; then
          echo "    ✓ Folder is readable"
        else
          echo "    ❌ Folder is not readable"
          all_valid=false
        fi
        ;;
      tar|tar.gz)
        echo -n "    Checking archive integrity... "
        if validate_tar_archive "${source}" "${source_type}"; then
          echo "✓"
        else
          echo "❌"
          echo "    ❌ Archive is corrupted or invalid"
          all_valid=false
        fi
        ;;
    esac
    
    i=$((i + 1))
  done
  
  if [ "${all_valid}" = "true" ]; then
    echo ""
    echo "✓ All sources validated successfully"
    return 0
  else
    echo ""
    echo "❌ Some sources failed validation"
    return 1
  fi
}

# Create PVC if needed
create_pvc_if_needed() {
  local index=$1
  local pvc_name="${IMPORT_PVC_NAMES[$index]}"
  local namespace="${IMPORT_NAMESPACES[$index]}"
  local create_pvc="${IMPORT_CREATE_PVC[$index]}"
  local storage_class="${IMPORT_STORAGE_CLASSES[$index]}"
  local pvc_size="${IMPORT_PVC_SIZES[$index]}"
  
  if [ "${create_pvc}" != "true" ]; then
    return 0
  fi
  
  log_output "📦 Creating PVC '${pvc_name}' in namespace '${namespace}'..."
  log_output "   Storage class: ${storage_class}"
  log_output "   Size: ${pvc_size}"
  
  # Create PVC YAML
  local pvc_yaml=$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${namespace}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: ${pvc_size}
EOF
)
  
  echo "${pvc_yaml}" | ${KUBECTL_CMD} apply -f - 2>&1 | while read line; do log_output "   ${line}"; done
  
  # Wait for PVC to be bound
  log_output "   Waiting for PVC to be bound..."
  local timeout=60
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local status=$(${KUBECTL_CMD} get pvc "${pvc_name}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${status}" = "Bound" ]; then
      log_output "   ✓ PVC is bound"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    printf "\r   Waiting... (%d/%d seconds) [Status: %s]    " $elapsed $timeout "${status:-Pending}"
  done
  
  printf "\r%80s\r" " "
  log_output "   ⚠️  PVC not bound after ${timeout} seconds (this may be normal for some storage classes)"
  return 0
}

# Create namespace if needed
create_namespace_if_needed() {
  local namespace=$1
  
  if namespace_exists "${namespace}"; then
    return 0
  fi
  
  log_output "📁 Creating namespace '${namespace}'..."
  ${KUBECTL_CMD} create namespace "${namespace}" 2>&1 | while read line; do log_output "   ${line}"; done
  
  if namespace_exists "${namespace}"; then
    log_output "   ✓ Namespace created"
    return 0
  else
    log_output "   ❌ Failed to create namespace"
    return 1
  fi
}

# Import a single source to PVC
import_to_pvc() {
  local index=$1
  local total=$2
  
  local source="${IMPORT_SOURCES[$index]}"
  local pvc_name="${IMPORT_PVC_NAMES[$index]}"
  local namespace="${IMPORT_NAMESPACES[$index]}"
  local source_type="${IMPORT_SOURCE_TYPES[$index]}"
  local data_mode="${IMPORT_DATA_MODES[$index]}"
  
  # Set current pod name for cleanup trap
  CURRENT_POD_NAME=""
  CURRENT_NAMESPACE="${namespace}"
  CURRENT_PVC_NAME="${pvc_name}"
  CURRENT_IMPORT_PID=""
  CURRENT_TEMP_ERROR_FILE=""
  
  local IMPORT_PID=""
  local TEMP_ERROR_FILE=""
  
  log_output ""
  log_output "=========================================="
  log_output "Importing $((index + 1))/${total}: ${source}"
  log_output "  → ${namespace}/${pvc_name}"
  log_output "=========================================="
  log_output ""
  
  # Create namespace if needed
  for ns in "${NAMESPACES_TO_CREATE[@]:-}"; do
    if [ "${ns}" = "${namespace}" ]; then
      if ! create_namespace_if_needed "${namespace}"; then
        return 1
      fi
      break
    fi
  done
  
  # Create PVC if needed
  if ! create_pvc_if_needed "$index"; then
    return 1
  fi
  
  # Generate pod name
  local POD_NAME="import-$(echo "${pvc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g' | cut -c1-40)-$(date +%s)"
  CURRENT_POD_NAME="${POD_NAME}"
  
  log_output "🚀 Starting import..."
  log_output "  Source: ${source}"
  log_output "  Target: ${namespace}/${pvc_name}"
  log_output "  Mode: ${data_mode}"
  log_output "  Pod: ${POD_NAME}"
  log_output ""
  
  # Create import pod
  log_output "🔧 Creating import pod..."
  ${KUBECTL_CMD} run "${POD_NAME}" \
    --image=busybox:latest \
    --restart=Never \
    --namespace="${namespace}" \
    --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"import\",
        \"image\": \"busybox:latest\",
        \"command\": [\"sleep\", \"infinity\"],
        \"resources\": {
          \"limits\": {
            \"memory\": \"2Gi\"
          },
          \"requests\": {
            \"memory\": \"512Mi\"
          }
        },
        \"volumeMounts\": [{
          \"mountPath\": \"/data\",
          \"name\": \"data\"
        }]
      }],
      \"volumes\": [{
        \"name\": \"data\",
        \"persistentVolumeClaim\": {
          \"claimName\": \"${pvc_name}\"
        }
      }]
    }
  }" 2>&1 | grep -v "pod/.*created" || true
  
  # Wait for pod to be ready
  log_output "⏳ Waiting for pod to be ready..."
  local TIMEOUT=120
  local ELAPSED=0
  local PHASE=""
  local READY=""
  while [ $ELAPSED -lt $TIMEOUT ]; do
    PHASE=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    READY=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${namespace}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    if [ -z "$READY" ]; then
      READY="false"
    fi
    
    if [ "$PHASE" = "Running" ] && [ "$READY" = "true" ]; then
      break
    fi
    if [ "$PHASE" = "Failed" ] || [ "$PHASE" = "Error" ]; then
      log_output ""
      log_output "❌ Pod failed to start. Status: $PHASE"
      ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${namespace}" | tail -30 | while read line; do log_output "$line"; done
      save_pod_logs "${POD_NAME}" "${namespace}" "${pvc_name}"
      ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${namespace}" --ignore-not-found=true
      return 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    printf "\r   $(get_spinner) Waiting... (%d/%d seconds) [Phase: %s, Ready: %s]    " $ELAPSED $TIMEOUT "${PHASE:-Pending}" "${READY:-false}"
  done
  printf "\r%80s\r" " "
  
  if [ "$PHASE" != "Running" ] || [ "$READY" != "true" ]; then
    log_output "❌ Pod is not ready. Phase: $PHASE, Ready: $READY"
    ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${namespace}" | tail -20 | while read line; do log_output "$line"; done
    save_pod_logs "${POD_NAME}" "${namespace}" "${pvc_name}"
    ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${namespace}" --ignore-not-found=true
    return 1
  fi
  
  log_output "✓ Pod is ready and running"
  log_output ""
  
  # Clear existing data if requested
  if [ "${data_mode}" = "clear" ]; then
    log_output "🗑️  Clearing existing data..."
    ${KUBECTL_CMD} exec "${POD_NAME}" -n "${namespace}" -- sh -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true" 2>/dev/null || true
    log_output "✓ Existing data cleared"
    log_output ""
  fi
  
  # Import data based on source type
  log_output "📥 Importing data..."
  local IMPORT_START=$(date +%s)
  
  case "${source_type}" in
    folder)
      # Use tar to copy folder contents preserving permissions
      log_output "   Source type: folder"
      if command -v pv &> /dev/null; then
        TEMP_ERROR_FILE=$(mktemp)
        CURRENT_TEMP_ERROR_FILE="${TEMP_ERROR_FILE}"
        set +e
        tar -cf - -C "${source}" . 2>"${TEMP_ERROR_FILE}" | \
          pv -p -t -e -r -b | \
          ${KUBECTL_CMD} exec -i "${POD_NAME}" -n "${namespace}" -- tar -xf - -C /data 2>>"${TEMP_ERROR_FILE}"
        EXIT_CODE=$?
        set -e
      else
        log_output "   (Install 'pv' for better progress indication)"
        set +e
        tar -cf - -C "${source}" . | \
          ${KUBECTL_CMD} exec -i "${POD_NAME}" -n "${namespace}" -- tar -xf - -C /data
        EXIT_CODE=$?
        set -e
      fi
      ;;
    tar)
      # Import uncompressed tar
      log_output "   Source type: tar archive"
      if command -v pv &> /dev/null; then
        TEMP_ERROR_FILE=$(mktemp)
        CURRENT_TEMP_ERROR_FILE="${TEMP_ERROR_FILE}"
        set +e
        pv -p -t -e -r -b "${source}" | \
          ${KUBECTL_CMD} exec -i "${POD_NAME}" -n "${namespace}" -- tar -xf - -C /data 2>"${TEMP_ERROR_FILE}"
        EXIT_CODE=$?
        set -e
      else
        log_output "   (Install 'pv' for better progress indication)"
        set +e
        cat "${source}" | \
          ${KUBECTL_CMD} exec -i "${POD_NAME}" -n "${namespace}" -- tar -xf - -C /data
        EXIT_CODE=$?
        set -e
      fi
      ;;
    tar.gz)
      # Import compressed tar
      log_output "   Source type: compressed tar archive"
      if command -v pv &> /dev/null; then
        TEMP_ERROR_FILE=$(mktemp)
        CURRENT_TEMP_ERROR_FILE="${TEMP_ERROR_FILE}"
        set +e
        pv -p -t -e -r -b "${source}" | \
          ${KUBECTL_CMD} exec -i "${POD_NAME}" -n "${namespace}" -- tar -xzf - -C /data 2>"${TEMP_ERROR_FILE}"
        EXIT_CODE=$?
        set -e
      else
        log_output "   (Install 'pv' for better progress indication)"
        set +e
        cat "${source}" | \
          ${KUBECTL_CMD} exec -i "${POD_NAME}" -n "${namespace}" -- tar -xzf - -C /data
        EXIT_CODE=$?
        set -e
      fi
      ;;
  esac
  
  # Check for errors
  if [ ${EXIT_CODE:-0} -ne 0 ]; then
    log_output ""
    log_output "❌ Import failed (exit code: ${EXIT_CODE})"
    if [ -n "${TEMP_ERROR_FILE}" ] && [ -s "${TEMP_ERROR_FILE}" ]; then
      log_output "📋 Error output:"
      cat "${TEMP_ERROR_FILE}" | while read line; do log_output "   $line"; done
    fi
    rm -f "${TEMP_ERROR_FILE}" 2>/dev/null || true
    save_pod_logs "${POD_NAME}" "${namespace}" "${pvc_name}"
    ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${namespace}" --ignore-not-found=true
    return 1
  fi
  
  rm -f "${TEMP_ERROR_FILE}" 2>/dev/null || true
  
  local IMPORT_END=$(date +%s)
  local IMPORT_DURATION=$((IMPORT_END - IMPORT_START))
  
  # Verify import
  log_output ""
  log_output "🔍 Verifying import..."
  local DATA_SIZE=$(${KUBECTL_CMD} exec "${POD_NAME}" -n "${namespace}" -- du -sh /data 2>/dev/null | awk '{print $1}' || echo "unknown")
  local FILE_COUNT=$(${KUBECTL_CMD} exec "${POD_NAME}" -n "${namespace}" -- sh -c "find /data -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ' || echo "unknown")
  
  log_output "   Data size: ${DATA_SIZE}"
  log_output "   File count: ${FILE_COUNT}"
  log_output ""
  
  # Cleanup pod
  log_output "🧹 Cleaning up pod..."
  cleanup_pvc "${POD_NAME}" "${namespace}" "${IMPORT_PID:-}" "${TEMP_ERROR_FILE:-}" "${pvc_name}"
  log_output "✓ Cleanup complete"
  
  # Clear current pod name
  CURRENT_POD_NAME=""
  CURRENT_PVC_NAME=""
  CURRENT_IMPORT_PID=""
  CURRENT_TEMP_ERROR_FILE=""
  
  log_output ""
  log_output "=========================================="
  log_output "✅ Import completed successfully!"
  log_output "=========================================="
  log_output "  Source:     ${source}"
  log_output "  Target:     ${namespace}/${pvc_name}"
  log_output "  Duration:   $(format_time ${IMPORT_DURATION})"
  log_output "  Data size:  ${DATA_SIZE}"
  log_output ""
  
  return 0
}

# Global array for namespaces to create
NAMESPACES_TO_CREATE=()

# Parse arguments first (so --help and --version work without dependency checks)
SOURCES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -V|--version)
      echo "PVC Import Script version ${SCRIPT_VERSION}"
      exit 0
      ;;
    -h|--help)
      echo "Usage: $0 [-v] <source> [source2 ...]"
      echo ""
      echo "Imports data from folders, tar, or tar.gz archives into Kubernetes PVCs."
      echo ""
      echo "Options:"
      echo "  -v, --verbose      Enable verbose output"
      echo "  -V, --version      Show version information"
      echo "  -h, --help         Show this help message"
      echo ""
      echo "Sources can be:"
      echo "  - A folder path"
      echo "  - A .tar file"
      echo "  - A .tar.gz or .tgz file"
      echo ""
      echo "Examples:"
      echo "  $0 ./my-backup-folder"
      echo "  $0 ./default-my-pvc.tar.gz"
      echo "  $0 backup1.tar.gz backup2.tar.gz backup3/"
      echo ""
      echo "The script will prompt for target PVC and other options interactively."
      exit 0
      ;;
    -*)
      echo "❌ Unknown option: $1"
      echo "Use -h or --help for usage information"
      exit 1
      ;;
    *)
      SOURCES+=("$1")
      shift
      ;;
  esac
done

if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "❌ Error: At least one source is required"
  echo ""
  echo "Usage: $0 [-v] <source> [source2 ...]"
  echo ""
  echo "Sources can be folders, .tar files, or .tar.gz files"
  echo "Example: $0 ./my-backup.tar.gz"
  echo ""
  echo "Use -h for more help"
  exit 1
fi

# Check dependencies (prompts only, no install yet)
check_and_prompt_dependencies

# Check that sources exist and determine their types
echo ""
echo "=========================================="
echo "📁 Checking sources..."
echo "=========================================="

VALID_SOURCES=()
SOURCE_TYPES=()
SOURCE_SIZES=()

for source in "${SOURCES[@]}"; do
  # Normalize path
  if [ -e "${source}" ]; then
    source=$(realpath "${source}" 2>/dev/null || echo "${source}")
  fi
  
  source_type=$(get_source_type "${source}")
  
  echo ""
  echo "  ${source}"
  
  case "${source_type}" in
    folder)
      echo "    Type: Folder"
      size=$(get_source_size "${source}" "${source_type}")
      echo "    Size: $(format_bytes ${size})"
      VALID_SOURCES+=("${source}")
      SOURCE_TYPES+=("${source_type}")
      SOURCE_SIZES+=("${size}")
      ;;
    tar)
      echo "    Type: Tar archive"
      size=$(get_source_size "${source}" "${source_type}")
      echo "    Size: $(format_bytes ${size})"
      VALID_SOURCES+=("${source}")
      SOURCE_TYPES+=("${source_type}")
      SOURCE_SIZES+=("${size}")
      ;;
    tar.gz)
      echo "    Type: Compressed tar archive (tar.gz)"
      size=$(get_source_size "${source}" "${source_type}")
      echo "    Estimated uncompressed size: $(format_bytes ${size})"
      VALID_SOURCES+=("${source}")
      SOURCE_TYPES+=("${source_type}")
      SOURCE_SIZES+=("${size}")
      ;;
    not_found)
      echo "    ❌ Not found"
      ;;
    unknown)
      echo "    ❌ Unknown file type (not a folder, tar, or tar.gz)"
      ;;
  esac
done

if [ ${#VALID_SOURCES[@]} -eq 0 ]; then
  echo ""
  echo "❌ No valid sources found"
  exit 1
fi

echo ""
echo "✓ Found ${#VALID_SOURCES[@]} valid source(s)"

# Check if running interactively
if [ ! -t 0 ]; then
  echo ""
  echo "❌ This script requires interactive input"
  echo "   Please run it in an interactive terminal"
  exit 1
fi

# Initialize logging
init_log_file
if [ -n "${LOG_FILE}" ]; then
  echo ""
  echo "📝 Log file: ${LOG_FILE}"
fi

# Prompt for target configuration for each source
echo ""
echo "=========================================="
echo "🎯 Configure import targets"
echo "=========================================="
echo ""
echo "For each source, you'll be asked to specify the target PVC."
echo "If the PVC doesn't exist, you can create a new one."

for i in "${!VALID_SOURCES[@]}"; do
  prompt_for_target "${VALID_SOURCES[$i]}" "${SOURCE_TYPES[$i]}" "${SOURCE_SIZES[$i]}" "$((i + 1))"
done

# Prompt for data handling mode for each import
echo ""
echo "=========================================="
echo "📋 Configure data handling"
echo "=========================================="

for i in "${!IMPORT_SOURCES[@]}"; do
  prompt_data_handling "$i"
done

# Check for ReadWriteOnce conflicts
echo ""
echo "=========================================="
echo "🔍 Checking for conflicts..."
echo "=========================================="

SKIP_IMPORTS=()
for i in "${!IMPORT_SOURCES[@]}"; do
  if ! check_rwo_conflicts "$i"; then
    SKIP_IMPORTS+=("$i")
  fi
done

# Remove skipped imports
if [ ${#SKIP_IMPORTS[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  Some imports will be skipped due to conflicts"
fi

# Validate all sources
if ! validate_all_sources; then
  echo ""
  echo "❌ Source validation failed. Please fix the issues and try again."
  exit 1
fi

# Show summary and confirm
echo ""
echo "=========================================="
echo "📋 Import Summary"
echo "=========================================="
echo ""

for i in "${!IMPORT_SOURCES[@]}"; do
  _source="${IMPORT_SOURCES[$i]}"
  _pvc="${IMPORT_PVC_NAMES[$i]}"
  _ns="${IMPORT_NAMESPACES[$i]}"
  _create="${IMPORT_CREATE_PVC[$i]}"
  _mode="${IMPORT_DATA_MODES[$i]}"
  _sc="${IMPORT_STORAGE_CLASSES[$i]}"
  _size="${IMPORT_PVC_SIZES[$i]}"
  
  echo "  $((i + 1)). $(basename "${_source}")"
  echo "     → ${_ns}/${_pvc}"
  if [ "${_create}" = "true" ]; then
    echo "     📦 Create new PVC (${_size}, ${_sc})"
  fi
  echo "     Mode: ${_mode}"
  echo ""
done

echo ""
read -p "Proceed with import? (Y/n): " confirm
if [[ "${confirm}" =~ ^[Nn]$ ]]; then
  echo ""
  echo "Import cancelled."
  exit 0
fi

# Now install any pending dependencies (after user has confirmed)
install_pending_dependencies

# Execute imports
echo ""
echo "=========================================="
echo "🚀 Starting imports..."
echo "=========================================="

TOTAL=${#IMPORT_SOURCES[@]}

for i in "${!IMPORT_SOURCES[@]}"; do
  # Check if interrupted
  if [ "${INTERRUPTED}" = "true" ]; then
    echo ""
    echo "⚠️  Import process was interrupted. Stopping."
    break
  fi
  
  # Check if this import should be skipped
  _skip=false
  for s in "${SKIP_IMPORTS[@]:-}"; do
    if [ "$s" = "$i" ]; then
      _skip=true
      break
    fi
  done
  
  if [ "${_skip}" = "true" ]; then
    log_output ""
    log_output "⏭️  Skipping import $((i + 1))/${TOTAL}: $(basename "${IMPORT_SOURCES[$i]}")"
    continue
  fi
  
  if import_to_pvc "$i" "${TOTAL}"; then
    SUCCESSFUL_IMPORTS+=("${IMPORT_SOURCES[$i]}")
  else
    if [ "${INTERRUPTED}" = "true" ]; then
      break
    fi
    FAILED_IMPORTS+=("${IMPORT_SOURCES[$i]}")
  fi
done

# Final summary
echo ""
echo "=========================================="
echo "📊 Final Summary"
echo "=========================================="
echo "  Total:      ${TOTAL}"
echo "  Successful: ${#SUCCESSFUL_IMPORTS[@]}"
echo "  Failed:     ${#FAILED_IMPORTS[@]}"
echo ""

if [ ${#SUCCESSFUL_IMPORTS[@]} -gt 0 ]; then
  echo "✅ Successful imports:"
  for src in "${SUCCESSFUL_IMPORTS[@]}"; do
    echo "    - $(basename "${src}")"
  done
  echo ""
fi

if [ ${#FAILED_IMPORTS[@]} -gt 0 ]; then
  echo "❌ Failed imports:"
  for src in "${FAILED_IMPORTS[@]}"; do
    echo "    - $(basename "${src}")"
  done
  echo ""
  exit 1
fi

if [ "${INTERRUPTED}" = "true" ]; then
  exit 130
fi

echo "✅ All imports completed successfully!"

# Log final message
if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
  {
    echo ""
    echo "=========================================="
    echo "Log completed: $(date)"
    echo "=========================================="
  } >> "${LOG_FILE}" 2>/dev/null || true
fi

exit 0

