#!/usr/bin/env bash
#
# install-rsyslog.sh
#
# Installs and prepares rsyslog for centralized log collection.
#
# Purpose:
#  - Run preflight health checks
#  - Verify required commands are available
#  - Install rsyslog
#  - Prepare the remote log storage directory
#  - Ensure the rsyslog service exists
#  - Start the rsyslog service
#  - Enable the rsyslog service at boot
#
# Design:
#  - Keep installation separate from deep validation
#  - Use shared library helpers where possible
#  - Fail fast on critical errors
#  - Reserve listener, config-load, and remote log-write verification
#    for validate-rsyslog.sh
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Debian/Ubuntu package manager is available
#  - Required library files are present and sourceable
#
# Postconditions:
#  - rsyslog package is installed
#  - /var/log/remote exists
#  - /var/log/remote has ownership and permissions suitable for rsyslog
#  - rsyslog service exists
#  - rsyslog service is started
#  - rsyslog service is enabled at boot
#
# Returns:
#  - 0 if installation succeeds
#  - 1 is not used directly by this script as a final exit state
#  - 2 if a critical install step fails
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
#   sudo ./scripts/install-rsyslog.sh
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

readonly RSYSLOG_PACKAGE="rsyslog"
readonly RSYSLOG_SERVICE="rsyslog"
readonly REMOTE_LOG_DIR="/var/log/remote"
readonly REMOTE_LOG_OWNER="syslog:adm"
readonly REMOTE_LOG_MODE="0755"

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
    command_exists dpkg-query || return 2
    command_exists systemctl || return 2
    command_exists mkdir || return 2
    command_exists chown || return 2
    command_exists chmod || return 2

    pass "Preflight checks completed"
    return 0
}

#
# install_rsyslog_package
# Description:
#  - Installs the rsyslog package using shared APT helpers.
#
# Preconditions:
#  - Preflight checks have completed successfully
#  - APT helper library is sourced
#
# Postconditions:
#  - rsyslog package is installed
#
# Returns:
#  - 0 if package installation succeeds
#  - 2 if package installation fails
#
install_rsyslog_package() {
    step "Phase 2 — Install rsyslog"

    apt_update || return 2
    apt_install "${RSYSLOG_PACKAGE}" || return 2

    pass "rsyslog package installation completed"
    return 0
}

#
# prepare_remote_log_directory
# Description:
#  - Creates the remote log root directory used by centralized logging.
#  - Applies ownership and permissions required for rsyslog to create
#    dynamic hostname/program log paths beneath /var/log/remote.
#
# Preconditions:
#  - rsyslog package is installed
#  - Script is running with root privileges
#
# Postconditions:
#  - /var/log/remote exists
#  - /var/log/remote ownership is set for rsyslog writes
#  - /var/log/remote permissions are set
#
# Returns:
#  - 0 if directory preparation succeeds
#  - 2 if a critical directory preparation step fails
#
prepare_remote_log_directory() {
    step "Phase 3 — Prepare remote log directory"

    ensure_directory "${REMOTE_LOG_DIR}" || return 2

    info "Applying ownership to ${REMOTE_LOG_DIR}"
    if chown -R "${REMOTE_LOG_OWNER}" "${REMOTE_LOG_DIR}" >/dev/null 2>&1; then
        pass "Ownership applied: ${REMOTE_LOG_OWNER} -> ${REMOTE_LOG_DIR}"
    else
        fail "Failed to apply ownership to ${REMOTE_LOG_DIR}"
        return 2
    fi

    info "Applying permissions to ${REMOTE_LOG_DIR}"
    if chmod "${REMOTE_LOG_MODE}" "${REMOTE_LOG_DIR}" >/dev/null 2>&1; then
        pass "Permissions applied: ${REMOTE_LOG_MODE} -> ${REMOTE_LOG_DIR}"
    else
        fail "Failed to apply permissions to ${REMOTE_LOG_DIR}"
        return 2
    fi

    pass "Remote log directory preparation completed"
    return 0
}

#
# prepare_rsyslog_service
# Description:
#  - Verifies the rsyslog service exists.
#  - Starts the rsyslog service.
#  - Enables the rsyslog service at boot.
#  - Confirms the rsyslog service is running.
#
# Preconditions:
#  - rsyslog package is installed
#  - systemd service helpers are sourced
#
# Postconditions:
#  - rsyslog service exists
#  - rsyslog service is started
#  - rsyslog service is enabled
#  - rsyslog service is running
#
# Returns:
#  - 0 if service preparation succeeds
#  - 2 if a critical service preparation step fails
#
prepare_rsyslog_service() {
    step "Phase 4 — Prepare rsyslog service"

    service_exists "${RSYSLOG_SERVICE}" || return 2
    start_service "${RSYSLOG_SERVICE}" || return 2
    enable_service "${RSYSLOG_SERVICE}" || return 2
    service_running "${RSYSLOG_SERVICE}" || return 2

    pass "rsyslog service preparation completed"
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
    info "rsyslog installation stage completed successfully"
    info "Run the next stage script: scripts/validate-rsyslog.sh"
    info "That script should verify listener ports, config load, and log writes"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Install rsyslog"

    preflight_checks || die "Preflight checks failed"
    install_rsyslog_package || die "rsyslog installation failed"
    prepare_remote_log_directory || die "Remote log directory preparation failed"
    prepare_rsyslog_service || die "rsyslog service preparation failed"

    print_next_steps
    pass "install-rsyslog.sh completed successfully"
    return 0
}

main "$@"
