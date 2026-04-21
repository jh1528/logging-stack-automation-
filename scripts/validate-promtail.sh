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
#  - Keep validation separate from installation responsibilities
#
# Validation Mode:
#  - Readiness mode only
#    - Confirms promtail.service exists
#    - Confirms promtail.service is running
#    - Confirms config file exists
#    - Confirms port 9080 listener exists
#    - Confirms the HTTP readiness endpoint responds successfully
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Use infra-bash-lib helpers for output and service checks
#
# Notes:
#  - This script validates Promtail only
#  - It does not prove end-to-end remote ingestion
#  - End-to-end behavior belongs in validate-pipeline.sh
#
# Environment Variables:
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
# Author:
#  - Jared Husson style preserved by ChatGPT
#

set -u

# ==============================================================================
# Path discovery and shared library loading
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/../infra-bash-lib"

# shellcheck source=../../infra-bash-lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../../infra-bash-lib/apt.sh
source "${LIB_DIR}/apt.sh"
# shellcheck source=../../infra-bash-lib/service.sh
source "${LIB_DIR}/service.sh"
# shellcheck source=../../infra-bash-lib/system.sh
source "${LIB_DIR}/system.sh"

# ==============================================================================
# Configuration
# ==============================================================================

PROMTAIL_HTTP_HOST="${PROMTAIL_HTTP_HOST:-127.0.0.1}"
PROMTAIL_HTTP_PORT="${PROMTAIL_HTTP_PORT:-9080}"
PROMTAIL_BASE_URL="http://${PROMTAIL_HTTP_HOST}:${PROMTAIL_HTTP_PORT}"

PROMTAIL_CONFIG="${PROMTAIL_CONFIG:-/etc/promtail/config.yml}"

# ==============================================================================
# Internal helpers
# ==============================================================================

require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		die "This script must be run as root"
	fi

	pass "Running as root"
	return 0
}

require_runtime_commands() {
	step "Checking validation command dependencies"

	command_exists curl >/dev/null || die "curl is required for Promtail validation"
	command_exists ss >/dev/null || die "ss is required for listener validation"

	pass "Required validation commands are available"
	return 0
}

validate_service_exists() {
	step "Checking Promtail service registration"

	service_exists promtail || die "promtail.service is not installed"
	return 0
}

validate_service_running() {
	step "Checking Promtail service status"

	service_running promtail || die "promtail.service is not running"
	return 0
}

validate_config_exists() {
	step "Checking Promtail config file"

	if [[ -f "${PROMTAIL_CONFIG}" ]]; then
		pass "Promtail config exists: ${PROMTAIL_CONFIG}"
		return 0
	fi

	fail "Promtail config does not exist: ${PROMTAIL_CONFIG}"
	return 2
}

validate_listener() {
	step "Checking Promtail listener"

	local listener_output

	listener_output="$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E "(^|:)${PROMTAIL_HTTP_PORT}$" || true)"

	if [[ -n "$listener_output" ]]; then
		pass "Port ${PROMTAIL_HTTP_PORT} is listening"
		return 0
	fi

	fail "Port ${PROMTAIL_HTTP_PORT} is not listening"
	return 2
}

validate_ready_endpoint() {
	step "Checking Promtail readiness endpoint"

	if curl -fsS "${PROMTAIL_BASE_URL}/ready" >/dev/null 2>&1; then
		pass "Promtail readiness endpoint responded successfully: ${PROMTAIL_BASE_URL}/ready"
		return 0
	fi

	fail "Promtail readiness endpoint did not respond successfully: ${PROMTAIL_BASE_URL}/ready"
	return 2
}

print_validation_summary() {
	step "Promtail validation summary"

	info "Service: promtail.service"
	info "Config: ${PROMTAIL_CONFIG}"
	info "Endpoint: ${PROMTAIL_BASE_URL}"
	info "Readiness mode: enabled"

	pass "Promtail validation completed successfully"
	return 0
}

# ==============================================================================
# Main workflow
# ==============================================================================

main() {
	step "Starting Promtail validation"

	require_root
	require_runtime_commands

	validate_service_exists
	validate_service_running
	validate_config_exists || die "Promtail config validation failed"
	validate_listener || die "Promtail is not listening on the expected port"
	validate_ready_endpoint || die "Promtail readiness endpoint validation failed"

	print_validation_summary
}

main "$@"
