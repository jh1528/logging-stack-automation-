#!/usr/bin/env bash
#
# validate-grafana.sh
#
# Validates a Grafana installation in readiness mode.
#
# Purpose:
#  - Verify Grafana is installed and running correctly
#  - Confirm the HTTP UI is reachable
#  - Keep validation separate from installation responsibilities
#
# Validation Mode:
#  - Readiness mode only
#    - Confirms grafana-server.service exists
#    - Confirms grafana-server.service is running
#    - Confirms port 3000 is listening
#    - Confirms the HTTP UI responds successfully
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Use infra-bash-lib helpers for output and service checks
#
# Notes:
#  - This script validates Grafana only
#  - It does not validate Loki datasources or dashboards
#
# Environment Variables:
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

GRAFANA_HTTP_HOST="${GRAFANA_HTTP_HOST:-127.0.0.1}"
GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"
GRAFANA_BASE_URL="http://${GRAFANA_HTTP_HOST}:${GRAFANA_HTTP_PORT}"

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

	command_exists curl >/dev/null || die "curl is required for Grafana validation"
	command_exists ss >/dev/null || die "ss is required for listener validation"

	pass "Required validation commands are available"
	return 0
}

validate_service_exists() {
	step "Checking Grafana service registration"

	service_exists grafana-server || die "grafana-server.service is not installed"
	return 0
}

validate_service_running() {
	step "Checking Grafana service status"

	service_running grafana-server || die "grafana-server.service is not running"
	return 0
}

validate_listener() {
	step "Checking Grafana listener"

	local listener_output

	listener_output="$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E "(^|:)${GRAFANA_HTTP_PORT}$" || true)"

	if [[ -n "$listener_output" ]]; then
		pass "Port ${GRAFANA_HTTP_PORT} is listening"
		return 0
	fi

	fail "Port ${GRAFANA_HTTP_PORT} is not listening"
	return 2
}

validate_http_endpoint() {
	step "Checking Grafana HTTP endpoint"

	if curl -fsS "${GRAFANA_BASE_URL}/login" >/dev/null 2>&1; then
		pass "Grafana HTTP endpoint responded successfully: ${GRAFANA_BASE_URL}/login"
		return 0
	fi

	fail "Grafana HTTP endpoint did not respond successfully: ${GRAFANA_BASE_URL}/login"
	return 2
}

print_validation_summary() {
	step "Grafana validation summary"

	info "Service: grafana-server.service"
	info "Endpoint: ${GRAFANA_BASE_URL}"
	info "Readiness mode: enabled"

	pass "Grafana validation completed successfully"
	return 0
}

# ==============================================================================
# Main workflow
# ==============================================================================

main() {
	step "Starting Grafana validation"

	require_root
	require_runtime_commands

	validate_service_exists
	validate_service_running
	validate_listener || die "Grafana is not listening on the expected port"
	validate_http_endpoint || die "Grafana HTTP endpoint validation failed"

	print_validation_summary
}

main "$@"
