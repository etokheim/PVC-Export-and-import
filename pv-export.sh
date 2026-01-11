#!/bin/bash

###############################################################################
# PVC Export Script for Kubernetes
# 
# Exports the contents of Kubernetes PersistentVolumeClaims to compressed
# tar.gz archives. Supports multiple PVCs and custom output directories.
#
# Usage: ./pv-export.sh [-n namespace] [-o output-dir] [-v] <pvc-name[@namespace]> [...]
#
# Author: Auto-generated script
# Version: 2.0
###############################################################################

# Exit on error, but allow functions to handle errors gracefully
# Use set -e carefully - we handle errors in functions with return codes
set -e
# Enable nounset for better variable checking, but allow unset in some cases
set -u

# Script version
SCRIPT_VERSION="2.2"

# Get script directory for log file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}" .sh)

# Global variables
SUCCESSFUL_EXPORTS=()
FAILED_EXPORTS=()
VERBOSE=false
KUBECTL_CMD=""  # Will be set by detect_kubectl()
INTERRUPTED=false  # Track if script was interrupted
EXPORT_FORMAT="compressed"  # Export format: "compressed" (.tar.gz), "uncompressed" (.tar), or "folder"
LOG_FILE=""  # Will be set when logging is initialized

# Log directories
LOG_DIR="${SCRIPT_DIR}/logs"
POD_LOG_DIR="${SCRIPT_DIR}/logs/pod_logs"

# Helper functions for parsing pvc@namespace format
# Extract PVC name from "pvc@namespace" format
parse_pvc_name() {
  local entry=$1
  echo "${entry%%@*}"
}

# Extract namespace from "pvc@namespace" format
parse_pvc_namespace() {
  local entry=$1
  if [[ "$entry" == *"@"* ]]; then
    echo "${entry#*@}"
  else
    echo ""
  fi
}

# Format PVC entry for display (shows namespace if different from default or if mixed namespaces)
format_pvc_display() {
  local entry=$1
  local pvc_name=$(parse_pvc_name "$entry")
  local pvc_ns=$(parse_pvc_namespace "$entry")
  if [ -n "$pvc_ns" ]; then
    echo "${pvc_name} (${pvc_ns})"
  else
    echo "${pvc_name}"
  fi
}

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
    echo "PVC Export Script - Log Started"
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

# Cleanup function for individual PVC export
cleanup_pvc() {
  local pod_name=$1
  local namespace=$2
  local export_pid=$3
  local temp_error_file=$4
  local pvc_name=${5:-"unknown"}
  
  if [ -n "${pod_name}" ] && [ -n "${namespace}" ]; then
    # Kill background export process if running
    if [ -n "${export_pid}" ] && kill -0 "${export_pid}" 2>/dev/null; then
      log debug "Killing background export process ${export_pid}"
      kill "${export_pid}" 2>/dev/null || true
      wait "${export_pid}" 2>/dev/null || true
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
  
  # Mark as interrupted to stop processing remaining PVCs
  INTERRUPTED=true
  
  # Clean up any remaining pods from current export
  if [ -n "${CURRENT_POD_NAME:-}" ] && [ -n "${CURRENT_NAMESPACE:-}" ]; then
    echo ""
    echo "🛑 Interrupt received. Stopping all exports..."
    echo "🧹 Cleaning up current pod..."
    cleanup_pvc "${CURRENT_POD_NAME}" "${CURRENT_NAMESPACE}" "${CURRENT_EXPORT_PID:-}" "${CURRENT_TEMP_ERROR_FILE:-}" "${CURRENT_PVC_NAME:-}"
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
          description="Pipe viewer - provides progress bars during export (recommended)"
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
            echo "   ✓ ${dep} will be installed before export starts"
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

# Parse arguments first (so --help and --version work without dependency checks)
NAMESPACE="default"
OUTPUT_DIR="."
PVC_NAMES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)
      if [ -z "${2:-}" ]; then
        echo "❌ Error: ${1} requires a value"
        echo "   Usage: $0 ${1} <namespace> ..."
        exit 1
      fi
      NAMESPACE="$2"
      shift 2
      ;;
    -o|--output)
      if [ -z "${2:-}" ]; then
        echo "❌ Error: ${1} requires a value"
        echo "   Usage: $0 ${1} <directory> ..."
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    --uncompressed)
      EXPORT_FORMAT="uncompressed"
      shift
      ;;
    --folder)
      EXPORT_FORMAT="folder"
      shift
      ;;
    -V|--version)
      echo "PVC Export Script version ${SCRIPT_VERSION}"
      exit 0
      ;;
    -h|--help)
      echo "Usage: $0 [-n|--namespace namespace] [-o|--output directory] [--uncompressed] <pvc-name[@namespace]> [...]"
      echo ""
      echo "Options:"
      echo "  -n, --namespace    Default Kubernetes namespace for PVCs without @namespace (default: default)"
      echo "  -o, --output       Output directory for exported files (default: current directory)"
      echo "  -v, --verbose      Enable verbose output"
      echo "  --uncompressed     Use uncompressed tar (faster, less memory, larger files)"
      echo "                     Recommended for very large PVCs (>1TB)"
      echo "  --folder           Export to plain folder (no archive, uses kubectl cp)"
      echo "                     Best for quick access to files without extraction"
      echo "  -V, --version      Show version information"
      echo "  -h, --help         Show this help message"
      echo ""
      echo "PVC Naming:"
      echo "  You can specify the namespace per-PVC using the @namespace suffix:"
      echo "    pvc-name              Uses the default namespace (-n or 'default')"
      echo "    pvc-name@namespace    Uses the specified namespace"
      echo ""
      echo "Examples:"
      echo "  $0 my-pvc                                    # Uses 'default' namespace"
      echo "  $0 -n myns my-pvc                            # Uses 'myns' namespace"
      echo "  $0 my-pvc@production                         # Uses 'production' namespace"
      echo "  $0 pvc1@ns1 pvc2@ns2 pvc3@ns3                 # Multiple namespaces"
      echo "  $0 -n default pvc1 pvc2@other                # Mix: pvc1 uses 'default', pvc2 uses 'other'"
      echo "  $0 -o /backup pvc1@prod pvc2@staging"
      exit 0
      ;;
    *)
      PVC_NAMES+=("$1")
      shift
      ;;
  esac
done

# Check if we have any PVCs before processing
if [ ${#PVC_NAMES[@]} -eq 0 ]; then
  echo "❌ Error: At least one PVC name is required"
  echo ""
  echo "Usage: $0 [-n|--namespace namespace] [-o|--output directory] <pvc-name[@namespace]> [...]"
  echo "Example: $0 my-pvc                         # Uses 'default' namespace"
  echo "Example: $0 my-pvc@production              # Uses 'production' namespace"
  echo "Example: $0 pvc1@ns1 pvc2@ns2              # Multiple namespaces"
  echo "Example: $0 -n myns pvc1 pvc2@other        # Mix default and per-PVC namespaces"
  exit 1
fi

# Normalize PVC entries: ensure all entries have namespace (use default if not specified)
# Store as "pvc@namespace" format internally
PVC_ENTRIES=()
for entry in "${PVC_NAMES[@]}"; do
  if [[ "$entry" == *"@"* ]]; then
    # Already has namespace
    PVC_ENTRIES+=("$entry")
  else
    # Add default namespace
    PVC_ENTRIES+=("${entry}@${NAMESPACE}")
  fi
done
PVC_NAMES=("${PVC_ENTRIES[@]}")

# Check if we have multiple namespaces (for display purposes)
UNIQUE_NAMESPACES=()
for entry in "${PVC_NAMES[@]}"; do
  ns=$(parse_pvc_namespace "$entry")
  if [[ ! " ${UNIQUE_NAMESPACES[*]:-} " =~ " ${ns} " ]]; then
    UNIQUE_NAMESPACES+=("$ns")
  fi
done
MULTI_NAMESPACE_MODE=false
if [ ${#UNIQUE_NAMESPACES[@]} -gt 1 ]; then
  MULTI_NAMESPACE_MODE=true
fi

# Check dependencies (prompts only, no install yet)
check_and_prompt_dependencies

# Validate and prepare output directory
OUTPUT_DIR=$(realpath "${OUTPUT_DIR}" 2>/dev/null || echo "${OUTPUT_DIR}")
if [ ! -d "${OUTPUT_DIR}" ]; then
  echo "📁 Creating output directory: ${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}" || {
    echo "❌ Error: Cannot create output directory: ${OUTPUT_DIR}"
    exit 1
  }
fi

# Check write permissions in output directory
TEMP_TEST_FILE="${OUTPUT_DIR}/.pv-export-test-$$"
if ! touch "${TEMP_TEST_FILE}" 2>/dev/null; then
  echo "❌ Error: Cannot write to output directory: ${OUTPUT_DIR}"
  echo "   Please ensure the directory exists and you have write permissions"
  exit 1
fi
rm -f "${TEMP_TEST_FILE}"

# Function to export a single PVC
export_pvc() {
  local PVC_NAME=$1
  local NAMESPACE=$2
  local EXPORT_NUM=$3
  local TOTAL_EXPORTS=$4
  local OUTPUT_DIR=$5
  
  # Set current pod name for cleanup trap (initialize to avoid set -u errors)
  CURRENT_POD_NAME=""
  CURRENT_NAMESPACE="${NAMESPACE}"
  CURRENT_PVC_NAME="${PVC_NAME}"
  CURRENT_EXPORT_PID=""
  CURRENT_TEMP_ERROR_FILE=""
  
  # Initialize EXPORT_PID and TEMP_ERROR_FILE to empty to avoid unset variable errors
  local EXPORT_PID=""
  local TEMP_ERROR_FILE=""
  
  log_output ""
  log_output "=========================================="
  log_output "Exporting PVC ${EXPORT_NUM}/${TOTAL_EXPORTS}: ${PVC_NAME}"
  log_output "=========================================="
  log_output ""
  
  # Sanitize PVC name for filename (replace special chars with underscore)
  SANITIZED_PVC_NAME=$(echo "${PVC_NAME}" | sed 's/[^a-zA-Z0-9._-]/_/g')
  if [ "${EXPORT_FORMAT}" = "folder" ]; then
    OUTPUT_PATH="${OUTPUT_DIR}/${SANITIZED_PVC_NAME}@${NAMESPACE}"
    OUTPUT_FILE="${OUTPUT_PATH}"  # For compatibility with existing code
    log_output "📁 Using folder export (plain directory)"
  elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
    OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED_PVC_NAME}@${NAMESPACE}.tar"
    OUTPUT_PATH="${OUTPUT_FILE}"
    TAR_COMPRESS_FLAG=""
    log_output "📦 Using uncompressed export (faster, less memory, larger output file)"
  else
    OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED_PVC_NAME}@${NAMESPACE}.tar.gz"
    OUTPUT_PATH="${OUTPUT_FILE}"
    TAR_COMPRESS_FLAG="z"
  fi
  # Pod name: Kubernetes pod names must be lowercase, alphanumeric with hyphens, max 63 chars
  POD_NAME="export-$(echo "${PVC_NAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g' | cut -c1-40)-$(date +%s)-${EXPORT_NUM}"
  
  CURRENT_POD_NAME="${POD_NAME}"
  
  # Check if PVC exists and get details
  log_output "📋 Checking PVC details..."
  if ! ${KUBECTL_CMD} get pvc "${PVC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    echo "❌ Error: PVC '${PVC_NAME}' not found in namespace '${NAMESPACE}'"
    log debug "Checking if namespace exists..."
    if ! ${KUBECTL_CMD} get namespace "${NAMESPACE}" &>/dev/null; then
      echo "   Note: Namespace '${NAMESPACE}' does not exist"
    fi
    return 1
  fi

  PVC_INFO=$(${KUBECTL_CMD} get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o json)
  PVC_SIZE=$(echo "$PVC_INFO" | jq -r '.spec.resources.requests.storage // "unknown"')
  PVC_STATUS=$(echo "$PVC_INFO" | jq -r '.status.phase // "unknown"')
  PVC_STORAGE_CLASS=$(echo "$PVC_INFO" | jq -r '.spec.storageClassName // "default"')
  PVC_ACCESS_MODE=$(echo "$PVC_INFO" | jq -r '.spec.accessModes[0] // "unknown"')
  PVC_VOLUME_NAME=$(echo "$PVC_INFO" | jq -r '.spec.volumeName // "not bound"')
  
  log_output "✓ PVC found!"
  log_output "  Name:           ${PVC_NAME}"
  log_output "  Namespace:      ${NAMESPACE}"
  log_output "  Status:         ${PVC_STATUS}"
  log_output "  Size:           ${PVC_SIZE}"
  log_output "  Storage Class:  ${PVC_STORAGE_CLASS}"
  log_output "  Access Mode:    ${PVC_ACCESS_MODE}"
  log_output "  Volume Name:    ${PVC_VOLUME_NAME}"
  log_output ""
  
  if [ "${PVC_STATUS}" != "Bound" ]; then
    log_output "⚠️  Warning: PVC is not in 'Bound' status. Export may fail."
    log_output ""
  fi
  
  # Note: ReadWriteOnce conflicts and file overwrites are checked in pre_check_pvcs()
  # before exports start, so we don't need to prompt here during the transfer
  
  # Check write permissions in output directory
  if ! touch "${OUTPUT_FILE}.test" 2>/dev/null; then
    echo "❌ Error: Cannot write to output directory: ${OUTPUT_DIR}"
    echo "   Please ensure the directory exists and you have write permissions"
    return 1
  fi
  rm -f "${OUTPUT_FILE}.test"
  
  # Check available disk space (warn if very low - less than 1GB)
  log_output "💾 Checking disk space..."
  if command -v df &> /dev/null; then
    AVAILABLE_SPACE_KB=$(df -k "${OUTPUT_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$AVAILABLE_SPACE_KB" != "0" ] && [ "$AVAILABLE_SPACE_KB" -lt 1048576 ]; then
      AVAILABLE_SPACE_GB=$(awk "BEGIN {printf \"%.1f\", $AVAILABLE_SPACE_KB/1024/1024}")
      echo "⚠️  Warning: Low disk space detected (${AVAILABLE_SPACE_GB} GB available)."
      if [ "${EXPORT_FORMAT}" = "folder" ]; then
        echo "   Export may fail if there's not enough space for the folder backup."
      elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
        echo "   Export may fail if there's not enough space for the uncompressed backup."
      else
        echo "   Export may fail if there's not enough space for the compressed backup."
      fi
      echo ""
    fi
  fi
  
  log_output "🚀 Starting export..."
  log_output "  Output file: ${OUTPUT_FILE}"
  log_output "  Pod name:    ${POD_NAME}"
  log_output ""
  
  # Calculate memory limit based on PVC size (for large PVCs, need more memory)
  # Default: 2Gi, but increase for large PVCs
  MEMORY_LIMIT="2Gi"
  PVC_SIZE_NUM=$(echo "${PVC_SIZE}" | sed 's/[^0-9]//g')
  PVC_SIZE_UNIT=$(echo "${PVC_SIZE}" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]')
  
  # Handle TiB/TB units (convert to Gi for comparison)
  PVC_SIZE_GI="${PVC_SIZE_NUM}"
  if [ "${PVC_SIZE_UNIT}" = "TI" ] || [ "${PVC_SIZE_UNIT}" = "T" ]; then
    # Convert TB to Gi (1TB = 1024Gi)
    PVC_SIZE_GI=$((PVC_SIZE_NUM * 1024))
  fi
  
  # Convert to Gi for comparison (check larger sizes first)
  if [ "${PVC_SIZE_UNIT}" = "GI" ] || [ "${PVC_SIZE_UNIT}" = "G" ] || [ "${PVC_SIZE_UNIT}" = "TI" ] || [ "${PVC_SIZE_UNIT}" = "T" ]; then
    if [ "${PVC_SIZE_GI}" -gt 1024 ]; then
      # Very large PVCs (>1TB) - use 16Gi memory
      MEMORY_LIMIT="16Gi"
      log_output "⚠️  Extremely large PVC detected (${PVC_SIZE}). Using maximum memory limit (${MEMORY_LIMIT})"
      if [ "${EXPORT_FORMAT}" = "compressed" ]; then
        log_output "   💡 Tip: Consider using --uncompressed or --folder flag for faster export with less memory usage"
        log_output "   Example: $0 --uncompressed -o ${OUTPUT_DIR} ${PVC_NAME}"
      fi
    elif [ "${PVC_SIZE_GI}" -gt 500 ]; then
      MEMORY_LIMIT="8Gi"
      log_output "⚠️  Very large PVC detected (${PVC_SIZE}). Using increased memory limit (${MEMORY_LIMIT})"
      if [ "${PVC_SIZE_GI}" -gt 800 ] && [ "${EXPORT_FORMAT}" = "compressed" ]; then
        log_output "   💡 Tip: For PVCs >800Gi, consider using --uncompressed or --folder flag to reduce memory usage"
      fi
    elif [ "${PVC_SIZE_GI}" -gt 100 ]; then
      MEMORY_LIMIT="4Gi"
      log_output "⚠️  Large PVC detected (${PVC_SIZE}). Using increased memory limit (${MEMORY_LIMIT})"
    fi
  fi
  
  # Create pod
  log_output "🔧 Creating export pod..."
  log debug "Pod name: ${POD_NAME}, Namespace: ${NAMESPACE}, PVC: ${PVC_NAME}, Memory limit: ${MEMORY_LIMIT}"
  ${KUBECTL_CMD} run "${POD_NAME}" \
    --image=busybox:latest \
    --restart=Never \
    --namespace="${NAMESPACE}" \
    --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"export\",
        \"image\": \"busybox:latest\",
        \"command\": [\"sleep\", \"infinity\"],
        \"resources\": {
          \"limits\": {
            \"memory\": \"${MEMORY_LIMIT}\"
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
          \"claimName\": \"${PVC_NAME}\"
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
  local WAIT_SPINNER=""
  while [ $ELAPSED -lt $TIMEOUT ]; do
    PHASE=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    # Check if containerStatuses exists and has at least one element
    READY=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    # If containerStatuses is empty, ready will be empty, so default to false
    if [ -z "$READY" ]; then
      READY="false"
    fi
    
    if [ "$PHASE" = "Running" ] && [ "$READY" = "true" ]; then
      break
    fi
    if [ "$PHASE" = "Failed" ] || [ "$PHASE" = "Error" ]; then
      log_output ""
      log_output "❌ Pod failed to start. Status: $PHASE"
      log_output ""
      log_output "📋 Pod events:"
      ${KUBECTL_CMD} get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${POD_NAME}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 | while read line; do log_output "$line"; done || log_output "  (No events found)"
      log_output ""
      log_output "📋 Pod description:"
      ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -30 | while read line; do log_output "$line"; done
      save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
      ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
      return 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    WAIT_SPINNER=$(get_spinner)
    printf "\r   ${WAIT_SPINNER} Waiting... (%d/%d seconds) [Phase: %s, Ready: %s]    " $ELAPSED $TIMEOUT "${PHASE:-Pending}" "${READY:-false}"
  done
  printf "\r%80s\r" " "  # Clear progress line
  
  # Final check that pod is actually ready
  PHASE=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  READY=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  
  if [ "$PHASE" != "Running" ] || [ "$READY" != "true" ]; then
    log_output "❌ Pod is not ready. Phase: $PHASE, Ready: $READY"
    log_output ""
    log_output "📋 Pod events:"
    ${KUBECTL_CMD} get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${POD_NAME}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 | while read line; do log_output "$line"; done || log_output "  (No events found)"
    log_output ""
    ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -30 | while read line; do log_output "$line"; done
    save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
    ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    return 1
  fi
  
  log_output "✓ Pod is ready and running"
  log_output ""
  
  # Verify pod is still running before export
  PHASE=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$PHASE" != "Running" ]; then
    log_output "❌ Pod is not running. Current phase: $PHASE"
    ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -20 | while read line; do log_output "$line"; done
    save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
    ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    return 1
  fi
  
  # Verify data directory is accessible
  log_output "🔍 Verifying data directory access..."
  if ! ${KUBECTL_CMD} exec "${POD_NAME}" -n "${NAMESPACE}" -- test -d /data 2>/dev/null; then
    log_output "❌ Cannot access /data directory in pod"
    log_output "📋 Pod description:"
    ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -30 | while read line; do log_output "$line"; done
    save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
    ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    return 1
  fi
  
  # Calculate data size (can take a while for large volumes)
  log_output "📊 Calculating data size (this may take a while for large volumes)..."
  local DU_TEMP_FILE=$(mktemp)
  ${KUBECTL_CMD} exec "${POD_NAME}" -n "${NAMESPACE}" -- du -sh /data > "${DU_TEMP_FILE}" 2>/dev/null &
  local DU_PID=$!
  local DU_START=$(date +%s)
  local DU_ELAPSED=0
  local DU_SPINNER=""
  
  # Show spinner while du runs
  while kill -0 "${DU_PID}" 2>/dev/null; do
    DU_ELAPSED=$(($(date +%s) - DU_START))
    DU_SPINNER=$(get_spinner)
    printf "\r   ${DU_SPINNER} Calculating... (elapsed: %s)    " "$(format_time $DU_ELAPSED)"
    sleep 1
  done
  printf "\r%80s\r" " "  # Clear line
  
  wait "${DU_PID}" 2>/dev/null || true
  DATA_SIZE=$(cat "${DU_TEMP_FILE}" 2>/dev/null | awk '{print $1}' || echo "unknown")
  rm -f "${DU_TEMP_FILE}"
  
  log_output "✓ Data directory accessible (size: ${DATA_SIZE})"
  log_output ""
  
  # Export with progress
  log_output "📥 Exporting data..."
  EXPORT_START=$(date +%s)
  
  # Handle folder export differently
  if [ "${EXPORT_FORMAT}" = "folder" ]; then
    # Create output directory
    mkdir -p "${OUTPUT_PATH}"
    log debug "Starting folder export to ${OUTPUT_PATH}"
    
    # Use kubectl cp to copy files from pod to local folder (run in background for progress)
    TEMP_ERROR_FILE=$(mktemp)
    CURRENT_TEMP_ERROR_FILE="${TEMP_ERROR_FILE}"
    ${KUBECTL_CMD} cp "${NAMESPACE}/${POD_NAME}:/data/." "${OUTPUT_PATH}/" 2>"${TEMP_ERROR_FILE}" &
    EXPORT_PID=$!
    CURRENT_EXPORT_PID="${EXPORT_PID}"
    
    # Monitor progress with spinner, file count, and folder size
    local PROGRESS_START=$(date +%s)
    local PREV_SIZE=0
    local PREV_COUNT=0
    local POD_CHECK_COUNTER=0
    local CURRENT_SIZE=0
    local CURRENT_COUNT=0
    local ELAPSED=0
    local SPEED_BPS=0
    local SPINNER=""
    local SIZE_STR=""
    local COUNT_STR=""
    local TIME_STR=""
    
    log_output "   Copying files to folder..."
    
    while kill -0 "${EXPORT_PID}" 2>/dev/null; do
      # Check pod status every 5 seconds
      POD_CHECK_COUNTER=$((POD_CHECK_COUNTER + 1))
      if [ $POD_CHECK_COUNTER -ge 5 ]; then
        POD_CHECK_COUNTER=0
        PHASE=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$PHASE" != "Running" ]; then
          printf "\r%80s\r" " "
          log_output "❌ Pod stopped running during export. Phase: $PHASE"
          kill "${EXPORT_PID}" 2>/dev/null || true
          wait "${EXPORT_PID}" 2>/dev/null || true
          ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -20 | while read line; do log_output "$line"; done
          save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
          ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
          rm -rf "${OUTPUT_PATH}"
          return 1
        fi
      fi
      
      # Get current folder size and file count
      if [ -d "${OUTPUT_PATH}" ]; then
        CURRENT_SIZE=$(du -sk "${OUTPUT_PATH}" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
        CURRENT_COUNT=$(find "${OUTPUT_PATH}" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
      fi
      ELAPSED=$(($(date +%s) - PROGRESS_START))
      
      # Calculate speed
      SPEED_BPS=0
      if [ "$CURRENT_SIZE" -gt "$PREV_SIZE" ]; then
        SPEED_BPS=$((CURRENT_SIZE - PREV_SIZE))
      fi
      PREV_SIZE=$CURRENT_SIZE
      PREV_COUNT=$CURRENT_COUNT
      
      # Format display values
      SPINNER=$(get_spinner)
      if [ "$CURRENT_SIZE" -ge 1073741824 ]; then
        SIZE_STR=$(awk "BEGIN {printf \"%.2f GB\", $CURRENT_SIZE/1024/1024/1024}")
      elif [ "$CURRENT_SIZE" -ge 1048576 ]; then
        SIZE_STR=$(awk "BEGIN {printf \"%.1f MB\", $CURRENT_SIZE/1024/1024}")
      else
        SIZE_STR=$(awk "BEGIN {printf \"%.0f KB\", $CURRENT_SIZE/1024}")
      fi
      
      if [ "$SPEED_BPS" -ge 1048576 ]; then
        SPEED_STR=$(awk "BEGIN {printf \"%.1f MB/s\", $SPEED_BPS/1024/1024}")
      elif [ "$SPEED_BPS" -gt 0 ]; then
        SPEED_STR=$(awk "BEGIN {printf \"%.0f KB/s\", $SPEED_BPS/1024}")
      else
        SPEED_STR="--"
      fi
      
      TIME_STR=$(format_time $ELAPSED)
      COUNT_STR="${CURRENT_COUNT} files"
      
      printf "\r   ${SPINNER} ${SIZE_STR} | ${COUNT_STR} | ${SPEED_STR} | ${TIME_STR}     "
      sleep 1
    done
    
    # Wait for process and get exit code
    wait "${EXPORT_PID}" 2>/dev/null
    EXIT_CODE=$?
    CURRENT_EXPORT_PID=""
    
    # Clear progress line
    printf "\r%80s\r" " "
    
    if [ $EXIT_CODE -ne 0 ]; then
      if [ -s "${TEMP_ERROR_FILE}" ]; then
        log_output ""
        log_output "📋 Error output:"
        cat "${TEMP_ERROR_FILE}" | while read line; do log_output "$line"; done
      fi
      rm -f "${TEMP_ERROR_FILE}"
      log_output ""
      log_output "❌ Folder export failed (exit code: ${EXIT_CODE})"
      log_output ""
      log_output "📋 Checking pod status..."
      ${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" | while read line; do log_output "$line"; done
      save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
      ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
      # Clean up partial folder on failure
      rm -rf "${OUTPUT_PATH}"
      return 1
    fi
    rm -f "${TEMP_ERROR_FILE}"
  # Check if pv (pipe viewer) is available for progress (for tar exports)
  elif command -v pv &> /dev/null; then
    # Use pv for progress if available
    # Note: pv -s expects bytes, but PVC_SIZE is human-readable, so we'll let pv estimate
    # Redirect stderr to a temp file to capture errors separately
    TEMP_ERROR_FILE=$(mktemp)
    CURRENT_TEMP_ERROR_FILE="${TEMP_ERROR_FILE}"
    log debug "Starting export with pv, temp error file: ${TEMP_ERROR_FILE}, format: ${EXPORT_FORMAT}"
    # Use set +e temporarily for pipe handling
    set +e
    if [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
      ${KUBECTL_CMD} exec "${POD_NAME}" -n "${NAMESPACE}" -- tar -cf - -C /data . 2>"${TEMP_ERROR_FILE}" | \
        pv -p -t -e -r -b > "${OUTPUT_FILE}"
    else
      ${KUBECTL_CMD} exec "${POD_NAME}" -n "${NAMESPACE}" -- tar -czf - -C /data . 2>"${TEMP_ERROR_FILE}" | \
        pv -p -t -e -r -b > "${OUTPUT_FILE}"
    fi
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
    if [ $EXIT_CODE -ne 0 ]; then
      # Show errors if any
      if [ -s "${TEMP_ERROR_FILE}" ]; then
        log_output ""
        log_output "📋 Error output:"
        cat "${TEMP_ERROR_FILE}" | while read line; do log_output "$line"; done
      fi
      rm -f "${TEMP_ERROR_FILE}"
      log_output ""
      
      # Check for specific error codes
      if [ $EXIT_CODE -eq 137 ]; then
        log_output "❌ Export failed: Process was killed (exit code 137)"
        log_output ""
        log_output "   Possible causes:"
        log_output "   1. Out of memory (OOM killed) - check pod memory usage"
        log_output "   2. Node pressure - the node may have evicted the pod"
        log_output "   3. Storage issue - the underlying storage may have disconnected"
        log_output ""
        log_output "   For large PVCs (${PVC_SIZE}), try:"
        log_output "   - Pod memory limit: ${MEMORY_LIMIT} (automatically set based on PVC size)"
        log_output "   - Export during low-usage periods"
        log_output "   - Check cluster node resources: ${KUBECTL_CMD} top nodes"
        log_output ""
        log_output "   Checking pod resource usage..."
        ${KUBECTL_CMD} top pod "${POD_NAME}" -n "${NAMESPACE}" 2>/dev/null | while read line; do log_output "$line"; done || log_output "   (Resource metrics not available)"
      else
        log_output "❌ Export failed (exit code: ${EXIT_CODE})"
      fi
      log_output ""
      log_output "📋 Checking pod status..."
      ${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" | while read line; do log_output "$line"; done
      log_output ""
      log_output "📋 Pod events:"
      ${KUBECTL_CMD} get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${POD_NAME}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 | while read line; do log_output "$line"; done || log_output "  (No events found)"
      
      # Check for OOM events specifically
      OOM_EVENT=$(${KUBECTL_CMD} get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${POD_NAME}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "oom\|killed\|memory" || echo "")
      if [ -n "${OOM_EVENT}" ]; then
        log_output ""
        log_output "⚠️  OOM (Out of Memory) event detected in pod events:"
        echo "${OOM_EVENT}" | head -3 | while read line; do log_output "$line"; done
      fi
      
      save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
      ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
      return 1
    fi
    # Clean up temp error file on success
    rm -f "${TEMP_ERROR_FILE}"
  else
    # Fallback: show file size growth with spinner and speed (for tar exports without pv)
    log_output "   (Install 'pv' for better progress indication)"
    log debug "Starting export without pv, output file: ${OUTPUT_FILE}, format: ${EXPORT_FORMAT}"
    if [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
      ${KUBECTL_CMD} exec "${POD_NAME}" -n "${NAMESPACE}" -- tar -cf - -C /data . > "${OUTPUT_FILE}" 2>&1 &
    else
      ${KUBECTL_CMD} exec "${POD_NAME}" -n "${NAMESPACE}" -- tar -czf - -C /data . > "${OUTPUT_FILE}" 2>&1 &
    fi
    EXPORT_PID=$!
    CURRENT_EXPORT_PID="${EXPORT_PID}"
    
    # Initialize progress tracking
    local PROGRESS_START=$(date +%s)
    local PREV_SIZE=0
    local SPEED_SAMPLES=()
    local POD_CHECK_COUNTER=0
    local CURRENT_SIZE=0
    local ELAPSED=0
    local SPEED_BPS=0
    local AVG_SPEED=0
    local SPINNER=""
    local SIZE_STR=""
    local SPEED_STR=""
    local TIME_STR=""
    local s=0
    
    # Monitor file size and pod status
    while kill -0 "${EXPORT_PID}" 2>/dev/null; do
      # Check pod status every 5 seconds (expensive operation)
      POD_CHECK_COUNTER=$((POD_CHECK_COUNTER + 1))
      if [ $POD_CHECK_COUNTER -ge 5 ]; then
        POD_CHECK_COUNTER=0
        PHASE=$(${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$PHASE" != "Running" ]; then
          printf "\r%80s\r" " "  # Clear line
          log_output ""
          log_output "❌ Pod stopped during export. Phase: $PHASE"
          kill "${EXPORT_PID}" 2>/dev/null || true
          wait "${EXPORT_PID}" 2>/dev/null || true
          ${KUBECTL_CMD} describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -20 | while read line; do log_output "$line"; done
          save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
          ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
          return 1
        fi
      fi
      
      # Get current file size
      if [ -f "${OUTPUT_FILE}" ]; then
        CURRENT_SIZE=$(stat -f%z "${OUTPUT_FILE}" 2>/dev/null || stat -c%s "${OUTPUT_FILE}" 2>/dev/null || echo "0")
        ELAPSED=$(($(date +%s) - PROGRESS_START))
        
        # Calculate speed (bytes since last check)
        SPEED_BPS=0
        if [ "$CURRENT_SIZE" -gt "$PREV_SIZE" ]; then
          SPEED_BPS=$((CURRENT_SIZE - PREV_SIZE))
        fi
        PREV_SIZE=$CURRENT_SIZE
        
        # Keep last 10 speed samples for averaging
        SPEED_SAMPLES+=($SPEED_BPS)
        if [ ${#SPEED_SAMPLES[@]} -gt 10 ]; then
          SPEED_SAMPLES=("${SPEED_SAMPLES[@]:1}")
        fi
        
        # Calculate average speed
        AVG_SPEED=0
        for s in "${SPEED_SAMPLES[@]}"; do
          AVG_SPEED=$((AVG_SPEED + s))
        done
        if [ ${#SPEED_SAMPLES[@]} -gt 0 ]; then
          AVG_SPEED=$((AVG_SPEED / ${#SPEED_SAMPLES[@]}))
        fi
        
        # Format output
        SPINNER=$(get_spinner)
        SIZE_STR=$(format_bytes $CURRENT_SIZE)
        SPEED_STR=$(format_speed $AVG_SPEED)
        TIME_STR=$(format_time $ELAPSED)
        
        printf "\r   ${SPINNER} Transferred: %-12s Speed: %-12s Elapsed: %-10s" "$SIZE_STR" "$SPEED_STR" "$TIME_STR"
      else
        SPINNER=$(get_spinner)
        printf "\r   ${SPINNER} Waiting for data..."
      fi
      sleep 1
    done
    printf "\r%80s\r" " "  # Clear progress line
    
    # Check exit status
    if ! wait "${EXPORT_PID}"; then
      EXIT_CODE=$?
      log_output ""
      if [ $EXIT_CODE -eq 137 ]; then
        log_output "❌ Export failed: Process was killed (exit code 137)"
        log_output ""
        log_output "   Possible causes:"
        log_output "   1. Out of memory (OOM killed) - check pod memory usage"
        log_output "   2. Node pressure - the node may have evicted the pod"
        log_output "   3. Storage issue - the underlying storage may have disconnected"
        log_output ""
        log_output "   For large PVCs (${PVC_SIZE}), current memory limit: ${MEMORY_LIMIT}"
        log_output "   Check available node memory: ${KUBECTL_CMD} top nodes"
      else
        log_output "❌ Export command failed (exit code: ${EXIT_CODE})"
      fi
      ${KUBECTL_CMD} get pod "${POD_NAME}" -n "${NAMESPACE}" | while read line; do log_output "$line"; done
      save_pod_logs "${POD_NAME}" "${NAMESPACE}" "${PVC_NAME}"
      ${KUBECTL_CMD} delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
      return 1
    fi
    log_output ""
  fi
  
  EXPORT_END=$(date +%s)
  EXPORT_DURATION=$((EXPORT_END - EXPORT_START))
  
  # Clean up pod
  log_output ""
  log_output "🧹 Cleaning up pod..."
  cleanup_pvc "${POD_NAME}" "${NAMESPACE}" "${EXPORT_PID:-}" "${TEMP_ERROR_FILE:-}" "${PVC_NAME}"
  log_output "✓ Cleanup complete"
  log_output ""
  
  # Clear current pod name so trap doesn't try to clean it up again
  CURRENT_POD_NAME=""
  CURRENT_PVC_NAME=""
  CURRENT_EXPORT_PID=""
  CURRENT_TEMP_ERROR_FILE=""
  
  # Verify and show results
  if [ "${EXPORT_FORMAT}" = "folder" ]; then
    # For folder exports, check if directory exists and has content
    if [ -d "${OUTPUT_PATH}" ]; then
      FOLDER_SIZE=$(du -sh "${OUTPUT_PATH}" 2>/dev/null | awk '{print $1}' || echo "unknown")
      FILE_COUNT=$(find "${OUTPUT_PATH}" -type f 2>/dev/null | wc -l | tr -d ' ')
      
      log_output "=========================================="
      log_output "✅ Export completed successfully!"
      log_output "=========================================="
      log_output "  Output folder:  ${OUTPUT_PATH}"
      log_output "  Folder size:    ${FOLDER_SIZE}"
      log_output "  File count:     ${FILE_COUNT} files"
      log_output "  Duration:       ${EXPORT_DURATION} seconds"
    else
      log_output "=========================================="
      log_output "❌ Export failed!"
      log_output "=========================================="
      log_output "  Output folder is missing"
      return 1
    fi
  elif [ -f "${OUTPUT_FILE}" ] && [ -s "${OUTPUT_FILE}" ]; then
    FILE_SIZE=$(stat -f%z "${OUTPUT_FILE}" 2>/dev/null || stat -c%s "${OUTPUT_FILE}" 2>/dev/null || echo "0")
    FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE/1024/1024}")
    FILE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE/1024/1024/1024}")

    log_output "=========================================="
    log_output "✅ Export completed successfully!"
    log_output "=========================================="
    log_output "  Output file:    ${OUTPUT_FILE}"
    log_output "  File size:      ${FILE_SIZE_MB} MB (${FILE_SIZE_GB} GB)"
    log_output "  Duration:       ${EXPORT_DURATION} seconds"
    if [ $EXPORT_DURATION -gt 0 ]; then
      SPEED_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE_MB/$EXPORT_DURATION}")
      log_output "  Average speed:  ${SPEED_MB} MB/s"
    fi
    log_output "  PVC size:       ${PVC_SIZE}"
    log_output ""
    ls -lh "${OUTPUT_FILE}" | while read line; do log_output "$line"; done
    log_output ""
  else
    log_output "=========================================="
    log_output "❌ Export failed!"
    log_output "=========================================="
    log_output "  Output file is missing or empty"
    return 1
  fi
  
  # Success - return 0
  return 0
}

# Function to pre-check all PVCs and get user confirmations before starting exports
# PVC entries are in "pvc@namespace" format
pre_check_pvcs() {
  local OUTPUT_DIR=$1
  local PVC_ENTRIES_ARRAY=("${@:2}")
  
  local SKIP_PVCS=()
  local CONFLICT_PVCS=()
  local OVERWRITE_PVCS=()
  local VALID_PVCS=()
  
  echo "🔍 Pre-checking all PVCs before starting exports..."
  echo ""
  
  for PVC_ENTRY in "${PVC_ENTRIES_ARRAY[@]}"; do
    # Parse entry to get PVC name and namespace
    local PVC_NAME=$(parse_pvc_name "$PVC_ENTRY")
    local NAMESPACE=$(parse_pvc_namespace "$PVC_ENTRY")
    
    # Sanitize PVC name for filename
    SANITIZED_PVC_NAME=$(echo "${PVC_NAME}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    if [ "${EXPORT_FORMAT}" = "folder" ]; then
      OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED_PVC_NAME}@${NAMESPACE}"
    elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
      OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED_PVC_NAME}@${NAMESPACE}.tar"
    else
      OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED_PVC_NAME}@${NAMESPACE}.tar.gz"
    fi
    
    # Check if PVC exists
    if ! ${KUBECTL_CMD} get pvc "${PVC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
      log_output "❌ PVC '${PVC_NAME}' not found in namespace '${NAMESPACE}'"
      SKIP_PVCS+=("${PVC_ENTRY}")
      continue
    fi
    
    # Get PVC info
    PVC_INFO=$(${KUBECTL_CMD} get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null)
    if [ -z "${PVC_INFO}" ]; then
      log_output "❌ Cannot retrieve information for PVC '${PVC_NAME}'"
      SKIP_PVCS+=("${PVC_ENTRY}")
      continue
    fi
    
    PVC_ACCESS_MODE=$(echo "$PVC_INFO" | jq -r '.spec.accessModes[0] // "unknown"')
    PVC_STATUS=$(echo "$PVC_INFO" | jq -r '.status.phase // "unknown"')
    
    # Check ReadWriteOnce conflicts
    if [ "${PVC_ACCESS_MODE}" = "ReadWriteOnce" ] || [ "${PVC_ACCESS_MODE}" = "RWO" ]; then
      MOUNTED_BY=$(${KUBECTL_CMD} get pods --all-namespaces -o json 2>/dev/null | \
        jq -r --arg pvc "${PVC_NAME}" --arg ns "${NAMESPACE}" \
        '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName==$pvc and .metadata.namespace==$ns) | 
        "\(.metadata.namespace)/\(.metadata.name) [\(.status.phase)]"' 2>/dev/null || echo "")
      
      if [ -n "${MOUNTED_BY}" ]; then
        CONFLICT_PVCS+=("${PVC_ENTRY}|${MOUNTED_BY}")
      fi
    fi
    
    # Check for existing output files/folders
    if [ -f "${OUTPUT_FILE}" ] || [ -d "${OUTPUT_FILE}" ]; then
      OVERWRITE_PVCS+=("${PVC_ENTRY}|${OUTPUT_FILE}")
    fi
    
    # Check PVC status
    if [ "${PVC_STATUS}" != "Bound" ]; then
      log_output "⚠️  Warning: PVC '${PVC_NAME}' (${NAMESPACE}) is not in 'Bound' status (${PVC_STATUS})"
    fi
    
    VALID_PVCS+=("${PVC_ENTRY}")
  done
  
  echo ""
  
  # Handle conflicts
  if [ ${#CONFLICT_PVCS[@]} -gt 0 ]; then
    log_output "⚠️  ReadWriteOnce PVC Conflicts Detected:"
    log_output ""
    for conflict in "${CONFLICT_PVCS[@]}"; do
      PVC_ENTRY=$(echo "$conflict" | cut -d'|' -f1)
      MOUNTED_BY=$(echo "$conflict" | cut -d'|' -f2-)
      local disp_pvc=$(parse_pvc_name "$PVC_ENTRY")
      local disp_ns=$(parse_pvc_namespace "$PVC_ENTRY")
      log_output "  - ${disp_pvc} (${disp_ns}) is mounted by:"
      echo "${MOUNTED_BY}" | sed 's/^/    /' | while read line; do log_output "$line"; done
      log_output ""
    done
    log_output "   The export pods may fail to start. Consider:"
    log_output "   1. Stopping the pod(s) using these PVCs temporarily"
    log_output "   2. Or use a different backup method"
    log_output ""
    if [ -t 0 ]; then
      read -p "   Continue with conflicting PVCs anyway? (y/N): " -n 1 -r
      echo
      log_output "   User response: ${REPLY}"
    else
      log_output "   Running non-interactively, skipping conflicting PVCs..."
      REPLY="N"
    fi
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      for conflict in "${CONFLICT_PVCS[@]}"; do
        PVC_ENTRY=$(echo "$conflict" | cut -d'|' -f1)
        SKIP_PVCS+=("${PVC_ENTRY}")
        # Remove from VALID_PVCS
        local NEW_VALID=()
        for v in ${VALID_PVCS[@]+"${VALID_PVCS[@]}"}; do
          if [ "$v" != "${PVC_ENTRY}" ]; then
            NEW_VALID+=("$v")
          fi
        done
        VALID_PVCS=(${NEW_VALID[@]+"${NEW_VALID[@]}"})
      done
    fi
    log_output ""
  fi
  
  # Handle overwrites
  if [ ${#OVERWRITE_PVCS[@]} -gt 0 ]; then
    log_output "⚠️  Existing Output Files Detected:"
    log_output ""
    for overwrite in "${OVERWRITE_PVCS[@]}"; do
      PVC_ENTRY=$(echo "$overwrite" | cut -d'|' -f1)
      OUTPUT_FILE=$(echo "$overwrite" | cut -d'|' -f2)
      local disp_pvc=$(parse_pvc_name "$PVC_ENTRY")
      local disp_ns=$(parse_pvc_namespace "$PVC_ENTRY")
      log_output "  - ${disp_pvc} (${disp_ns}): ${OUTPUT_FILE}"
    done
    log_output ""
    if [ -t 0 ]; then
      read -p "   Overwrite existing files? (y/N): " -n 1 -r
      echo
      log_output "   User response: ${REPLY}"
    else
      log_output "   Running non-interactively, skipping PVCs with existing files..."
      REPLY="N"
    fi
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      for overwrite in "${OVERWRITE_PVCS[@]}"; do
        PVC_ENTRY=$(echo "$overwrite" | cut -d'|' -f1)
        SKIP_PVCS+=("${PVC_ENTRY}")
        # Remove from VALID_PVCS
        local NEW_VALID=()
        for v in ${VALID_PVCS[@]+"${VALID_PVCS[@]}"}; do
          if [ "$v" != "${PVC_ENTRY}" ]; then
            NEW_VALID+=("$v")
          fi
        done
        VALID_PVCS=(${NEW_VALID[@]+"${NEW_VALID[@]}"})
      done
    else
      # Remove existing files
      for overwrite in "${OVERWRITE_PVCS[@]}"; do
        OUTPUT_FILE=$(echo "$overwrite" | cut -d'|' -f2)
        rm -f "${OUTPUT_FILE}"
      done
    fi
    log_output ""
  fi
  
  # Summary
  if [ ${#SKIP_PVCS[@]} -gt 0 ]; then
    log_output "📋 PVCs to skip: ${#SKIP_PVCS[@]}"
    for pvc_entry in "${SKIP_PVCS[@]}"; do
      local disp_pvc=$(parse_pvc_name "$pvc_entry")
      local disp_ns=$(parse_pvc_namespace "$pvc_entry")
      log_output "   - ${disp_pvc} (${disp_ns})"
    done
    log_output ""
  fi
  
  if [ ${#VALID_PVCS[@]} -eq 0 ]; then
    log_output "❌ No valid PVCs to export after pre-checks"
    return 1
  fi
  
  log_output "✅ Ready to export ${#VALID_PVCS[@]} PVC(s)"
  log_output ""
  
  # Export the arrays (using a hack with eval since bash doesn't support returning arrays)
  # We'll use global variables instead
  # Use ${array[@]+"${array[@]}"} syntax to handle empty arrays with set -u
  PRE_CHECK_SKIP_PVCS=(${SKIP_PVCS[@]+"${SKIP_PVCS[@]}"})
  PRE_CHECK_VALID_PVCS=(${VALID_PVCS[@]+"${VALID_PVCS[@]}"})
  
  return 0
}

# Main script execution
# Initialize log file
init_log_file
if [ -n "${LOG_FILE}" ]; then
  echo "📝 Log file: ${LOG_FILE}"
  if [ -n "${POD_LOG_DIR}" ]; then
    echo "📋 Pod logs: ${POD_LOG_DIR}"
  fi
  echo ""
fi

log_output "=========================================="
log_output "PVC Export Script"
log_output "=========================================="
log_output "  Kubernetes:    ${KUBECTL_CMD}"
if [ "${MULTI_NAMESPACE_MODE}" = "true" ]; then
  log_output "  Namespaces:    multiple (${#UNIQUE_NAMESPACES[@]})"
else
  log_output "  Namespace:     ${UNIQUE_NAMESPACES[0]}"
fi
log_output "  Output dir:    ${OUTPUT_DIR}"
log_output "  PVCs to export: ${#PVC_NAMES[@]}"
for entry in "${PVC_NAMES[@]}"; do
  pvc_name=$(parse_pvc_name "$entry")
  pvc_ns=$(parse_pvc_namespace "$entry")
  if [ "${MULTI_NAMESPACE_MODE}" = "true" ]; then
    log_output "    - ${pvc_name} (${pvc_ns})"
  else
    log_output "    - ${pvc_name}"
  fi
done
log_output ""

# Check disk space once at the start
log_output "💾 Checking disk space in output directory..."
if command -v df &> /dev/null; then
  AVAILABLE_SPACE_KB=$(df -k "${OUTPUT_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  if [ "$AVAILABLE_SPACE_KB" != "0" ] && [ "$AVAILABLE_SPACE_KB" -lt 1048576 ]; then
    AVAILABLE_SPACE_GB=$(awk "BEGIN {printf \"%.1f\", $AVAILABLE_SPACE_KB/1024/1024}")
    log_output "⚠️  Warning: Low disk space detected (${AVAILABLE_SPACE_GB} GB available)."
    if [ "${EXPORT_FORMAT}" = "folder" ]; then
      log_output "   Exports may fail if there's not enough space for the folder backups."
    elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
      log_output "   Exports may fail if there's not enough space for the uncompressed backups."
    else
      log_output "   Exports may fail if there's not enough space for the compressed backups."
    fi
    log_output ""
  fi
fi

# Prompt for export format if not already specified via command-line
if [ "${EXPORT_FORMAT}" = "compressed" ]; then
  # Check if we're in an interactive terminal
  if [ -t 0 ]; then
    echo ""
    echo "📦 Export Format Options:"
    echo "   [1] Compressed (.tar.gz):   Smaller files, slower export, more memory usage"
    echo "   [2] Uncompressed (.tar):    Larger files, faster export, less memory usage"
    echo "   [3] Folder:                 Plain directory, fastest, easy file access"
    echo ""
    echo "   💡 Tip: For very large PVCs (>1TB), uncompressed or folder is recommended"
    echo ""
    while true; do
      read -p "   Choose format [1/2/3] (default: 1): " FORMAT_CHOICE
      FORMAT_CHOICE=$(echo "${FORMAT_CHOICE}" | tr '[:upper:]' '[:lower:]')
      if [ -z "${FORMAT_CHOICE}" ] || [ "${FORMAT_CHOICE}" = "1" ]; then
        EXPORT_FORMAT="compressed"
        log_output "✓ Using compressed export (.tar.gz)"
        break
      elif [ "${FORMAT_CHOICE}" = "2" ]; then
        EXPORT_FORMAT="uncompressed"
        log_output "✓ Using uncompressed export (.tar)"
        break
      elif [ "${FORMAT_CHOICE}" = "3" ]; then
        EXPORT_FORMAT="folder"
        log_output "✓ Using folder export (plain directory)"
        break
      else
        echo "   Please enter 1, 2, or 3"
      fi
    done
    echo ""
  else
    # Non-interactive mode: default to compressed
    log_output "ℹ️  Non-interactive mode: using compressed export (.tar.gz)"
    log_output "   (Use --uncompressed or --folder flag to change format)"
  fi
elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
  log_output "ℹ️  Using uncompressed export (.tar) as specified by --uncompressed flag"
elif [ "${EXPORT_FORMAT}" = "folder" ]; then
  log_output "ℹ️  Using folder export (plain directory) as specified by --folder flag"
fi

# Pre-check all PVCs and get user confirmations
PRE_CHECK_SKIP_PVCS=()
PRE_CHECK_VALID_PVCS=()
if ! pre_check_pvcs "${OUTPUT_DIR}" "${PVC_NAMES[@]}"; then
  log_output "❌ Pre-check failed. Exiting."
  exit 1
fi

# Export each PVC (only the valid ones)
TOTAL=${#PRE_CHECK_VALID_PVCS[@]}
EXPORT_NUM=0

for PVC_ENTRY in "${PRE_CHECK_VALID_PVCS[@]}"; do
  # Check if script was interrupted
  if [ "${INTERRUPTED}" = "true" ]; then
    echo ""
    echo "⚠️  Export process was interrupted. Stopping all remaining exports."
    break
  fi
  
  # Parse entry to get PVC name and namespace
  PVC_NAME=$(parse_pvc_name "$PVC_ENTRY")
  PVC_NAMESPACE=$(parse_pvc_namespace "$PVC_ENTRY")
  
  EXPORT_NUM=$((EXPORT_NUM + 1))
  
  if export_pvc "${PVC_NAME}" "${PVC_NAMESPACE}" "${EXPORT_NUM}" "${TOTAL}" "${OUTPUT_DIR}"; then
    SUCCESSFUL_EXPORTS+=("${PVC_ENTRY}")
  else
    # Check if failure was due to interruption
    if [ "${INTERRUPTED}" = "true" ]; then
      echo ""
      echo "⚠️  Export interrupted. Stopping all remaining exports."
      break
    fi
    FAILED_EXPORTS+=("${PVC_ENTRY}")
  fi
done

# Show interruption summary if interrupted
if [ "${INTERRUPTED}" = "true" ]; then
  log_output ""
  log_output "=========================================="
  log_output "Export Interrupted"
  log_output "=========================================="
  log_output "  Total PVCs:     ${TOTAL}"
  log_output "  Completed:      ${#SUCCESSFUL_EXPORTS[@]}"
  log_output "  Failed:         ${#FAILED_EXPORTS[@]}"
  log_output "  Interrupted:    Yes"
  log_output ""
  if [ ${#SUCCESSFUL_EXPORTS[@]} -gt 0 ]; then
    log_output "✅ Successfully exported before interruption:"
    for pvc_entry in "${SUCCESSFUL_EXPORTS[@]}"; do
      pvc_name=$(parse_pvc_name "$pvc_entry")
      pvc_ns=$(parse_pvc_namespace "$pvc_entry")
      SANITIZED=$(echo "${pvc_name}" | sed 's/[^a-zA-Z0-9._-]/_/g')
      if [ "${EXPORT_FORMAT}" = "folder" ]; then
        OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED}@${pvc_ns}"
      elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
        OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED}@${pvc_ns}.tar"
      else
        OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED}@${pvc_ns}.tar.gz"
      fi
      if [ "${EXPORT_FORMAT}" = "folder" ] && [ -d "${OUTPUT_FILE}" ]; then
        FOLDER_SIZE=$(du -sh "${OUTPUT_FILE}" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_output "    - ${pvc_name} (${pvc_ns}) → ${OUTPUT_FILE}/ (${FOLDER_SIZE})"
      elif [ -f "${OUTPUT_FILE}" ]; then
        FILE_SIZE=$(stat -f%z "${OUTPUT_FILE}" 2>/dev/null || stat -c%s "${OUTPUT_FILE}" 2>/dev/null || echo "0")
        FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE/1024/1024}")
        log_output "    - ${pvc_name} (${pvc_ns}) → ${OUTPUT_FILE} (${FILE_SIZE_MB} MB)"
      else
        log_output "    - ${pvc_name} (${pvc_ns}) → ${OUTPUT_FILE}"
      fi
    done
    log_output ""
  fi
  if [ ${#FAILED_EXPORTS[@]} -gt 0 ]; then
    log_output "❌ Failed exports:"
    for pvc_entry in "${FAILED_EXPORTS[@]}"; do
      pvc_name=$(parse_pvc_name "$pvc_entry")
      pvc_ns=$(parse_pvc_namespace "$pvc_entry")
      log_output "    - ${pvc_name} (${pvc_ns})"
    done
    log_output ""
  fi
fi

# Final summary (only if not interrupted)
if [ "${INTERRUPTED}" != "true" ]; then
  log_output ""
  log_output "=========================================="
  log_output "Export Summary"
  log_output "=========================================="
  log_output "  Total PVCs:     ${TOTAL}"
  log_output "  Successful:     ${#SUCCESSFUL_EXPORTS[@]}"
  log_output "  Failed:         ${#FAILED_EXPORTS[@]}"
  if [ ${#PRE_CHECK_SKIP_PVCS[@]} -gt 0 ]; then
    log_output "  Skipped:        ${#PRE_CHECK_SKIP_PVCS[@]}"
  fi
  log_output ""
else
  # Summary was already shown in cleanup function
  echo ""
fi

if [ ${#SUCCESSFUL_EXPORTS[@]} -gt 0 ]; then
  log_output "✅ Successfully exported:"
  for pvc_entry in "${SUCCESSFUL_EXPORTS[@]}"; do
    pvc_name=$(parse_pvc_name "$pvc_entry")
    pvc_ns=$(parse_pvc_namespace "$pvc_entry")
    SANITIZED=$(echo "${pvc_name}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    if [ "${EXPORT_FORMAT}" = "folder" ]; then
      OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED}@${pvc_ns}"
    elif [ "${EXPORT_FORMAT}" = "uncompressed" ]; then
      OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED}@${pvc_ns}.tar"
    else
      OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED}@${pvc_ns}.tar.gz"
    fi
    if [ "${EXPORT_FORMAT}" = "folder" ] && [ -d "${OUTPUT_FILE}" ]; then
      FOLDER_SIZE=$(du -sh "${OUTPUT_FILE}" 2>/dev/null | awk '{print $1}' || echo "unknown")
      log_output "    - ${pvc_name} (${pvc_ns}) → ${OUTPUT_FILE}/ (${FOLDER_SIZE})"
    elif [ -f "${OUTPUT_FILE}" ]; then
      FILE_SIZE=$(stat -f%z "${OUTPUT_FILE}" 2>/dev/null || stat -c%s "${OUTPUT_FILE}" 2>/dev/null || echo "0")
      FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE/1024/1024}")
      log_output "    - ${pvc_name} (${pvc_ns}) → ${OUTPUT_FILE} (${FILE_SIZE_MB} MB)"
    else
      log_output "    - ${pvc_name} (${pvc_ns}) → ${OUTPUT_FILE}"
    fi
  done
  log_output ""
fi

if [ "${INTERRUPTED}" = "true" ]; then
  exit 130  # Standard exit code for SIGINT (Ctrl+C)
elif [ ${#FAILED_EXPORTS[@]} -gt 0 ]; then
  log_output "❌ Failed exports:"
  for pvc_entry in "${FAILED_EXPORTS[@]}"; do
    pvc_name=$(parse_pvc_name "$pvc_entry")
    pvc_ns=$(parse_pvc_namespace "$pvc_entry")
    log_output "    - ${pvc_name} (${pvc_ns})"
  done
  log_output ""
  exit 1
fi

# Show skipped PVCs if any
if [ ${#PRE_CHECK_SKIP_PVCS[@]} -gt 0 ]; then
  log_output "⏭️  Skipped PVCs (from pre-check):"
  for pvc_entry in "${PRE_CHECK_SKIP_PVCS[@]}"; do
    pvc_name=$(parse_pvc_name "$pvc_entry")
    pvc_ns=$(parse_pvc_namespace "$pvc_entry")
    log_output "    - ${pvc_name} (${pvc_ns})"
  done
  log_output ""
fi

if [ ${#FAILED_EXPORTS[@]} -eq 0 ]; then
  log_output "✅ All exports completed successfully!"
fi

# Log final message to log file
if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
  {
    echo ""
    echo "=========================================="
    echo "Log completed: $(date)"
    echo "=========================================="
  } >> "${LOG_FILE}" 2>/dev/null || true
fi

exit 0