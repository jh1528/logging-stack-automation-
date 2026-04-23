#!/usr/bin/env bash
#
# install-loki.sh
#
# Installs Grafana Loki as a single-binary local service.
#
# Purpose:
#  - Run install preflight checks
#  - Install required runtime dependencies
#  - Download the official Loki release archive
#  - Create the Loki service account
#  - Prepare Loki directories
#  - Install the Loki binary
#  - Write the Loki configuration
#  - Register Loki as a systemd service
#  - Start and enable the Loki service
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep installation responsibilities separate from validation responsibilities
#  - Use infra-bash-lib helpers for output, health checks, filesystem, and service control
#  - Fail fast on critical installation steps
#
# Notes:
#  - This script installs Loki only
#  - It does not install Grafana or Promtail
#  - It does not validate end-to-end ingestion
#  - Validation should be handled by validate-loki.sh
#
# Environment Variables:
#  - LOKI_VERSION
#      Loki release version to install
#      Default: 3.7.1
#
#  - LOKI_ARCH
#      Loki architecture suffix used in release artifacts
#      Default: amd64
#
#  - LOKI_USER
#      Service account used to run Loki
#      Default: loki
#
#  - LOKI_GROUP
#      Service group used to run Loki
#      Default: loki
#
#  - LOKI_INSTALL_DIR
#      Directory used for the Loki binary
#      Default: /usr/local/bin
#
#  - LOKI_CONFIG_DIR
#      Directory used for Loki configuration
#      Default: /etc/loki
#
#  - LOKI_DATA_DIR
#      Directory used for Loki local storage
#      Default: /var/lib/loki
#
#  - LOKI_HTTP_PORT
#      HTTP listen port for Loki
#      Default: 3100
#
# Usage:
#  sudo ./scripts/install-loki.sh
#
# Returns:
#  - 0 if installation succeeds
#  - 2 if a critical installation step fails
#

set -u

# ------------------------------------------------------------------------------
# Path discovery and shared library loading
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ------------------------------------------------------------------------------
# External reusable library location
# ------------------------------------------------------------------------------
# Priority:
#   1. LIB_DIR environment variable, if exported by caller
#   2. Default shared reusable library path
#
# Example:
#   export LIB_DIR="/home/graylog/infra-bash-lib"
#   sudo ./scripts/install-loki.sh
#
readonly DEFAULT_LIB_DIR="/home/graylog/infra-bash-lib"
readonly LIB_DIR="${LIB_DIR:-${DEFAULT_LIB_DIR}}"

COMMON_LIB="${LIB_DIR}/common.sh"
APT_LIB="${LIB_DIR}/apt.sh"
SERVICE_LIB="${LIB_DIR}/service.sh"
HEALTH_LIB="${LIB_DIR}/health.sh"
SYSTEM_LIB="${LIB_DIR}/system.sh"

# ------------------------------------------------------------------------------
# Library loading
# ------------------------------------------------------------------------------

[[ -f "${COMMON_LIB}"  ]] || { echo "[FAIL] Missing library: ${COMMON_LIB}"; exit 2; }
[[ -f "${APT_LIB}"     ]] || { echo "[FAIL] Missing library: ${APT_LIB}"; exit 2; }
[[ -f "${SERVICE_LIB}" ]] || { echo "[FAIL] Missing library: ${SERVICE_LIB}"; exit 2; }
[[ -f "${HEALTH_LIB}"  ]] || { echo "[FAIL] Missing library: ${HEALTH_LIB}"; exit 2; }
[[ -f "${SYSTEM_LIB}"  ]] || { echo "[FAIL] Missing library: ${SYSTEM_LIB}"; exit 2; }

# shellcheck source=/dev/null
source "${COMMON_LIB}"
# shellcheck source=/dev/null
source "${APT_LIB}"
# shellcheck source=/dev/null
source "${SERVICE_LIB}"
# shellcheck source=/dev/null
source "${HEALTH_LIB}"
# shellcheck source=/dev/null
source "${SYSTEM_LIB}"

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly LOKI_VERSION="${LOKI_VERSION:-3.7.1}"
readonly LOKI_ARCH="${LOKI_ARCH:-amd64}"

readonly LOKI_USER="${LOKI_USER:-loki}"
readonly LOKI_GROUP="${LOKI_GROUP:-loki}"

readonly LOKI_INSTALL_DIR="${LOKI_INSTALL_DIR:-/usr/local/bin}"
readonly LOKI_CONFIG_DIR="${LOKI_CONFIG_DIR:-/etc/loki}"
readonly LOKI_DATA_DIR="${LOKI_DATA_DIR:-/var/lib/loki}"

readonly LOKI_BINARY_NAME="loki"
readonly LOKI_BINARY_PATH="${LOKI_INSTALL_DIR}/${LOKI_BINARY_NAME}"
readonly LOKI_CONFIG_PATH="${LOKI_CONFIG_DIR}/config.yml"

readonly LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"

readonly LOKI_RELEASE_FILE="loki-linux-${LOKI_ARCH}.zip"
readonly LOKI_DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/${LOKI_RELEASE_FILE}"

readonly TMP_DIR="/tmp/loki-install"
readonly TMP_ARCHIVE_PATH="${TMP_DIR}/${LOKI_RELEASE_FILE}"
readonly TMP_EXTRACT_DIR="${TMP_DIR}/extract"

# Preflight thresholds
readonly ROOT_FREE_GB_WARN=5
readonly ROOT_FREE_GB_FAIL=2
readonly MEMORY_TOTAL_GB_WARN=2
readonly MEMORY_TOTAL_GB_FAIL=1
readonly LOAD_WARN=4.00
readonly LOAD_FAIL=8.00

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

#
# require_root
# Description:
#  - Verifies the script is running with root privileges.
#
# Preconditions:
#  - None
#
# Postconditions:
#  - A formatted PASS or FAIL message is printed
#
# Returns:
#  - 0 if running as root
#  - 2 if not running as root
#
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "This script must be run as root"
        return 2
    fi

    pass "Running as root"
    return 0
}

#
# ensure_group_exists
# Description:
#  - Ensures the Loki system group exists.
#
# Preconditions:
#  - Accepts one argument:
#    1. group name
#
# Postconditions:
#  - The requested group exists
#
# Returns:
#  - 0 if the group exists or was created
#  - 2 if the group name is invalid or creation fails
#
ensure_group_exists() {
    local group_name="$1"

    if [[ -z "${group_name}" ]]; then
        fail "Usage: ensure_group_exists <group_name>"
        return 2
    fi

    if getent group "${group_name}" >/dev/null 2>&1; then
        pass "Group already exists: ${group_name}"
        return 0
    fi

    if groupadd --system "${group_name}" >/dev/null 2>&1; then
        pass "Group created: ${group_name}"
        return 0
    fi

    fail "Failed to create group: ${group_name}"
    return 2
}

#
# ensure_user_exists
# Description:
#  - Ensures the Loki system user exists and is assigned to the Loki group.
#
# Preconditions:
#  - Accepts two arguments:
#    1. user name
#    2. group name
#
# Postconditions:
#  - The requested user exists
#  - The user is associated with the provided group
#
# Returns:
#  - 0 if the user exists or was created
#  - 2 if input is invalid or user creation fails
#
ensure_user_exists() {
    local user_name="$1"
    local group_name="$2"

    if [[ -z "${user_name}" || -z "${group_name}" ]]; then
        fail "Usage: ensure_user_exists <user_name> <group_name>"
        return 2
    fi

    if id "${user_name}" >/dev/null 2>&1; then
        pass "User already exists: ${user_name}"
        return 0
    fi

    if useradd \
        --system \
        --gid "${group_name}" \
        --home-dir "${LOKI_DATA_DIR}" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "${user_name}" >/dev/null 2>&1; then
        pass "User created: ${user_name}"
        return 0
    fi

    fail "Failed to create user: ${user_name}"
    return 2
}

#
# prepare_temp_workspace
# Description:
#  - Creates the temporary workspace used during archive download and extraction.
#
# Preconditions:
#  - Filesystem helper library is sourced
#
# Postconditions:
#  - Temporary working directories exist
#
# Returns:
#  - 0 if the temporary workspace is ready
#  - 2 if a directory preparation step fails
#
prepare_temp_workspace() {
    ensure_directory "${TMP_DIR}" || return 2
    ensure_directory "${TMP_EXTRACT_DIR}" || return 2
    return 0
}

#
# install_runtime_dependencies
# Description:
#  - Installs runtime dependencies required to download and extract Loki.
#
# Preconditions:
#  - APT helper library is sourced
#  - Script is running with sufficient privileges
#
# Postconditions:
#  - curl is installed
#  - unzip is installed
#
# Returns:
#  - 0 if dependency installation succeeds
#  - 2 if dependency installation fails
#
install_runtime_dependencies() {
    step "Phase 2 — Install runtime dependencies"

    apt_update || return 2
    apt_install curl unzip || return 2

    pass "Runtime dependency installation completed"
    return 0
}

#
# run_preflight_checks
# Description:
#  - Runs installation safety checks before downloading and configuring Loki.
#  - Validates free disk space, total system memory, and current CPU load.
#
# Preconditions:
#  - Shared health helper library is sourced
#
# Postconditions:
#  - Preflight thresholds are checked
#
# Returns:
#  - 0 if preflight checks complete successfully
#  - 2 if a critical preflight step fails
#
run_preflight_checks() {
    step "Phase 1 — Preflight"

    info "Checking free disk space on /"
    check_disk_free_gb / "${ROOT_FREE_GB_WARN}" "${ROOT_FREE_GB_FAIL}"
    case $? in
        0) ;;
        1) warn "Disk space is below the recommended level, but installation may continue" ;;
        2) die "Disk free-space check failed or minimum capacity is not met" ;;
    esac

    info "Checking total system memory"
    check_memory_total_gb "${MEMORY_TOTAL_GB_WARN}" "${MEMORY_TOTAL_GB_FAIL}"
    case $? in
        0) ;;
        1) warn "System memory is below the recommended level, but installation may continue" ;;
        2) die "System memory is below the minimum required level or could not be checked" ;;
    esac

    info "Checking current CPU load"
    check_cpu_load "${LOAD_WARN}" "${LOAD_FAIL}"
    case $? in
        0) ;;
        1) warn "CPU load is elevated; installation may continue" ;;
        2) die "CPU load is too high or could not be checked" ;;
    esac

    pass "Preflight checks completed"
    return 0
}

#
# prepare_directories
# Description:
#  - Creates all directories required for Loki configuration and local storage.
#  - Applies ownership to Loki-managed paths.
#
# Preconditions:
#  - Loki service account exists
#  - Filesystem helper library is sourced
#
# Postconditions:
#  - Install, config, and data directories exist
#  - Loki directory ownership is applied
#
# Returns:
#  - 0 if directory preparation succeeds
#  - 2 if a critical directory preparation step fails
#
prepare_directories() {
    step "Phase 4 — Prepare Loki directories"

    ensure_directory "${LOKI_INSTALL_DIR}" || return 2
    ensure_directory "${LOKI_CONFIG_DIR}" || return 2
    ensure_directory "${LOKI_DATA_DIR}" || return 2
    ensure_directory "${LOKI_DATA_DIR}/chunks" || return 2
    ensure_directory "${LOKI_DATA_DIR}/rules" || return 2
    ensure_directory "${LOKI_DATA_DIR}/index" || return 2
    ensure_directory "${LOKI_DATA_DIR}/index_cache" || return 2
    ensure_directory "${LOKI_DATA_DIR}/compactor" || return 2

    if chown -R "${LOKI_USER}:${LOKI_GROUP}" "${LOKI_CONFIG_DIR}" "${LOKI_DATA_DIR}" >/dev/null 2>&1; then
        pass "Ownership applied to Loki directories"
        return 0
    fi

    fail "Failed to apply ownership to Loki directories"
    return 2
}

#
# download_loki_archive
# Description:
#  - Downloads the requested Loki release archive into the temporary workspace.
#
# Preconditions:
#  - Temporary workspace is writable
#  - Runtime dependencies are installed
#
# Postconditions:
#  - Loki release archive exists at the temporary archive path
#
# Returns:
#  - 0 if archive download succeeds
#  - 2 if archive download fails
#
download_loki_archive() {
    step "Phase 5 — Download Loki release archive"

    prepare_temp_workspace || return 2

    if [[ -f "${TMP_ARCHIVE_PATH}" ]]; then
        info "Removing existing temporary archive"
        rm -f "${TMP_ARCHIVE_PATH}" || return 2
    fi

    if download_file "${LOKI_DOWNLOAD_URL}" "${TMP_ARCHIVE_PATH}"; then
        pass "Loki archive downloaded: ${TMP_ARCHIVE_PATH}"
        return 0
    fi

    fail "Failed to download Loki archive from: ${LOKI_DOWNLOAD_URL}"
    return 2
}

#
# extract_loki_archive
# Description:
#  - Extracts the downloaded Loki archive into the temporary extract directory.
#
# Preconditions:
#  - Loki archive has already been downloaded
#
# Postconditions:
#  - Extracted Loki files exist in the temporary extract directory
#
# Returns:
#  - 0 if archive extraction succeeds
#  - 2 if archive extraction fails
#
extract_loki_archive() {
    step "Phase 6 — Extract Loki release archive"

    if [[ ! -f "${TMP_ARCHIVE_PATH}" ]]; then
        fail "Cannot extract missing archive: ${TMP_ARCHIVE_PATH}"
        return 2
    fi

    rm -rf "${TMP_EXTRACT_DIR}" || return 2
    ensure_directory "${TMP_EXTRACT_DIR}" || return 2

    if unzip -o "${TMP_ARCHIVE_PATH}" -d "${TMP_EXTRACT_DIR}" >/dev/null 2>&1; then
        pass "Archive extracted: ${TMP_ARCHIVE_PATH}"
        return 0
    fi

    fail "Failed to extract archive: ${TMP_ARCHIVE_PATH}"
    return 2
}

#
# install_loki_binary
# Description:
#  - Installs the Loki binary into the configured install directory.
#
# Preconditions:
#  - Loki archive has already been extracted
#
# Postconditions:
#  - Loki binary exists at the configured binary path
#
# Returns:
#  - 0 if binary installation succeeds
#  - 2 if binary installation fails
#
install_loki_binary() {
    step "Phase 7 — Install Loki binary"

    local extracted_binary_path="${TMP_EXTRACT_DIR}/loki-linux-${LOKI_ARCH}"

    if [[ ! -f "${extracted_binary_path}" ]]; then
        fail "Expected binary not found after extraction: ${extracted_binary_path}"
        return 2
    fi

    if install -m 0755 "${extracted_binary_path}" "${LOKI_BINARY_PATH}" >/dev/null 2>&1; then
        pass "Loki binary installed: ${LOKI_BINARY_PATH}"
        return 0
    fi

    fail "Failed to install Loki binary: ${LOKI_BINARY_PATH}"
    return 2
}

#
# write_loki_config
# Description:
#  - Writes a minimal single-binary Loki configuration for local filesystem storage.
#  - Configures a single-node in-memory ring suitable for lab use.
#
# Preconditions:
#  - Loki directories already exist
#  - Config directory is writable
#
# Postconditions:
#  - Loki configuration file exists
#  - Ownership is applied to the Loki config file
#
# Returns:
#  - 0 if configuration is written successfully
#  - 2 if configuration writing fails
#
write_loki_config() {
    step "Phase 8 — Write Loki configuration"

    write_file "${LOKI_CONFIG_PATH}" <<EOF
# config.yml
#
# Minimal local Loki configuration for single-binary deployment.
#
# Purpose:
#  - Run Loki locally for the logging stack project
#  - Store data on the local filesystem
#  - Keep configuration simple and suitable for staged validation
#
# Notes:
#  - Authentication is disabled for lab simplicity
#  - Local filesystem storage is used
#  - Replication factor is set to 1 because this is a single-node deployment

auth_enabled: false

server:
  http_listen_address: 0.0.0.0
  http_listen_port: ${LOKI_HTTP_PORT}
  grpc_listen_port: 9096
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: ${LOKI_DATA_DIR}
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
  storage:
    filesystem:
      chunks_directory: ${LOKI_DATA_DIR}/chunks
      rules_directory: ${LOKI_DATA_DIR}/rules

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: ${LOKI_DATA_DIR}/index
    cache_location: ${LOKI_DATA_DIR}/index_cache

limits_config:
  allow_structured_metadata: false
  volume_enabled: true
  retention_period: 168h

compactor:
  working_directory: ${LOKI_DATA_DIR}/compactor

analytics:
  reporting_enabled: false
EOF

    if [[ $? -ne 0 ]]; then
        fail "Failed to write Loki configuration"
        return 2
    fi

    if chown "${LOKI_USER}:${LOKI_GROUP}" "${LOKI_CONFIG_PATH}" >/dev/null 2>&1; then
        pass "Ownership applied to Loki configuration"
        return 0
    fi

    fail "Failed to apply ownership to Loki configuration"
    return 2
}

#
# write_loki_service
# Description:
#  - Writes the Loki systemd unit file and reloads systemd.
#
# Preconditions:
#  - Loki binary and configuration file already exist
#  - Systemd helper library is sourced
#
# Postconditions:
#  - loki.service unit file exists
#  - systemd daemon is reloaded
#
# Returns:
#  - 0 if the systemd unit is written successfully
#  - 2 if systemd unit creation fails
#
write_loki_service() {
    step "Phase 9 — Write Loki systemd service"

    write_systemd_unit "loki" <<EOF
[Unit]
Description=Grafana Loki
Documentation=https://grafana.com/oss/loki/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LOKI_USER}
Group=${LOKI_GROUP}
WorkingDirectory=${LOKI_DATA_DIR}
ExecStart=${LOKI_BINARY_PATH} -config.file=${LOKI_CONFIG_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    if [[ $? -ne 0 ]]; then
        fail "Failed to write Loki systemd unit"
        return 2
    fi

    reload_systemd || return 2
    pass "Loki systemd service written"
    return 0
}

#
# start_and_enable_loki
# Description:
#  - Enables the Loki service at boot.
#  - Starts the Loki service immediately.
#  - Confirms the Loki service reaches the running state.
#
# Preconditions:
#  - loki.service has already been written and reloaded into systemd
#
# Postconditions:
#  - Loki is enabled
#  - Loki is started
#  - Loki is running
#
# Returns:
#  - 0 if service startup succeeds
#  - 2 if service startup fails
#
start_and_enable_loki() {
    step "Phase 10 — Start and enable Loki service"

    enable_service loki || return 2
    start_service loki || return 2

    if service_running loki; then
        pass "Loki service startup completed"
        return 0
    fi

    fail "Loki service did not reach running state"
    return 2
}

#
# cleanup_temp_workspace
# Description:
#  - Removes temporary installation files created during archive download and extraction.
#
# Preconditions:
#  - None
#
# Postconditions:
#  - Temporary installation workspace is removed when present
#
# Returns:
#  - 0 if cleanup succeeds or is not needed
#  - 1 if cleanup could not be completed
#
cleanup_temp_workspace() {
    step "Phase 11 — Clean temporary installation files"

    if [[ -d "${TMP_DIR}" ]]; then
        if rm -rf "${TMP_DIR}" >/dev/null 2>&1; then
            pass "Temporary files removed: ${TMP_DIR}"
            return 0
        fi

        warn "Failed to remove temporary files: ${TMP_DIR}"
        return 1
    fi

    pass "No temporary files needed cleanup"
    return 0
}

#
# print_install_summary
# Description:
#  - Prints a concise summary of the Loki installation result.
#
# Preconditions:
#  - Installation phases completed successfully
#
# Postconditions:
#  - Install summary is printed to stdout
#
# Returns:
#  - 0
#
print_install_summary() {
    step "Next Step"

    info "Version: ${LOKI_VERSION}"
    info "Binary: ${LOKI_BINARY_PATH}"
    info "Config: ${LOKI_CONFIG_PATH}"
    info "Data directory: ${LOKI_DATA_DIR}"
    info "Service: loki.service"
    info "HTTP endpoint: http://localhost:${LOKI_HTTP_PORT}"
    info "Run the next stage script: scripts/validate-loki.sh"

    pass "Loki installation completed"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Install Loki"

    require_root || die "Root privilege check failed"
    run_preflight_checks || die "Preflight checks failed"
    install_runtime_dependencies || die "Failed to install required runtime dependencies"

    step "Phase 3 — Create Loki service account"
    ensure_group_exists "${LOKI_GROUP}" || die "Failed to prepare Loki group"
    ensure_user_exists "${LOKI_USER}" "${LOKI_GROUP}" || die "Failed to prepare Loki user"

    prepare_directories || die "Failed to prepare Loki directories"
    download_loki_archive || die "Failed to download Loki release archive"
    extract_loki_archive || die "Failed to extract Loki release archive"
    install_loki_binary || die "Failed to install Loki binary"
    write_loki_config || die "Failed to write Loki configuration"
    write_loki_service || die "Failed to write Loki systemd service"
    start_and_enable_loki || die "Failed to start or enable Loki service"

    cleanup_temp_workspace
    print_install_summary
    pass "install-loki.sh completed successfully"
    return 0
}

main "$@"
