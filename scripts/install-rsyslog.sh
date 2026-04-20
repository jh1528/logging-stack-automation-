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
#  - Ensure the rsyslog service exists
#  - Start the rsyslog service
#  - Enable the rsyslog service at boot
#
# Design:
#  - Keep installation separate from deep validation
#  - Use shared library helpers where possible
#  - Fail fast on critical errors
#  - Reserve listener and log-write verification for validate-rsyslog.sh
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Debian/Ubuntu package manager is available
#  - Required library files are present and sourceable
#
# Postconditions:
#  - rsyslog package is installed
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

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "This script must be run as root"
        return 2
    fi

    pass "Running with root privileges"
    return 0
}

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

    pass "Preflight checks completed"
    return 0
}

install_rsyslog_package() {
    step "Phase 2 — Install rsyslog"

    apt_update || return 2
    apt_install "${RSYSLOG_PACKAGE}" || return 2

    pass "rsyslog package installation completed"
    return 0
}

prepare_rsyslog_runtime() {
    step "Phase 3 — Prepare rsyslog runtime"

    ensure_directory "${REMOTE_LOG_DIR}" || return 2

    service_exists "${RSYSLOG_SERVICE}" || return 2
    start_service "${RSYSLOG_SERVICE}" || return 2
    enable_service "${RSYSLOG_SERVICE}" || return 2
    service_running "${RSYSLOG_SERVICE}" || return 2

    pass "rsyslog runtime preparation completed"
    return 0
}

print_next_steps() {
    step "Next Step"

    info "Using shared library path: ${LIB_DIR}"
    info "rsyslog installation stage completed successfully"
    info "Run the next stage script: scripts/validate-rsyslog.sh"
    info "That script should verify listener ports, config load, and log writes"
}

main() {
    step "Install rsyslog"

    preflight_checks || die "Preflight checks failed"
    install_rsyslog_package || die "rsyslog installation failed"
    prepare_rsyslog_runtime || die "rsyslog runtime preparation failed"

    print_next_steps
    pass "install-rsyslog.sh completed successfully"
    return 0
}

main "$@"
