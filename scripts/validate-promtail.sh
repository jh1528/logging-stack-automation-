#!/usr/bin/env bash
#
# validate-promtail.sh
#
# Validates a Promtail installation in readiness mode.
#
# Purpose:
#  - Verify Promtail is installed and running correctly
#  - Confirm the Promtail HTTP endpoint is reachable
#  - Confirm the Promtail config exists
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Use shared helper libraries for service, system, and output logic
#  - Keep end-to-end ingestion validation in validate-pipeline.sh
#
# Validation Mode:
#  - Readiness mode only
#    - Confirms promtail.service exists
#    - Confirms promtail.service is running
#    - Confirms config file exists
#    - Confirms port 9080 is listening
#    - Confirms the HTTP readiness endpoint responds successfully
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Required library files are present and sourceable
#
# Postconditions:
#  - Promtail service health is confirmed
#  - Promtail config existence is confirmed
#  - Promtail readiness endpoint is confirmed
#
# Notes:
#  - This script validates Promtail only
#  - It does not prove end-to-end remote ingestion
#  - End-to-end behavior belongs in validate-pipeline.sh
#
# Environment Variables:
#  - LIB_DIR
#      Override shared library path
#      Default: /home/graylog/infra-bash-lib
#
#  - PROMTAIL_HTTP_HOST
#      Promtail HTTP host
#      Default: 127.0.0.1
#
#  - PROMTAIL_HTTP_PORT
#      Promtail HTTP listen port
#      Default: 9080
#
#  - PROMTAIL_CONFIG
#      Promtail config path
#      Default: /etc/promtail/config.yml
#
# Usage:
#  sudo ./scripts/validate-promtail.sh
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
#   sudo ./scripts/validate-promtail.sh
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

readonly PROMTAIL_HTTP_HOST="${PROMTAIL_HTTP_HOST:-127.0.0.1}"
readonly PROMTAIL_HTTP_PORT="${PROMTAIL_HTTP_PORT:-9080}"
readonly PROMTAIL_BASE_URL="http://${PROMTAIL_HTTP_HOST}:${PROMTAIL_HTTP_PORT}"
readonly PROMTAIL_CONFIG="${PROMTAIL_CONFIG:-/etc/promtail/config.yml}"

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
#  - Verifies the commands required for Promtail validation are available.
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
#  - Verifies the Promtail service exists.
#
# Preconditions:
#  - Shared service helper library is sourced
#
# Postconditions:
#  - promtail.service exists
#
# Returns:
#  - 0 if service exists
#  - 2 if service is missing
#
validate_service_exists() {
    step "Phase 2 — Service registration validation"

    service_exists promtail || return 2
    pass "Promtail service registration validated"
    return 0
}

#
# validate_service_running
# Description:
#  - Verifies the Promtail service is running.
#
# Preconditions:
#  - Promtail service exists
#
# Postconditions:
#  - promtail.service is running
#
# Returns:
#  - 0 if service is running
#  - 2 if service is not running
#
validate_service_running() {
    step "Phase 3 — Service status validation"

    service_running promtail || return 2
    pass "Promtail service status validated"
    return 0
}

#
# validate_config_exists
# Description:
#  - Verifies the Promtail config file exists.
#
# Preconditions:
#  - Promtail has been installed
#
# Postconditions:
#  - /etc/promtail/config.yml exists
#
# Returns:
#  - 0 if config exists
#  - 2 if config is missing
#
validate_config_exists() {
    step "Phase 4 — Config file validation"

    if [[ -f "${PROMTAIL_CONFIG}" ]]; then
        pass "Promtail config exists: ${PROMTAIL_CONFIG}"
        return 0
    fi

    fail "Promtail config does not exist: ${PROMTAIL_CONFIG}"
    return 2
}

#
# validate_listener
# Description:
#  - Verifies the Promtail HTTP listener is active on the expected port.
#
# Preconditions:
#  - Promtail service is running
#
# Postconditions:
#  - Port 9080 listener is validated
#
# Returns:
#  - 0 if listener validation succeeds
#  - 2 if listener validation fails
#
validate_listener() {
    step "Phase 5 — Listener validation"

    if command_exists ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|:)${PROMTAIL_HTTP_PORT}$"; then
            pass "Port ${PROMTAIL_HTTP_PORT} is listening"
            return 0
        fi
    elif command_exists netstat >/dev/null 2>&1; then
        if netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)${PROMTAIL_HTTP_PORT}$"; then
            pass "Port ${PROMTAIL_HTTP_PORT} is listening"
            return 0
        fi
    fi

    fail "Port ${PROMTAIL_HTTP_PORT} is not listening"
    return 2
}

#
# validate_ready_endpoint
# Description:
#  - Verifies the Promtail /ready endpoint responds successfully.
#
# Preconditions:
#  - Promtail service is running
#
# Postconditions:
#  - /ready responds successfully
#
# Returns:
#  - 0 if readiness check succeeds
#  - 2 if readiness check fails
#
validate_ready_endpoint() {
    step "Phase 6 — Readiness endpoint validation"

    if curl -fsS "${PROMTAIL_BASE_URL}/ready" >/dev/null 2>&1; then
        pass "Promtail readiness endpoint responded successfully: ${PROMTAIL_BASE_URL}/ready"
        return 0
    fi

    fail "Promtail readiness endpoint did not respond successfully: ${PROMTAIL_BASE_URL}/ready"
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

    info "Service: promtail.service"
    info "Config: ${PROMTAIL_CONFIG}"
    info "Endpoint: ${PROMTAIL_BASE_URL}"
    info "Readiness mode: enabled"

    pass "Promtail validation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Validate Promtail"

    require_root || die "Root privilege check failed"
    require_runtime_commands || die "Validation command checks failed"
    validate_service_exists || die "Promtail service registration validation failed"
    validate_service_running || die "Promtail service status validation failed"
    validate_config_exists || die "Promtail config validation failed"
    validate_listener || die "Promtail listener validation failed"
    validate_ready_endpoint || die "Promtail readiness endpoint validation failed"

    print_validation_summary
    pass "validate-promtail.sh completed successfully"
    return 0
}

main "$@"
