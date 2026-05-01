#!/usr/bin/env bash
#
# start-stack.sh
#
# Starts the local centralized logging stack before pipeline validation.
#
# Purpose:
#  - Start rsyslog, Loki, Promtail, and Grafana
#  - Verify services are running
#  - Wait for Loki and Grafana HTTP endpoints
#  - Give clear PASS/FAIL output before validate-pipeline.sh is run
#
# Design:
#  - Keep this script separate from installation and setup
#  - Do not rewrite configuration files
#  - Do not provision dashboards
#  - Only start and health-check existing services
#  - Use infra-bash-lib helpers for consistent project output
#
# Preconditions:
#  - rsyslog, Loki, Promtail, and Grafana are already installed
#  - infra-bash-lib exists and is sourceable
#  - Service unit files exist
#
# Postconditions:
#  - Required services are started
#  - Loki readiness endpoint responds
#  - Grafana login endpoint responds
#
# Returns:
#  - 0 if all services start and endpoints respond
#  - 2 if a critical service or endpoint fails
#

set -u

readonly DEFAULT_LIB_DIR="/home/graylog/infra-bash-lib"
readonly LIB_DIR="${LIB_DIR:-${DEFAULT_LIB_DIR}}"

COMMON_LIB="${LIB_DIR}/common.sh"
SERVICE_LIB="${LIB_DIR}/service.sh"
SYSTEM_LIB="${LIB_DIR}/system.sh"

[[ -f "${COMMON_LIB}"  ]] || { echo "[FAIL] Missing library: ${COMMON_LIB}"; exit 2; }
[[ -f "${SERVICE_LIB}" ]] || { echo "[FAIL] Missing library: ${SERVICE_LIB}"; exit 2; }
[[ -f "${SYSTEM_LIB}"  ]] || { echo "[FAIL] Missing library: ${SYSTEM_LIB}"; exit 2; }

# shellcheck source=/dev/null
source "${COMMON_LIB}"
# shellcheck source=/dev/null
source "${SERVICE_LIB}"
# shellcheck source=/dev/null
source "${SYSTEM_LIB}"

readonly RSYSLOG_SERVICE="rsyslog"
readonly LOKI_SERVICE="loki"
readonly PROMTAIL_SERVICE="promtail"
readonly GRAFANA_SERVICE="grafana-server"

readonly LOKI_HTTP_HOST="${LOKI_HTTP_HOST:-127.0.0.1}"
readonly LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
readonly LOKI_BASE_URL="http://${LOKI_HTTP_HOST}:${LOKI_HTTP_PORT}"

readonly GRAFANA_HTTP_HOST="${GRAFANA_HTTP_HOST:-127.0.0.1}"
readonly GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"
readonly GRAFANA_BASE_URL="http://${GRAFANA_HTTP_HOST}:${GRAFANA_HTTP_PORT}"

readonly HTTP_ENDPOINT_RETRIES="${HTTP_ENDPOINT_RETRIES:-15}"
readonly HTTP_ENDPOINT_SLEEP_SECONDS="${HTTP_ENDPOINT_SLEEP_SECONDS:-2}"

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
#  - Verifies required runtime commands are available.
#
# Preconditions:
#  - Shared system helper library is sourced
#
# Postconditions:
#  - Required commands are available
#
# Returns:
#  - 0 if required commands exist
#  - 2 if a required command is missing
#
require_runtime_commands() {
    step "Phase 1 — Runtime command checks"

    command_exists curl || return 2
    command_exists systemctl || return 2
    command_exists sleep || return 2

    pass "Runtime command checks completed"
    return 0
}

#
# validate_services_exist
# Description:
#  - Confirms all required systemd services exist before start attempts.
#
# Preconditions:
#  - Shared service helper library is sourced
#
# Postconditions:
#  - rsyslog, Loki, Promtail, and Grafana services are known to systemd
#
# Returns:
#  - 0 if all services exist
#  - 2 if any required service is missing
#
validate_services_exist() {
    step "Phase 2 — Service existence validation"

    service_exists "${RSYSLOG_SERVICE}" || return 2
    service_exists "${LOKI_SERVICE}" || return 2
    service_exists "${PROMTAIL_SERVICE}" || return 2
    service_exists "${GRAFANA_SERVICE}" || return 2

    pass "Service existence validation completed"
    return 0
}

#
# start_service
# Description:
#  - Starts one systemd service.
#
# Preconditions:
#  - Accepts one argument:
#    1. systemd service name
#  - Service exists
#
# Postconditions:
#  - Requested service has been started or start failure is reported
#
# Returns:
#  - 0 if service start succeeds
#  - 2 if service start fails
#
start_service() {
    local service_name="$1"

    if [[ -z "${service_name}" ]]; then
        fail "Usage: start_service <service_name>"
        return 2
    fi

    systemctl start "${service_name}" || {
        fail "Failed to start service: ${service_name}"
        return 2
    }

    pass "Started service: ${service_name}"
    return 0
}

#
# start_stack_services
# Description:
#  - Starts stack services in dependency-aware order.
#  - rsyslog starts first to receive logs.
#  - Loki starts before Promtail because Promtail pushes to Loki.
#  - Promtail starts before Grafana because Grafana only visualizes stored logs.
#  - Grafana starts last.
#
# Preconditions:
#  - Required services exist
#
# Postconditions:
#  - All required services have received start requests
#
# Returns:
#  - 0 if all start requests succeed
#  - 2 if any service fails to start
#
start_stack_services() {
    step "Phase 3 — Start logging stack services"

    start_service "${RSYSLOG_SERVICE}" || return 2
    start_service "${LOKI_SERVICE}" || return 2
    start_service "${PROMTAIL_SERVICE}" || return 2
    start_service "${GRAFANA_SERVICE}" || return 2

    pass "Logging stack service start completed"
    return 0
}

#
# validate_services_running
# Description:
#  - Verifies all stack services are running after start.
#
# Preconditions:
#  - Services have been started
#  - Shared service helper library is sourced
#
# Postconditions:
#  - rsyslog, Loki, Promtail, and Grafana are verified as running
#
# Returns:
#  - 0 if all services are running
#  - 2 if any service is not running
#
validate_services_running() {
    step "Phase 4 — Service running validation"

    service_running "${RSYSLOG_SERVICE}" || return 2
    service_running "${LOKI_SERVICE}" || return 2
    service_running "${PROMTAIL_SERVICE}" || return 2
    service_running "${GRAFANA_SERVICE}" || return 2

    pass "Service running validation completed"
    return 0
}

#
# wait_for_http_endpoint
# Description:
#  - Waits for an HTTP endpoint to respond successfully.
#
# Preconditions:
#  - curl is available
#  - Accepts two arguments:
#    1. Human-readable endpoint name
#    2. Endpoint URL
#
# Postconditions:
#  - Endpoint responds successfully or retry limit is reached
#
# Returns:
#  - 0 if endpoint responds successfully
#  - 2 if endpoint does not respond successfully
#
wait_for_http_endpoint() {
    local endpoint_name="$1"
    local endpoint_url="$2"
    local attempt

    if [[ -z "${endpoint_name}" || -z "${endpoint_url}" ]]; then
        fail "Usage: wait_for_http_endpoint <name> <url>"
        return 2
    fi

    for (( attempt=1; attempt<=HTTP_ENDPOINT_RETRIES; attempt++ )); do
        if curl -fsS "${endpoint_url}" >/dev/null 2>&1; then
            pass "${endpoint_name} responded successfully: ${endpoint_url}"
            return 0
        fi

        info "Waiting for ${endpoint_name}: attempt ${attempt}/${HTTP_ENDPOINT_RETRIES}"
        sleep "${HTTP_ENDPOINT_SLEEP_SECONDS}"
    done

    fail "${endpoint_name} did not respond successfully after ${HTTP_ENDPOINT_RETRIES} attempts: ${endpoint_url}"
    return 2
}

#
# validate_http_endpoints
# Description:
#  - Validates Loki and Grafana HTTP endpoints.
#
# Preconditions:
#  - Loki and Grafana services are running
#  - curl is available
#
# Postconditions:
#  - Loki /ready responds successfully
#  - Grafana /login responds successfully
#
# Returns:
#  - 0 if endpoints respond
#  - 2 if any endpoint fails
#
validate_http_endpoints() {
    step "Phase 5 — HTTP endpoint validation"

    wait_for_http_endpoint "Loki readiness endpoint" "${LOKI_BASE_URL}/ready" || return 2
    wait_for_http_endpoint "Grafana HTTP endpoint" "${GRAFANA_BASE_URL}/login" || return 2

    pass "HTTP endpoint validation completed"
    return 0
}

#
# print_start_summary
# Description:
#  - Prints a concise summary after successful stack startup.
#
# Preconditions:
#  - Services and endpoints have passed validation
#
# Postconditions:
#  - Operator receives next command to run
#
# Returns:
#  - 0
#
print_start_summary() {
    step "Start Summary"

    info "rsyslog is running"
    info "Loki is running and reachable: ${LOKI_BASE_URL}/ready"
    info "Promtail is running"
    info "Grafana is running and reachable: ${GRAFANA_BASE_URL}/login"
    info "Next command: sudo ./scripts/validate-pipeline.sh"

    pass "Logging stack started successfully"
    return 0
}

main() {
    step "Start centralized logging stack"

    require_root || die "Root privilege check failed"
    require_runtime_commands || die "Runtime command checks failed"
    validate_services_exist || die "Service existence validation failed"
    start_stack_services || die "Logging stack service start failed"
    validate_services_running || die "Service running validation failed"
    validate_http_endpoints || die "HTTP endpoint validation failed"
    print_start_summary

    pass "start-stack.sh completed successfully"
    return 0
}

main "$@"
