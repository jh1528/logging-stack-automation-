#!/usr/bin/env bash
#
# install-promtail.sh
#
# Installs and configures Promtail for the logging stack project.
#
# Purpose:
#  - Run preflight health checks
#  - Verify required commands are available
#  - Install required runtime dependencies
#  - Download the official Promtail release archive
#  - Prepare Promtail configuration and data directories
#  - Install the Promtail binary
#  - Write the Promtail configuration
#  - Register Promtail as a systemd service
#  - Start and enable the Promtail service
#
# Design:
#  - Keep installation responsibilities separate from validation
#  - Use shared library helpers where possible
#  - Fail fast on critical setup errors
#  - Keep functions small, focused, and well documented
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Debian/Ubuntu package manager is available
#  - Required library files are present and sourceable
#
# Postconditions:
#  - Promtail binary is installed
#  - /etc/promtail exists
#  - /var/lib/promtail exists
#  - Promtail configuration is written
#  - promtail.service exists
#  - promtail.service is started
#  - promtail.service is enabled at boot
#
# Notes:
#  - This script installs Promtail only
#  - Validation belongs in scripts/validate-promtail.sh
#  - Promtail reads rsyslog-written log files from /var/log/remote
#
# Environment Variables:
#  - PROMTAIL_VERSION
#      Promtail release version to install
#      Default: 2.9.3
#
#  - PROMTAIL_INSTALL_DIR
#      Directory used for the Promtail binary
#      Default: /usr/local/bin
#
#  - PROMTAIL_CONFIG_DIR
#      Directory used for Promtail configuration
#      Default: /etc/promtail
#
#  - PROMTAIL_DATA_DIR
#      Directory used for Promtail runtime data
#      Default: /var/lib/promtail
#
#  - PROMTAIL_HTTP_PORT
#      HTTP listen port for Promtail
#      Default: 9080
#
#  - LOKI_PUSH_URL
#      Loki push API endpoint used by Promtail
#      Default: http://127.0.0.1:3100/loki/api/v1/push
#
# Usage:
#  sudo ./scripts/install-promtail.sh
#
# Returns:
#  - 0 if installation succeeds
#  - 1 is not used directly by this script as a final exit state
#  - 2 if a critical installation step fails
#

set -u

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
#   sudo ./scripts/install-promtail.sh
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
# Constants
# ------------------------------------------------------------------------------

readonly PROMTAIL_VERSION="${PROMTAIL_VERSION:-2.9.3}"

readonly PROMTAIL_INSTALL_DIR="${PROMTAIL_INSTALL_DIR:-/usr/local/bin}"
readonly PROMTAIL_CONFIG_DIR="${PROMTAIL_CONFIG_DIR:-/etc/promtail}"
readonly PROMTAIL_DATA_DIR="${PROMTAIL_DATA_DIR:-/var/lib/promtail}"

readonly PROMTAIL_BINARY_NAME="promtail"
readonly PROMTAIL_BINARY_PATH="${PROMTAIL_INSTALL_DIR}/${PROMTAIL_BINARY_NAME}"
readonly PROMTAIL_CONFIG_PATH="${PROMTAIL_CONFIG_DIR}/config.yml"

readonly PROMTAIL_HTTP_PORT="${PROMTAIL_HTTP_PORT:-9080}"
readonly LOKI_PUSH_URL="${LOKI_PUSH_URL:-http://127.0.0.1:3100/loki/api/v1/push}"

readonly PROMTAIL_RELEASE_FILE="promtail-linux-amd64.zip"
readonly PROMTAIL_DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/${PROMTAIL_RELEASE_FILE}"

readonly TMP_DIR="/tmp/promtail-install"
readonly TMP_ARCHIVE_PATH="${TMP_DIR}/${PROMTAIL_RELEASE_FILE}"
readonly TMP_EXTRACT_DIR="${TMP_DIR}/extract"

readonly PROMTAIL_USER="root"
readonly PROMTAIL_GROUP="root"

# Preflight thresholds
readonly ROOT_DISK_WARN=80
readonly ROOT_DISK_FAIL=90
readonly MEMORY_WARN=80
readonly MEMORY_FAIL=90
readonly LOAD_WARN=2.00
readonly LOAD_FAIL=4.00

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

    pass "Running with root privileges"
    return 0
}

#
# preflight_checks
# Description:
#  - Runs installation safety and dependency checks before package install.
#  - Validates root access, system health thresholds, and required commands.
#
# Preconditions:
#  - Shared health and system helper libraries are sourced
#
# Postconditions:
#  - Required install preconditions are validated
#
# Returns:
#  - 0 if preflight checks complete successfully
#  - 2 if a critical preflight step fails
#
preflight_checks() {
    step "Phase 1 — Preflight"

    require_root || return 2

    check_disk "/" "${ROOT_DISK_WARN}" "${ROOT_DISK_FAIL}"
    case $? in
        0|1) ;;
        2) return 2 ;;
    esac

    check_memory "${MEMORY_WARN}" "${MEMORY_FAIL}"
    case $? in
        0|1) ;;
        2) return 2 ;;
    esac

    check_cpu_load "${LOAD_WARN}" "${LOAD_FAIL}"
    case $? in
        0|1) ;;
        2) return 2 ;;
    esac

    command_exists apt-get || return 2
    command_exists curl || return 2
    command_exists unzip || return 2
    command_exists install || return 2
    command_exists systemctl || return 2
    command_exists mkdir || return 2
    command_exists chown || return 2
    command_exists chmod || return 2

    pass "Preflight checks completed"
    return 0
}

#
# install_runtime_dependencies
# Description:
#  - Installs the runtime dependencies required to download and extract Promtail.
#
# Preconditions:
#  - Preflight checks have completed successfully
#  - APT helper library is sourced
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
# prepare_temp_workspace
# Description:
#  - Creates the temporary workspace used during Promtail archive download
#    and extraction.
#
# Preconditions:
#  - Filesystem helper library is sourced
#
# Postconditions:
#  - Temporary working directories exist
#
# Returns:
#  - 0 if temporary workspace preparation succeeds
#  - 2 if temporary workspace preparation fails
#
prepare_temp_workspace() {
    ensure_directory "${TMP_DIR}" || return 2
    ensure_directory "${TMP_EXTRACT_DIR}" || return 2
    return 0
}

#
# download_promtail_archive
# Description:
#  - Downloads the requested Promtail release archive into the temporary workspace.
#
# Preconditions:
#  - Runtime dependencies are installed
#  - Temporary workspace is writable
#
# Postconditions:
#  - Promtail release archive exists at the temporary archive path
#
# Returns:
#  - 0 if archive download succeeds
#  - 2 if archive download fails
#
download_promtail_archive() {
    step "Phase 3 — Download Promtail release archive"

    prepare_temp_workspace || return 2

    if [[ -f "${TMP_ARCHIVE_PATH}" ]]; then
        info "Removing existing temporary archive"
        rm -f "${TMP_ARCHIVE_PATH}" || return 2
    fi

    if download_file "${PROMTAIL_DOWNLOAD_URL}" "${TMP_ARCHIVE_PATH}"; then
        pass "Promtail archive downloaded: ${TMP_ARCHIVE_PATH}"
        return 0
    fi

    fail "Failed to download Promtail archive from: ${PROMTAIL_DOWNLOAD_URL}"
    return 2
}

#
# extract_promtail_archive
# Description:
#  - Extracts the downloaded Promtail archive into the temporary extract directory.
#
# Preconditions:
#  - Promtail archive has already been downloaded
#
# Postconditions:
#  - Extracted Promtail files exist in the temporary extract directory
#
# Returns:
#  - 0 if archive extraction succeeds
#  - 2 if archive extraction fails
#
extract_promtail_archive() {
    step "Phase 4 — Extract Promtail release archive"

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
# install_promtail_binary
# Description:
#  - Installs the Promtail binary into the configured install directory.
#
# Preconditions:
#  - Promtail archive has already been extracted
#
# Postconditions:
#  - Promtail binary exists at the configured binary path
#
# Returns:
#  - 0 if binary installation succeeds
#  - 2 if binary installation fails
#
install_promtail_binary() {
    step "Phase 5 — Install Promtail binary"

    local extracted_binary_path="${TMP_EXTRACT_DIR}/promtail-linux-amd64"

    if [[ ! -f "${extracted_binary_path}" ]]; then
        fail "Expected binary not found after extraction: ${extracted_binary_path}"
        return 2
    fi

    if install -m 0755 "${extracted_binary_path}" "${PROMTAIL_BINARY_PATH}" >/dev/null 2>&1; then
        pass "Promtail binary installed: ${PROMTAIL_BINARY_PATH}"
        return 0
    fi

    fail "Failed to install Promtail binary: ${PROMTAIL_BINARY_PATH}"
    return 2
}

#
# prepare_promtail_directories
# Description:
#  - Creates the directories required for Promtail configuration and runtime data.
#
# Preconditions:
#  - Filesystem helper library is sourced
#
# Postconditions:
#  - /etc/promtail exists
#  - /var/lib/promtail exists
#
# Returns:
#  - 0 if directory preparation succeeds
#  - 2 if directory preparation fails
#
prepare_promtail_directories() {
    step "Phase 6 — Prepare Promtail directories"

    ensure_directory "${PROMTAIL_CONFIG_DIR}" || return 2
    ensure_directory "${PROMTAIL_DATA_DIR}" || return 2

    if chown -R "${PROMTAIL_USER}:${PROMTAIL_GROUP}" "${PROMTAIL_CONFIG_DIR}" "${PROMTAIL_DATA_DIR}" >/dev/null 2>&1; then
        pass "Ownership applied to Promtail directories"
        return 0
    fi

    fail "Failed to apply ownership to Promtail directories"
    return 2
}

#
# write_promtail_config
# Description:
#  - Writes the Promtail configuration used to tail rsyslog-managed remote log files
#    and push them into Loki.
#
# Preconditions:
#  - Promtail directories already exist
#  - Config directory is writable
#
# Postconditions:
#  - Promtail configuration file exists
#
# Returns:
#  - 0 if configuration is written successfully
#  - 2 if configuration writing fails
#
write_promtail_config() {
    step "Phase 7 — Write Promtail configuration"

    write_file "${PROMTAIL_CONFIG_PATH}" <<EOF
server:
  http_listen_port: ${PROMTAIL_HTTP_PORT}

positions:
  filename: ${PROMTAIL_DATA_DIR}/positions.yaml

clients:
  - url: ${LOKI_PUSH_URL}

scrape_configs:
  - job_name: rsyslog
    static_configs:
      - targets:
          - localhost
        labels:
          job: rsyslog
          __path__: /var/log/remote/*/*.log
EOF
    if [[ $? -ne 0 ]]; then
        fail "Failed to write Promtail configuration"
        return 2
    fi

    pass "Promtail configuration written"
    return 0
}

#
# write_promtail_service
# Description:
#  - Writes the Promtail systemd unit file and reloads systemd.
#
# Preconditions:
#  - Promtail binary and configuration file already exist
#  - Systemd helper library is sourced
#
# Postconditions:
#  - promtail.service unit file exists
#  - systemd daemon is reloaded
#
# Returns:
#  - 0 if the systemd unit is written successfully
#  - 2 if systemd unit creation fails
#
write_promtail_service() {
    step "Phase 8 — Write Promtail systemd service"

    write_systemd_unit "promtail" <<EOF
[Unit]
Description=Promtail
After=network.target

[Service]
Type=simple
User=${PROMTAIL_USER}
Group=${PROMTAIL_GROUP}
ExecStart=${PROMTAIL_BINARY_PATH} -config.file=${PROMTAIL_CONFIG_PATH}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    if [[ $? -ne 0 ]]; then
        fail "Failed to write Promtail systemd unit"
        return 2
    fi

    reload_systemd || return 2
    pass "Promtail systemd service written"
    return 0
}

#
# prepare_promtail_service
# Description:
#  - Verifies the Promtail service exists.
#  - Starts the Promtail service.
#  - Enables the Promtail service at boot.
#  - Confirms the Promtail service is running.
#
# Preconditions:
#  - promtail.service has already been written and reloaded into systemd
#
# Postconditions:
#  - promtail.service exists
#  - promtail.service is started
#  - promtail.service is enabled
#  - promtail.service is running
#
# Returns:
#  - 0 if service preparation succeeds
#  - 2 if a critical service preparation step fails
#
prepare_promtail_service() {
    step "Phase 9 — Prepare Promtail service"

    service_exists promtail || return 2
    enable_service promtail || return 2
    start_service promtail || return 2
    service_running promtail || return 2

    pass "Promtail service preparation completed"
    return 0
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
    step "Phase 10 — Clean temporary installation files"

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
# print_next_steps
# Description:
#  - Prints a concise install summary and directs the operator to the
#    next validation stage.
#
# Preconditions:
#  - Installation phases completed successfully
#
# Postconditions:
#  - Next-step guidance is printed to stdout
#
# Returns:
#  - 0
#
print_next_steps() {
    step "Next Step"

    info "Using shared library path: ${LIB_DIR}"
    info "Version: ${PROMTAIL_VERSION}"
    info "Binary: ${PROMTAIL_BINARY_PATH}"
    info "Config: ${PROMTAIL_CONFIG_PATH}"
    info "Data directory: ${PROMTAIL_DATA_DIR}"
    info "Service: promtail.service"
    info "HTTP endpoint: http://127.0.0.1:${PROMTAIL_HTTP_PORT}"
    info "Run the next stage script: scripts/validate-promtail.sh"

    pass "Promtail installation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Install Promtail"

    preflight_checks || die "Preflight checks failed"
    install_runtime_dependencies || die "Runtime dependency installation failed"
    download_promtail_archive || die "Promtail archive download failed"
    extract_promtail_archive || die "Promtail archive extraction failed"
    install_promtail_binary || die "Promtail binary installation failed"
    prepare_promtail_directories || die "Promtail directory preparation failed"
    write_promtail_config || die "Promtail configuration writing failed"
    write_promtail_service || die "Promtail systemd service creation failed"
    prepare_promtail_service || die "Promtail service preparation failed"

    cleanup_temp_workspace
    print_next_steps
    pass "install-promtail.sh completed successfully"
    return 0
}

main "$@"
