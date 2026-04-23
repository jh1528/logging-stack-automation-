#!/usr/bin/env bash
#
# install-grafana.sh
#
# Installs and configures Grafana for the logging stack project.
#
# Purpose:
#  - Run preflight health checks
#  - Verify required commands are available
#  - Install prerequisite packages
#  - Register and trust the Grafana APT repository
#  - Install the grafana package
#  - Enable and start grafana-server.service
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
#  - Grafana repository signing key is installed
#  - Grafana APT repository is configured
#  - grafana package is installed
#  - grafana-server.service exists
#  - grafana-server.service is started
#  - grafana-server.service is enabled at boot
#
# Notes:
#  - Validation belongs in scripts/validate-grafana.sh
#  - This script installs Grafana only
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
#   sudo ./scripts/install-grafana.sh
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

readonly GRAFANA_PACKAGE="grafana"
readonly GRAFANA_SERVICE="grafana-server"

readonly GRAFANA_APT_KEYRING="/etc/apt/keyrings/grafana.gpg"
readonly GRAFANA_APT_SOURCE="/etc/apt/sources.list.d/grafana.list"
readonly GRAFANA_APT_REPO="deb [signed-by=${GRAFANA_APT_KEYRING}] https://apt.grafana.com stable main"
readonly GRAFANA_UI_URL="http://127.0.0.1:3000"

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
#  - Runs installation safety and dependency checks before configuring
#    the Grafana repository and package.
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
    command_exists curl || return 2
    command_exists gpg || return 2
    command_exists chmod || return 2
    command_exists mkdir || return 2

    pass "Preflight checks completed"
    return 0
}

#
# install_prerequisite_packages
# Description:
#  - Installs prerequisite packages required to configure and trust the
#    Grafana APT repository.
#
# Preconditions:
#  - Preflight checks have completed successfully
#  - APT helper library is sourced
#
# Postconditions:
#  - apt-transport-https is installed
#  - software-properties-common is installed
#  - wget is installed
#
# Returns:
#  - 0 if prerequisite installation succeeds
#  - 2 if prerequisite installation fails
#
install_prerequisite_packages() {
    step "Phase 2 — Install prerequisite packages"

    export DEBIAN_FRONTEND=noninteractive

    apt_update || return 2
    apt_install apt-transport-https software-properties-common wget || return 2

    pass "Prerequisite package installation completed"
    return 0
}

#
# ensure_apt_keyrings_directory
# Description:
#  - Ensures the APT keyrings directory exists before installing the
#    Grafana repository signing key.
#
# Preconditions:
#  - Filesystem helper library is sourced
#
# Postconditions:
#  - /etc/apt/keyrings exists
#
# Returns:
#  - 0 if directory preparation succeeds
#  - 2 if directory preparation fails
#
ensure_apt_keyrings_directory() {
    step "Phase 3 — Prepare APT keyrings directory"

    ensure_directory "/etc/apt/keyrings" || return 2

    pass "APT keyrings directory is ready"
    return 0
}

#
# install_grafana_repository_key
# Description:
#  - Downloads and installs the Grafana repository signing key.
#  - Applies the permissions required for APT keyring usage.
#
# Preconditions:
#  - /etc/apt/keyrings exists
#  - curl and gpg are available
#
# Postconditions:
#  - Grafana signing key exists at /etc/apt/keyrings/grafana.gpg
#  - Key permissions are set to 0644
#
# Returns:
#  - 0 if repository key installation succeeds
#  - 2 if repository key installation fails
#
install_grafana_repository_key() {
    step "Phase 4 — Install Grafana repository signing key"

    if curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o "${GRAFANA_APT_KEYRING}"; then
        pass "Grafana repository signing key installed"
    else
        fail "Failed to install Grafana repository signing key"
        return 2
    fi

    if chmod 0644 "${GRAFANA_APT_KEYRING}" >/dev/null 2>&1; then
        pass "Permissions applied to ${GRAFANA_APT_KEYRING}"
        return 0
    fi

    fail "Failed to set permissions on ${GRAFANA_APT_KEYRING}"
    return 2
}

#
# install_grafana_repository
# Description:
#  - Writes the Grafana APT repository definition file.
#
# Preconditions:
#  - Grafana repository signing key is installed
#
# Postconditions:
#  - Grafana repository file exists at /etc/apt/sources.list.d/grafana.list
#
# Returns:
#  - 0 if repository configuration succeeds
#  - 2 if repository configuration fails
#
install_grafana_repository() {
    step "Phase 5 — Configure Grafana APT repository"

    write_file "${GRAFANA_APT_SOURCE}" <<EOF
${GRAFANA_APT_REPO}
EOF
    if [[ $? -ne 0 ]]; then
        fail "Failed to configure Grafana APT repository"
        return 2
    fi

    pass "Grafana APT repository configured"
    return 0
}

#
# install_grafana_package
# Description:
#  - Installs the Grafana package from the configured APT repository.
#
# Preconditions:
#  - Grafana repository is configured
#  - APT helper library is sourced
#
# Postconditions:
#  - grafana package is installed
#
# Returns:
#  - 0 if Grafana package installation succeeds
#  - 2 if Grafana package installation fails
#
install_grafana_package() {
    step "Phase 6 — Install Grafana package"

    export DEBIAN_FRONTEND=noninteractive

    apt_update || return 2
    apt_install "${GRAFANA_PACKAGE}" || return 2

    pass "Grafana package installation completed"
    return 0
}

#
# prepare_grafana_service
# Description:
#  - Verifies the Grafana service exists.
#  - Starts the Grafana service.
#  - Enables the Grafana service at boot.
#  - Confirms the Grafana service is running.
#
# Preconditions:
#  - grafana package is installed
#  - systemd service helpers are sourced
#
# Postconditions:
#  - grafana-server.service exists
#  - grafana-server.service is started
#  - grafana-server.service is enabled
#  - grafana-server.service is running
#
# Returns:
#  - 0 if service preparation succeeds
#  - 2 if a critical service preparation step fails
#
prepare_grafana_service() {
    step "Phase 7 — Prepare Grafana service"

    service_exists "${GRAFANA_SERVICE}" || return 2
    enable_service "${GRAFANA_SERVICE}" || return 2
    start_service "${GRAFANA_SERVICE}" || return 2
    service_running "${GRAFANA_SERVICE}" || return 2

    pass "Grafana service preparation completed"
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
    info "Package: ${GRAFANA_PACKAGE}"
    info "Service: ${GRAFANA_SERVICE}.service"
    info "Web UI: ${GRAFANA_UI_URL}"
    info "Run the next stage script: scripts/validate-grafana.sh"

    pass "Grafana installation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Install Grafana"

    preflight_checks || die "Preflight checks failed"
    install_prerequisite_packages || die "Prerequisite package installation failed"
    ensure_apt_keyrings_directory || die "APT keyrings directory preparation failed"
    install_grafana_repository_key || die "Grafana repository key installation failed"
    install_grafana_repository || die "Grafana repository configuration failed"
    install_grafana_package || die "Grafana package installation failed"
    prepare_grafana_service || die "Grafana service preparation failed"

    print_next_steps
    pass "install-grafana.sh completed successfully"
    return 0
}

main "$@"
