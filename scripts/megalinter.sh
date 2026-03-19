#!/usr/bin/env bash

# megalinter.sh
#
# @description
# Ego Hygiene MegaLinter CLI
#
# A portable, Docker-based interface for running MegaLinter locally with:
# - Dynamic linter discovery (name ↔ descriptor)
# - Descriptor-based filtering
# - Optional caching
# - Clean CLI ergonomics
#
# This script is designed to function as both:
# - A standalone CLI tool
# - A sourceable module for testing (Bats)
#
# @usage
# ./scripts/megalinter.sh [options]
#
# @example
# ./scripts/megalinter.sh --descriptors PYTHON
#

# ------------------------------------------------------------------------------
# Execution Mode Detection
# ------------------------------------------------------------------------------

# Indicates whether this script is being sourced or executed
IS_EXECUTED_DIRECTLY="false"
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  IS_EXECUTED_DIRECTLY="true"
fi

# ------------------------------------------------------------------------------
# Strict Mode (only when executed directly)
# ------------------------------------------------------------------------------

if [[ "${IS_EXECUTED_DIRECTLY}" == "true" ]]; then
  set -o errexit
  set -o nounset
  set -o pipefail
fi

# ------------------------------------------------------------------------------
# Globals & Constants
# ------------------------------------------------------------------------------

# Script identity
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Docker image (pinned for reproducibility)
readonly DOCKER_IMAGE="oxsecurity/megalinter@sha256:ed944524cb36342a3693f5297ab92aef7188beff0a20a396fe9e90b4dcbbacfb"

# Workspace context
WORKSPACE_DIR="$(pwd)"
readonly WORKSPACE_DIR

# Cache file (used only when --cache is enabled)
readonly LINTER_CACHE_FILE=".cache/megalinter/linters.txt"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_INTERRUPTED=130

# ------------------------------------------------------------------------------
# Logging Utilities
# ------------------------------------------------------------------------------

# log_info
#
# @description
# Print an informational message to stdout.
#
# @arg $* Message to log
#
log_info() {
  printf "[%s][INFO] %s\n" "${SCRIPT_NAME}" "$*"
}

# log_warn
#
# @description
# Print a warning message to stderr.
#
# @arg $* Message to log
#
log_warn() {
  printf "[%s][WARN] %s\n" "${SCRIPT_NAME}" "$*" >&2
}

# log_error
#
# @description
# Print an error message to stderr.
#
# @arg $* Message to log
#
log_error() {
  printf "[%s][ERROR] %s\n" "${SCRIPT_NAME}" "$*" >&2
}

# log_debug
#
# @description
# Print a debug message when DEBUG_MODE is enabled.
#
# @arg $* Message to log
#
log_debug() {
  if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
    printf "[%s][DEBUG] %s\n" "${SCRIPT_NAME}" "$*"
  fi
}

# ------------------------------------------------------------------------------
# Cleanup & Signal Handling
# ------------------------------------------------------------------------------

# cleanup
#
# @description
# Executes on script exit. Used for cleanup and final error reporting.
#
cleanup() {
  local exit_code=$?

  # NOTE:
  # Add cleanup logic here if needed (temp files, containers, etc.)

  if [[ $exit_code -ne ${EXIT_SUCCESS} ]]; then
    log_error "Script exited with status ${exit_code}"
  else
    log_debug "Script exited successfully"
  fi
}

# on_interrupt
#
# @description
# Handles SIGINT (Ctrl+C)
#
on_interrupt() {
  log_warn "Execution interrupted by user"
  exit "${EXIT_INTERRUPTED}"
}

# on_error
#
# @description
# Handles unhandled errors when strict mode is enabled.
#
on_error() {
  local exit_code=$?
  log_error "Unhandled error occurred (exit code: ${exit_code})"
  exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# Trap Registration (only when executed directly)
# ------------------------------------------------------------------------------

if [[ "${IS_EXECUTED_DIRECTLY}" == "true" ]]; then
  trap cleanup EXIT
  trap on_interrupt INT
  trap on_error ERR
fi

# ------------------------------------------------------------------------------
# check_dependencies
#
# @description
# Verify that all required system dependencies are available before execution.
#
# Required tools:
# - bash
# - docker
# - awk
# - curl
# - git
#
# Exits with failure if any dependency is missing.
#
# @exitcode
# 0 if all dependencies are present, 1 otherwise
# ------------------------------------------------------------------------------

check_dependencies() {
  local required_commands=(
    "bash"
    "docker"
    "awk"
    "curl"
    "git"
    "sort"
  )

  local missing_dependencies=()

  for command_name in "${required_commands[@]}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing_dependencies+=("${command_name}")
    fi
  done

  if [[ ${#missing_dependencies[@]} -ne 0 ]]; then
    log_error "Missing required dependencies: ${missing_dependencies[*]}"
    exit "${EXIT_FAILURE}"
  fi

  log_debug "All dependencies are available"
}

# ------------------------------------------------------------------------------
# CLI Defaults
# ------------------------------------------------------------------------------

# NOTE:
# These represent the initial execution state before parsing arguments.

DEBUG_MODE="false"
CACHE_MODE="false"
REFRESH_CACHE_MODE="false"

CHANGED_ONLY="false"
FIX_MODE="false"

RAW_LINTER_INPUT=""
DESCRIPTOR_FILTER=""

LIST_MODE="false"
LIST_MAP_MODE="false"
LIST_DESCRIPTORS_MODE="false"

# ------------------------------------------------------------------------------
# show_help
#
# @description
# Display usage information for the CLI.
# ------------------------------------------------------------------------------

show_help() {
  cat <<EOF
Usage:
  ./scripts/megalinter.sh [options]

Options:
  --linters "eslint,flake8"     Run specific linters
  --descriptors "PYTHON,YAML"   Run linters by descriptor category

  --cache                       Use cached linter registry
  --refresh-cache               Refresh cached registry

  --changed-only                Only lint changed files
  --fix                         Apply auto-fixes

  --list                        List all available linters
  --list-map                    Show linter → descriptor mapping
  --list-descriptors            List descriptor categories

  --debug                       Enable debug logging
  --help                        Show this message
EOF
}

# ------------------------------------------------------------------------------
# get_github_repository
#
# @description
# Resolve the GitHub "owner/repo" from the current git remote origin.
#
# Supports SSH and HTTPS remote URL formats. Returns "unknown/unknown" when
# the remote cannot be parsed or does not exist.
#
# @stdout owner/repo string
# @exitcode 0 always
# ------------------------------------------------------------------------------

get_github_repository() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"

  if [[ -z "${remote_url}" ]]; then
    printf "unknown/unknown\n"
    return 0
  fi

  local repo

  # SSH format: git@github.com:owner/repo.git
  if [[ "${remote_url}" =~ ^git@github\.com:([^/]+/.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    repo="${repo%.git}"
    printf "%s\n" "${repo}"
    return 0
  fi

  # HTTPS format: https://github.com/owner/repo[.git]
  if [[ "${remote_url}" =~ ^https://github\.com/([^/]+/.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    repo="${repo%.git}"
    printf "%s\n" "${repo}"
    return 0
  fi

  printf "unknown/unknown\n"
}

# ------------------------------------------------------------------------------
# parse_arguments
#
# @description
# Parse CLI arguments and populate global state variables.
#
# @arg $@ Command-line arguments
# ------------------------------------------------------------------------------

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in

      # ----------------------------------------------------------------------
      # Linter Selection
      # ----------------------------------------------------------------------

      --linters)
        RAW_LINTER_INPUT="$2"
        shift 2
        ;;
      --descriptors)
        DESCRIPTOR_FILTER="$2"
        shift 2
        ;;

      # ----------------------------------------------------------------------
      # Execution Modes
      # ----------------------------------------------------------------------

      --changed-only)
        CHANGED_ONLY="true"
        shift
        ;;
      --fix)
        FIX_MODE="true"
        shift
        ;;

      # ----------------------------------------------------------------------
      # Cache Control
      # ----------------------------------------------------------------------

      --cache)
        CACHE_MODE="true"
        shift
        ;;
      --refresh-cache)
        REFRESH_CACHE_MODE="true"
        shift
        ;;

      # ----------------------------------------------------------------------
      # Introspection / Listing
      # ----------------------------------------------------------------------

      --list)
        LIST_MODE="true"
        shift
        ;;
      --list-map)
        LIST_MAP_MODE="true"
        shift
        ;;
      --list-descriptors)
        LIST_DESCRIPTORS_MODE="true"
        shift
        ;;

      # ----------------------------------------------------------------------
      # Debugging
      # ----------------------------------------------------------------------

      --debug)
        DEBUG_MODE="true"
        shift
        ;;

      # ----------------------------------------------------------------------
      # Help
      # ----------------------------------------------------------------------

      --help)
        show_help
        exit "${EXIT_SUCCESS}"
        ;;

      # ----------------------------------------------------------------------
      # Unknown Argument
      # ----------------------------------------------------------------------

      *)
        log_error "Unknown argument: $1"
        exit "${EXIT_FAILURE}"
        ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# fetch_megalinter_linter_map
#
# @description
# Fetch MegaLinter linter registry from official docs and extract
# "linter|DESCRIPTOR" pairs.
#
# Uses portable awk parsing (macOS + Linux compatible).
#
# @stdout
# newline-delimited list of "name|descriptor"
#
# @exitcode
# 0 on success, non-zero on failure
# ------------------------------------------------------------------------------

fetch_megalinter_linter_map() {
  local megalinter_url="https://megalinter.io/latest/all_linters/"

  curl --silent --fail "${megalinter_url}" | awk '
    /<tr>/ {
      name=""
      desc=""
    }

    /<strong>/ {
      line=$0
      sub(/.*<strong>/, "", line)
      sub(/<\/strong>.*/, "", line)
      name=line
    }

    /descriptors\// {
      line=$0
      sub(/.*descriptors\/[^"]*">/, "", line)
      sub(/<.*/, "", line)
      desc=line
    }

    /<\/tr>/ {
      if (name != "" && desc != "") {
        printf "%s|%s\n", name, desc
      }
    }
  '
}

# ------------------------------------------------------------------------------
# ensure_linter_cache
#
# @description
# Create cache file if it does not exist.
# ------------------------------------------------------------------------------

ensure_linter_cache() {
  if [[ ! -f "${LINTER_CACHE_FILE}" ]]; then
    log_debug "Cache miss → fetching linter registry"
    mkdir -p "$(dirname "${LINTER_CACHE_FILE}")"
    fetch_megalinter_linter_map | sort -u > "${LINTER_CACHE_FILE}"
  fi
}

# ------------------------------------------------------------------------------
# refresh_linter_cache
#
# @description
# Force refresh of linter cache.
# ------------------------------------------------------------------------------

refresh_linter_cache() {
  log_info "Refreshing linter cache"
  mkdir -p "$(dirname "${LINTER_CACHE_FILE}")"
  fetch_megalinter_linter_map | sort -u > "${LINTER_CACHE_FILE}"
}

# ------------------------------------------------------------------------------
# load_linter_registry
#
# @description
# Load linter registry from either:
# - live fetch (default)
# - cache (--cache)
# - refreshed cache (--refresh-cache)
#
# This function is the SINGLE SOURCE OF TRUTH for registry data.
#
# @stdout
# newline-delimited list of "name|descriptor"
# ------------------------------------------------------------------------------

load_linter_registry() {

  # --------------------------------------------------------------------------
  # Force refresh takes highest priority
  # --------------------------------------------------------------------------
  if [[ "${REFRESH_CACHE_MODE}" == "true" ]]; then
    refresh_linter_cache
    cat "${LINTER_CACHE_FILE}"
    return
  fi

  # --------------------------------------------------------------------------
  # Use cache if explicitly requested
  # --------------------------------------------------------------------------
  if [[ "${CACHE_MODE}" == "true" ]]; then
    ensure_linter_cache
    cat "${LINTER_CACHE_FILE}"
    return
  fi

  # --------------------------------------------------------------------------
  # Default: fetch fresh every time
  # --------------------------------------------------------------------------
  log_debug "Fetching linter registry (no cache)"
  fetch_megalinter_linter_map
}

# ------------------------------------------------------------------------------
# Runtime Maps
# ------------------------------------------------------------------------------

# NOTE:
# These maps are populated dynamically at runtime.

declare -A LINTER_NAME_TO_DESCRIPTOR
declare -A DESCRIPTOR_TO_LINTERS

# ------------------------------------------------------------------------------
# build_linter_maps
#
# @description
# Build in-memory mappings from linter registry data.
#
# Populates:
# - LINTER_NAME_TO_DESCRIPTOR[name] = DESCRIPTOR
# - DESCRIPTOR_TO_LINTERS[DESCRIPTOR] = comma-separated list of linters
#
# @stdin
# newline-delimited "name|descriptor"
#
# @example
# load_linter_registry | build_linter_maps
# ------------------------------------------------------------------------------
build_linter_maps() {
  local linter_name=""
  local descriptor=""

  # Reset maps (important for repeated calls)
  LINTER_NAME_TO_DESCRIPTOR=()
  DESCRIPTOR_TO_LINTERS=()

  while IFS="|" read -r linter_name descriptor; do

    # Skip malformed lines
    if [[ -z "${linter_name}" || -z "${descriptor}" ]]; then
      continue
    fi

    # ------------------------------------------------------------------------
    # Map: name → descriptor
    # ------------------------------------------------------------------------
    LINTER_NAME_TO_DESCRIPTOR["${linter_name}"]="${descriptor}"

    # ------------------------------------------------------------------------
    # Map: descriptor → list of linters
    # ------------------------------------------------------------------------
    if [[ -n "${DESCRIPTOR_TO_LINTERS[$descriptor]:-}" ]]; then
      DESCRIPTOR_TO_LINTERS["${descriptor}"]+=",${linter_name}"
    else
      DESCRIPTOR_TO_LINTERS["${descriptor}"]="${linter_name}"
    fi

  done
}

# ------------------------------------------------------------------------------
# initialize_linter_maps
#
# @description
# Load registry data and build mapping structures.
#
# This is the only function that should:
# - call load_linter_registry
# - initialize mapping state
# ------------------------------------------------------------------------------

initialize_linter_maps() {
  log_debug "Initializing linter maps"

  local registry_data
  registry_data="$(load_linter_registry)"
  build_linter_maps <<< "${registry_data}"

  log_debug "Loaded ${#LINTER_NAME_TO_DESCRIPTOR[@]} linters"
}

# ------------------------------------------------------------------------------
# normalize_linter_to_megalinter_key
#
# @description
# Convert a linter name + descriptor into a MegaLinter ENABLE_LINTERS key.
#
# Example:
#   (eslint, JAVASCRIPT) → JAVASCRIPT_ESLINT
#   (ruff-format, PYTHON) → PYTHON_RUFF_FORMAT
#
# @arg $1 Linter name
# @arg $2 Descriptor
# @stdout MegaLinter key
# ------------------------------------------------------------------------------

normalize_linter_to_megalinter_key() {
  local linter_name="$1"
  local descriptor="$2"

  # Convert linter name → uppercase + underscores
  local normalized_name
  normalized_name="$(echo "${linter_name}" | tr '[:lower:]-' '[:upper:]_')"

  printf "%s_%s\n" "${descriptor}" "${normalized_name}"
}

# ------------------------------------------------------------------------------
# resolve_linters
#
# @description
# Resolve CLI inputs into MegaLinter ENABLE_LINTERS value.
#
# Combines:
# - Explicit linters (--linters)
# - Descriptor groups (--descriptors)
#
# Uses dynamic registry + mapping layer.
#
# @stdout
# Comma-separated MegaLinter keys
# ------------------------------------------------------------------------------

resolve_linters() {
  local resolved_linter_names=()
  local final_keys=()

  # --------------------------------------------------------------------------
  # Descriptor expansion
  # --------------------------------------------------------------------------
  if [[ -n "${DESCRIPTOR_FILTER}" ]]; then
    IFS=',' read -ra DESCRIPTORS <<< "${DESCRIPTOR_FILTER}"

    for descriptor in "${DESCRIPTORS[@]}"; do
      descriptor="$(echo "${descriptor}" | tr '[:lower:]' '[:upper:]')"

      if [[ -n "${DESCRIPTOR_TO_LINTERS[$descriptor]:-}" ]]; then
        IFS=',' read -ra names <<< "${DESCRIPTOR_TO_LINTERS[$descriptor]}"
        for name in "${names[@]}"; do
          resolved_linter_names+=("${name}")
        done
      else
        log_warn "Unknown descriptor: ${descriptor}"
      fi
    done
  fi

  # --------------------------------------------------------------------------
  # Explicit linter input
  # --------------------------------------------------------------------------
  if [[ -n "${RAW_LINTER_INPUT}" ]]; then
    IFS=',' read -ra INPUT <<< "${RAW_LINTER_INPUT}"

    for item in "${INPUT[@]}"; do
      resolved_linter_names+=("${item}")
    done
  fi

  # --------------------------------------------------------------------------
  # Deduplicate linter names
  # --------------------------------------------------------------------------
  local unique_linter_names=()
  declare -A seen

  for name in "${resolved_linter_names[@]}"; do
    if [[ -z "${seen[$name]:-}" ]]; then
      unique_linter_names+=("${name}")
      seen[$name]="true"
    fi
  done

  # --------------------------------------------------------------------------
  # Convert to MegaLinter keys
  # --------------------------------------------------------------------------
  for name in "${unique_linter_names[@]}"; do

    local descriptor="${LINTER_NAME_TO_DESCRIPTOR[$name]:-}"

    if [[ -z "${descriptor}" ]]; then
      log_warn "Unknown linter: ${name} (skipping)"
      continue
    fi

    final_keys+=("$(normalize_linter_to_megalinter_key "${name}" "${descriptor}")")

  done

  # --------------------------------------------------------------------------
  # Output final ENABLE_LINTERS string
  # --------------------------------------------------------------------------
  printf "%s\n" "$(IFS=','; echo "${final_keys[*]}")"
}

# ------------------------------------------------------------------------------
# Introspection Functions
# ------------------------------------------------------------------------------

# list_linters
#
# @description
# Print all known linter names, one per line, sorted alphabetically.
#
# @stdout sorted linter names
# ------------------------------------------------------------------------------

list_linters() {
  local name
  for name in "${!LINTER_NAME_TO_DESCRIPTOR[@]}"; do
    printf "%s\n" "${name}"
  done | sort
}

# list_linter_map
#
# @description
# Print all linter → descriptor mappings in "name|descriptor" format,
# sorted alphabetically by linter name.
#
# @stdout sorted "name|descriptor" pairs
# ------------------------------------------------------------------------------

list_linter_map() {
  local name
  for name in "${!LINTER_NAME_TO_DESCRIPTOR[@]}"; do
    printf "%s|%s\n" "${name}" "${LINTER_NAME_TO_DESCRIPTOR[$name]}"
  done | sort
}

# list_descriptors
#
# @description
# Print all known descriptor categories, one per line, sorted alphabetically.
#
# @stdout sorted descriptor names
# ------------------------------------------------------------------------------

list_descriptors() {
  local descriptor
  for descriptor in "${!DESCRIPTOR_TO_LINTERS[@]}"; do
    printf "%s\n" "${descriptor}"
  done | sort
}

# list_by_descriptors
#
# @description
# Print all linter names that belong to the descriptor categories specified
# by DESCRIPTOR_FILTER, one per line, sorted alphabetically.
#
# @stdout sorted linter names for the requested descriptors
# ------------------------------------------------------------------------------

list_by_descriptors() {
  local descriptor name names

  IFS=',' read -ra descriptor_list <<< "${DESCRIPTOR_FILTER}"

  for descriptor in "${descriptor_list[@]}"; do
    descriptor="$(printf "%s" "${descriptor}" | tr '[:lower:]' '[:upper:]')"

    if [[ -n "${DESCRIPTOR_TO_LINTERS[$descriptor]:-}" ]]; then
      IFS=',' read -ra names <<< "${DESCRIPTOR_TO_LINTERS[$descriptor]}"
      for name in "${names[@]}"; do
        printf "%s\n" "${name}"
      done
    else
      log_warn "Unknown descriptor: ${descriptor}"
    fi
  done | sort
}

# ------------------------------------------------------------------------------
# build_docker_envs
#
# @description
# Construct Docker environment variable arguments for MegaLinter.
#
# Populates global DOCKER_ENVS array.
# ------------------------------------------------------------------------------

build_docker_envs() {
  DOCKER_ENVS=()

  # --------------------------------------------------------------------------
  # ENABLE_LINTERS (only if explicitly resolved)
  # --------------------------------------------------------------------------
  if [[ -n "${ENABLE_LINTERS:-}" ]]; then
    DOCKER_ENVS+=("--env" "ENABLE_LINTERS=${ENABLE_LINTERS}")
  fi

  # --------------------------------------------------------------------------
  # Codebase scope
  # --------------------------------------------------------------------------
  if [[ "${CHANGED_ONLY}" == "true" ]]; then
    DOCKER_ENVS+=("--env" "VALIDATE_ALL_CODEBASE=false")
  else
    DOCKER_ENVS+=("--env" "VALIDATE_ALL_CODEBASE=true")
  fi

  # --------------------------------------------------------------------------
  # Auto-fix mode
  # --------------------------------------------------------------------------
  if [[ "${FIX_MODE}" == "true" ]]; then
    DOCKER_ENVS+=("--env" "APPLY_FIXES=all")
  fi

  # --------------------------------------------------------------------------
  # Debug (optional)
  # --------------------------------------------------------------------------
  if [[ "${DEBUG_MODE}" == "true" ]]; then
    DOCKER_ENVS+=("--env" "LOG_LEVEL=DEBUG")
    DOCKER_ENVS+=("--env" "PRINT_ALL_FILES=true")
  fi
}

# ------------------------------------------------------------------------------
# print_docker_envs
#
# @description
# Debug helper to print Docker environment arguments clearly.
# ------------------------------------------------------------------------------

print_docker_envs() {
  log_debug "Docker environment variables:"

  for arg in "${DOCKER_ENVS[@]}"; do
    log_debug "  ${arg}"
  done
}

# ------------------------------------------------------------------------------
# run_megalinter
#
# @description
# Execute MegaLinter using Docker with constructed environment.
# ------------------------------------------------------------------------------

run_megalinter() {
  log_info "Running MegaLinter..."

  if [[ "${DEBUG_MODE}" == "true" ]]; then
    print_docker_envs
  fi

  docker run \
    --rm \
    --interactive \
    --tty \
    --platform "linux/amd64" \
    --volume "${WORKSPACE_DIR}:/github/workspace" \
    --workdir "/github/workspace" \
    --env "GITHUB_WORKSPACE=/github/workspace" \
    --env "GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-unknown/unknown}" \
    --env "GITHUB_REF=refs/heads/main" \
    --env "GITHUB_RUN_ID=local-run" \
    --env "PYTHONWARNINGS=ignore:Possible nested set:FutureWarning,ignore:pkg_resources is deprecated:UserWarning" \
    --env "NPM_CONFIG_AUDIT=false" \
    --env "NPM_CONFIG_FUND=false" \
    --env "NPM_CONFIG_LOGLEVEL=error" \
    "${DOCKER_ENVS[@]}" \
    "${DOCKER_IMAGE}"

  log_info "MegaLinter run complete."
}

# ------------------------------------------------------------------------------
# setup_environment
#
# @description
# Initialize runtime state required for execution.
#
# Responsibilities:
# - Resolve GitHub repository context
# - Initialize linter maps (registry + mapping layer)
# ------------------------------------------------------------------------------

setup_environment() {
  log_debug "Running setup phase"
  log_debug "Script directory: ${SCRIPT_DIR}"

  # --------------------------------------------------------------------------
  # Repository context
  # --------------------------------------------------------------------------
  GITHUB_REPOSITORY="$(get_github_repository)"
  readonly GITHUB_REPOSITORY

  # --------------------------------------------------------------------------
  # Initialize linter registry + maps
  # --------------------------------------------------------------------------
  initialize_linter_maps
}

# ------------------------------------------------------------------------------
# run_workflow
#
# @description
# Execute the main MegaLinter workflow.
# ------------------------------------------------------------------------------

run_workflow() {
  log_info "Starting execution"

  # --------------------------------------------------------------------------
  # Resolve linters → ENABLE_LINTERS
  # --------------------------------------------------------------------------
  ENABLE_LINTERS="$(resolve_linters)"

  # --------------------------------------------------------------------------
  # Build Docker environment
  # --------------------------------------------------------------------------
  build_docker_envs

  log_info "Resolved linters: ${ENABLE_LINTERS:-ALL}"

  if [[ "${DEBUG_MODE}" == "true" ]]; then
    log_debug "ENABLE_LINTERS=${ENABLE_LINTERS:-ALL}"
  fi

  # --------------------------------------------------------------------------
  # Execute MegaLinter
  # --------------------------------------------------------------------------
  run_megalinter

  log_info "Execution complete"
}

# ------------------------------------------------------------------------------
# main
#
# @description
# Entrypoint for CLI execution.
# ------------------------------------------------------------------------------

main() {
  check_dependencies
  parse_arguments "$@"

  # --------------------------------------------------------------------------
  # Cache control (early exit)
  # --------------------------------------------------------------------------
  if [[ "${REFRESH_CACHE_MODE}" == "true" ]]; then
    refresh_linter_cache
    exit "${EXIT_SUCCESS}"
  fi

  # --------------------------------------------------------------------------
  # Setup runtime environment
  # --------------------------------------------------------------------------
  setup_environment

  # --------------------------------------------------------------------------
  # Introspection modes (early exits)
  # --------------------------------------------------------------------------
  if [[ "${LIST_MODE}" == "true" ]]; then
    list_linters
    exit "${EXIT_SUCCESS}"
  fi

  if [[ "${LIST_MAP_MODE}" == "true" ]]; then
    list_linter_map
    exit "${EXIT_SUCCESS}"
  fi

  if [[ "${LIST_DESCRIPTORS_MODE}" == "true" ]]; then
    list_descriptors
    exit "${EXIT_SUCCESS}"
  fi

  if [[ -n "${DESCRIPTOR_FILTER}" && -z "${RAW_LINTER_INPUT}" ]]; then
    list_by_descriptors
    exit "${EXIT_SUCCESS}"
  fi

  # --------------------------------------------------------------------------
  # Run main workflow
  # --------------------------------------------------------------------------
  run_workflow
}

# ------------------------------------------------------------------------------
# Entrypoint Guard
# ------------------------------------------------------------------------------

if [[ "${IS_EXECUTED_DIRECTLY}" == "true" ]]; then
  main "$@"
fi