#!/usr/bin/env bash
#
# validate-grafana.sh
#
# Validates a Grafana installation in readiness mode.
#
# Purpose:
#  - Verify Grafana is installed and running correctly
#  - Confirm the HTTP UI is reachable
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Use shared helper libraries for service, system, and output logic
#
# Validation Mode:
#  - Readiness mode only
#    - Confirms grafana-server.service exists
#    - Confirms grafana-server.service is running
#    - Confirms port 3000 is listening
#    - Confirms the HTTP UI responds successfully
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Required library files are present and sourceable
#
# Postconditions:
#  - Grafana service health is confirmed
#  - Grafana UI endpoint is confirmed reachable
#
# Environment Variables:
#  - LIB_DIR
#      Override shared library path
#      Default: /home/graylog/infra-bash-lib
#
#  - GRAFANA_HTTP_HOST
#      Grafana HTTP host
#      Default: 127.0.0.1
#
#  - GRAFANA_HTTP_PORT
#      Grafana HTTP listen port
#      Default: 3000
#
# Usage:
#  sudo ./scripts/validate-grafana.sh
#
# Returns:
#  - 0 if validation succeeds
#  - 2 if a critical validation step fails
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
#   sudo ./scripts/validate-grafana.sh
#
readonly DEFAULT_LIB_DIR="/home/graylog/infra-bash-lib"
readonly LIB_DIR="${LIB_DIR:-${DEFAULT_LIB_DIR}}"

COMMON_LIB="${LIB_DIR}/common.sh"
SERVICE_LIB="${LIB_DIR}/service.sh"
SYSTEM_LIB="${LIB_DIR}/system.sh"

# ------------------------------------------------------------------------------
# Library loading
# ------------------------------------------------------------------------------

[[ -f "${COMMON_LIB}"  ]] || { echo "[FAIL] Missing library: ${COMMON_LIB}"; exit 2; }
[[ -f "${SERVICE_LIB}" ]] || { echo "[FAIL] Missing library: ${SERVICE_LIB}"; exit 2; }
[[ -f "${SYSTEM_LIB}"  ]] || { echo "[FAIL] Missing library: ${SYSTEM_LIB}"; exit 2; }

# shellcheck source=/dev/null
source "${COMMON_LIB}"
# shellcheck source=/dev/null
source "${SERVICE_LIB}"
# shellcheck source=/dev/null
source "${SYSTEM_LIB}"

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------

readonly GRAFANA_HTTP_HOST="${GRAFANA_HTTP_HOST:-127.0.0.1}"
readonly GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"
readonly GRAFANA_BASE_URL="http://${GRAFANA_HTTP_HOST}:${GRAFANA_HTTP_PORT}"

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
# require_runtime_commands
# Description:
#  - Verifies the commands required for Grafana validation are available.
#  - Supports either ss or netstat for listener validation.
#
# Preconditions:
#  - Shared system helper library is sourced
#
# Postconditions:
#  - Required validation commands are available
#
# Returns:
#  - 0 if command validation succeeds
#  - 2 if a critical command is missing
#
require_runtime_commands() {
    step "Phase 1 — Validation command checks"

    command_exists curl || return 2

    if command_exists ss >/dev/null 2>&1; then
        pass "Socket inspection command available: ss"
        return 0
    fi

    if command_exists netstat >/dev/null 2>&1; then
        pass "Socket inspection command available: netstat"
        return 0
    fi

    fail "Neither ss nor netstat is available for listener validation"
    return 2
}

#
# validate_service_exists
# Description:
#  - Verifies the Grafana service exists.
#
# Preconditions:
#  - Shared service helper library is sourced
#
# Postconditions:
#  - grafana-server.service exists
#
# Returns:
#  - 0 if service exists
#  - 2 if service is missing
#
validate_service_exists() {
    step "Phase 2 — Service registration validation"

    service_exists grafana-server || return 2
    pass "Grafana service registration validated"
    return 0
}

#
# validate_service_running
# Description:
#  - Verifies the Grafana service is running.
#
# Preconditions:
#  - Grafana service exists
#
# Postconditions:
#  - grafana-server.service is running
#
# Returns:
#  - 0 if service is running
#  - 2 if service is not running
#
validate_service_running() {
    step "Phase 3 — Service status validation"

    service_running grafana-server || return 2
    pass "Grafana service status validated"
    return 0
}

#
# validate_listener
# Description:
#  - Verifies the Grafana HTTP listener is active on the expected port.
#
# Preconditions:
#  - Grafana service is running
#
# Postconditions:
#  - Port 3000 listener is validated
#
# Returns:
#  - 0 if listener validation succeeds
#  - 2 if listener validation fails
#
validate_listener() {
    step "Phase 4 — Listener validation"

    if command_exists ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|:)${GRAFANA_HTTP_PORT}$"; then
            pass "Port ${GRAFANA_HTTP_PORT} is listening"
            return 0
        fi
    elif command_exists netstat >/dev/null 2>&1; then
        if netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)${GRAFANA_HTTP_PORT}$"; then
            pass "Port ${GRAFANA_HTTP_PORT} is listening"
            return 0
        fi
    fi

    fail "Port ${GRAFANA_HTTP_PORT} is not listening"
    return 2
}

#
# validate_http_endpoint
# Description:
#  - Verifies the Grafana /login endpoint responds successfully.
#
# Preconditions:
#  - Grafana service is running
#
# Postconditions:
#  - /login responds successfully
#
# Returns:
#  - 0 if HTTP validation succeeds
#  - 2 if HTTP validation fails
#
validate_http_endpoint() {
    step "Phase 5 — HTTP endpoint validation"

    if curl -fsS "${GRAFANA_BASE_URL}/login" >/dev/null 2>&1; then
        pass "Grafana HTTP endpoint responded successfully: ${GRAFANA_BASE_URL}/login"
        return 0
    fi

    fail "Grafana HTTP endpoint did not respond successfully: ${GRAFANA_BASE_URL}/login"
    return 2
}

#
# print_validation_summary
# Description:
#  - Prints a concise validation summary.
#
# Preconditions:
#  - Validation phases completed successfully
#
# Postconditions:
#  - Summary information is printed to stdout
#
# Returns:
#  - 0
#
print_validation_summary() {
    step "Validation Summary"

    info "Service: grafana-server.service"
    info "Endpoint: ${GRAFANA_BASE_URL}"
    info "Readiness mode: enabled"

    pass "Grafana validation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Validate Grafana"

    require_root || die "Root privilege check failed"
    require_runtime_commands || die "Validation command checks failed"
    validate_service_exists || die "Grafana service registration validation failed"
    validate_service_running || die "Grafana service status validation failed"
    validate_listener || die "Grafana listener validation failed"
    validate_http_endpoint || die "Grafana HTTP endpoint validation failed"

    print_validation_summary
    pass "validate-grafana.sh completed successfully"
    return 0
}

main "$@"
