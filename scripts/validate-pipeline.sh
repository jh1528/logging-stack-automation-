#!/usr/bin/env bash
#
# validate-pipeline.sh
#
# Validates the end-to-end centralized logging pipeline.
#
# Purpose:
#  - Verify the local logging stack is installed and healthy
#  - Confirm rsyslog can receive remote logs
#  - Confirm remote logs are written under /var/log/remote
#  - Confirm Promtail can ship remote logs into Loki
#  - Confirm Loki can return the ingested log data
#  - Confirm Grafana is reachable as the visibility layer
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Support readiness-only validation by default
#  - Support true end-to-end validation with a real external sender
#  - Avoid fake loopback assumptions where real behavior matters
#
# Validation Modes:
#  1. Readiness Mode (default)
#     - Confirms rsyslog, promtail, loki, and grafana services exist and run
#     - Confirms required HTTP endpoints respond
#     - Confirms /var/log/remote exists
#     - Does not pretend local loopback traffic is a real remote sender
#
#  2. Remote Sender Mode
#     - Enabled with EXPECT_REMOTE_SENDER=1
#     - Waits for a real remote syslog message from another host
#     - Confirms the message is written under /var/log/remote
#     - Queries Loki and confirms the same message is retrievable
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Required library files are present and sourceable
#  - Loki, Promtail, rsyslog, and Grafana have already been installed
#
# Postconditions:
#  - Readiness mode confirms stack health
#  - Remote sender mode confirms true end-to-end ingestion
#
# Environment Variables:
#  - LIB_DIR
#      Override shared library path
#      Default: /home/graylog/infra-bash-lib
#
#  - EXPECT_REMOTE_SENDER
#      When set to 1, wait for a real external sender and validate end-to-end
#      Default: 0
#
#  - PIPELINE_TEST_MESSAGE
#      Exact message text expected from the remote sender
#      Default: pipeline validation test message
#
#  - REMOTE_TEST_TIMEOUT
#      Seconds to wait for the remote sender message
#      Default: 60
#
#  - REMOTE_TEST_POLL_INTERVAL
#      Seconds between remote message checks
#      Default: 2
#
#  - LOKI_HTTP_HOST
#      Loki HTTP host
#      Default: 127.0.0.1
#
#  - LOKI_HTTP_PORT
#      Loki HTTP port
#      Default: 3100
#
#  - GRAFANA_HTTP_HOST
#      Grafana HTTP host
#      Default: 127.0.0.1
#
#  - GRAFANA_HTTP_PORT
#      Grafana HTTP port
#      Default: 3000
#
#  - LOKI_QUERY_RETRIES
#      Number of Loki query attempts in remote sender mode
#      Default: 15
#
#  - LOKI_QUERY_SLEEP_SECONDS
#      Delay between Loki query attempts
#      Default: 2
#
# Usage:
#  sudo ./scripts/validate-pipeline.sh
#
# Real end-to-end validation:
#  sudo EXPECT_REMOTE_SENDER=1 ./scripts/validate-pipeline.sh
#
# Example remote sender from another VM:
#  logger -n <SERVER_IP> -P 514 "pipeline validation test message"
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
#   sudo ./scripts/validate-pipeline.sh
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

readonly RSYSLOG_SERVICE="rsyslog"
readonly LOKI_SERVICE="loki"
readonly PROMTAIL_SERVICE="promtail"
readonly GRAFANA_SERVICE="grafana-server"

readonly REMOTE_LOG_DIR="/var/log/remote"

readonly EXPECT_REMOTE_SENDER="${EXPECT_REMOTE_SENDER:-0}"
readonly PIPELINE_TEST_MESSAGE="${PIPELINE_TEST_MESSAGE:-pipeline validation test message}"
readonly REMOTE_TEST_TIMEOUT="${REMOTE_TEST_TIMEOUT:-60}"
readonly REMOTE_TEST_POLL_INTERVAL="${REMOTE_TEST_POLL_INTERVAL:-2}"

readonly LOKI_HTTP_HOST="${LOKI_HTTP_HOST:-127.0.0.1}"
readonly LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
readonly LOKI_BASE_URL="http://${LOKI_HTTP_HOST}:${LOKI_HTTP_PORT}"

readonly GRAFANA_HTTP_HOST="${GRAFANA_HTTP_HOST:-127.0.0.1}"
readonly GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"
readonly GRAFANA_BASE_URL="http://${GRAFANA_HTTP_HOST}:${GRAFANA_HTTP_PORT}"

readonly LOKI_QUERY_RETRIES="${LOKI_QUERY_RETRIES:-15}"
readonly LOKI_QUERY_SLEEP_SECONDS="${LOKI_QUERY_SLEEP_SECONDS:-2}"

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
#  - Verifies the commands required for pipeline validation are available.
#
# Preconditions:
#  - Shared system helper library is sourced
#
# Postconditions:
#  - Required validation commands are available
#
# Returns:
#  - 0 if all required commands exist
#  - 2 if a critical command is missing
#
require_runtime_commands() {
    step "Phase 1 — Validation command checks"

    command_exists curl || return 2
    command_exists grep || return 2
    command_exists find || return 2
    command_exists awk || return 2
    command_exists sleep || return 2
    command_exists python3 || return 2

    pass "Validation command checks completed"
    return 0
}

#
# validate_local_services
# Description:
#  - Verifies all required pipeline services exist and are currently running.
#
# Preconditions:
#  - Shared service helper library is sourced
#
# Postconditions:
#  - rsyslog, loki, promtail, and grafana-server services are verified
#
# Returns:
#  - 0 if all services are present and running
#  - 2 if a critical service check fails
#
validate_local_services() {
    step "Phase 2 — Local service validation"

    service_exists "${RSYSLOG_SERVICE}" || return 2
    service_running "${RSYSLOG_SERVICE}" || return 2

    service_exists "${LOKI_SERVICE}" || return 2
    service_running "${LOKI_SERVICE}" || return 2

    service_exists "${PROMTAIL_SERVICE}" || return 2
    service_running "${PROMTAIL_SERVICE}" || return 2

    service_exists "${GRAFANA_SERVICE}" || return 2
    service_running "${GRAFANA_SERVICE}" || return 2

    pass "Local service validation completed"
    return 0
}

#
# validate_remote_log_directory
# Description:
#  - Verifies the remote log directory used by rsyslog exists.
#
# Preconditions:
#  - Shared system helper library is sourced
#
# Postconditions:
#  - /var/log/remote exists
#
# Returns:
#  - 0 if the remote log directory exists
#  - 2 if the remote log directory is missing
#
validate_remote_log_directory() {
    step "Phase 3 — Remote log directory validation"

    directory_exists "${REMOTE_LOG_DIR}" || return 2

    pass "Remote log directory validation completed"
    return 0
}

#
# validate_http_endpoints
# Description:
#  - Verifies Loki and Grafana HTTP endpoints respond successfully.
#
# Preconditions:
#  - curl is available
#  - Local services are running
#
# Postconditions:
#  - Loki /ready responds successfully
#  - Grafana /login responds successfully
#
# Returns:
#  - 0 if endpoint validation succeeds
#  - 2 if a critical endpoint check fails
#
validate_http_endpoints() {
    step "Phase 4 — HTTP endpoint validation"

    if curl -fsS "${LOKI_BASE_URL}/ready" >/dev/null 2>&1; then
        pass "Loki readiness endpoint responded successfully: ${LOKI_BASE_URL}/ready"
    else
        fail "Loki readiness endpoint did not respond successfully: ${LOKI_BASE_URL}/ready"
        return 2
    fi

    if curl -fsS "${GRAFANA_BASE_URL}/login" >/dev/null 2>&1; then
        pass "Grafana HTTP endpoint responded successfully: ${GRAFANA_BASE_URL}/login"
    else
        fail "Grafana HTTP endpoint did not respond successfully: ${GRAFANA_BASE_URL}/login"
        return 2
    fi

    pass "HTTP endpoint validation completed"
    return 0
}

#
# wait_for_remote_log_message
# Description:
#  - Waits for a real remote sender message to be written somewhere under
#    /var/log/remote.
#
# Preconditions:
#  - EXPECT_REMOTE_SENDER is set to 1
#  - A real external sender will transmit PIPELINE_TEST_MESSAGE
#
# Postconditions:
#  - The expected message is found in a file under /var/log/remote
#
# Returns:
#  - 0 if the message is found
#  - 2 if the timeout is reached without finding the message
#
wait_for_remote_log_message() {
    step "Phase 5 — Wait for real remote sender message"

    local elapsed=0
    local matched_file

    info "Remote sender mode enabled"
    info "Expected message: ${PIPELINE_TEST_MESSAGE}"
    info "Waiting up to ${REMOTE_TEST_TIMEOUT}s for a real external sender"
    info "Example sender command:"
    info "  logger -n <SERVER_IP> -P 514 \"${PIPELINE_TEST_MESSAGE}\""

    while (( elapsed < REMOTE_TEST_TIMEOUT )); do
        matched_file="$(grep -R -l -- "${PIPELINE_TEST_MESSAGE}" "${REMOTE_LOG_DIR}" 2>/dev/null | head -n 1 || true)"

        if [[ -n "${matched_file}" ]]; then
            pass "Remote sender message found in: ${matched_file}"
            return 0
        fi

        sleep "${REMOTE_TEST_POLL_INTERVAL}"
        elapsed=$(( elapsed + REMOTE_TEST_POLL_INTERVAL ))
    done

    fail "Timed out waiting for remote sender message under ${REMOTE_LOG_DIR}"
    return 2
}

#
# build_loki_query_url
# Description:
#  - Builds a Loki query_range URL for the expected pipeline test message.
#
# Preconditions:
#  - Accepts one argument:
#    1. message text
#
# Postconditions:
#  - A valid Loki query URL is written to stdout
#
# Returns:
#  - 0 if URL generation succeeds
#  - 2 if input is invalid
#
build_loki_query_url() {
    local test_message="$1"

    if [[ -z "${test_message}" ]]; then
        fail "Usage: build_loki_query_url <test_message>"
        return 2
    fi

    python3 - "${LOKI_BASE_URL}" "${test_message}" <<'PY'
import sys
import urllib.parse

base_url = sys.argv[1]
test_message = sys.argv[2]

query = '{job="rsyslog"} |= "%s"' % test_message
params = {
    "query": query,
    "limit": "20",
}
print(base_url + "/loki/api/v1/query_range?" + urllib.parse.urlencode(params))
PY
}

#
# query_loki_for_message
# Description:
#  - Queries Loki repeatedly until the expected pipeline test message is found
#    or retry attempts are exhausted.
#
# Preconditions:
#  - Loki is healthy
#  - The expected message has already been written under /var/log/remote
#
# Postconditions:
#  - Loki confirms the expected message is retrievable
#
# Returns:
#  - 0 if the message is found in Loki
#  - 2 if the message is not found after all retries
#
query_loki_for_message() {
    step "Phase 6 — Query Loki for remote sender message"

    local query_url
    local response_body
    local attempt

    query_url="$(build_loki_query_url "${PIPELINE_TEST_MESSAGE}")" || return 2

    for (( attempt=1; attempt<=LOKI_QUERY_RETRIES; attempt++ )); do
        info "Loki query attempt ${attempt}/${LOKI_QUERY_RETRIES}"

        response_body="$(curl -fsS "${query_url}" 2>/dev/null || true)"

        if [[ -n "${response_body}" ]] && grep -Fq "${PIPELINE_TEST_MESSAGE}" <<<"${response_body}"; then
            pass "Loki returned the expected pipeline test message"
            return 0
        fi

        sleep "${LOKI_QUERY_SLEEP_SECONDS}"
    done

    fail "Loki did not return the expected pipeline test message"
    return 2
}

#
# print_readiness_summary
# Description:
#  - Prints a concise readiness-mode summary.
#
# Preconditions:
#  - Readiness validation has completed successfully
#
# Postconditions:
#  - Summary information is printed to stdout
#
# Returns:
#  - 0
#
print_readiness_summary() {
    step "Readiness Summary"

    info "Local stack services are healthy"
    info "Remote log directory exists: ${REMOTE_LOG_DIR}"
    info "Loki is reachable: ${LOKI_BASE_URL}/ready"
    info "Grafana is reachable: ${GRAFANA_BASE_URL}/login"
    info "For real end-to-end validation, rerun with EXPECT_REMOTE_SENDER=1"

    pass "Readiness pipeline validation completed successfully"
    return 0
}

#
# print_end_to_end_summary
# Description:
#  - Prints a concise remote sender mode summary.
#
# Preconditions:
#  - End-to-end validation has completed successfully
#
# Postconditions:
#  - Summary information is printed to stdout
#
# Returns:
#  - 0
#
print_end_to_end_summary() {
    step "End-to-End Summary"

    info "A real remote sender message was received under ${REMOTE_LOG_DIR}"
    info "Promtail shipped the message into Loki"
    info "Loki returned the message successfully"
    info "Grafana is reachable as the visibility layer"

    pass "End-to-end pipeline validation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Validate centralized logging pipeline"

    require_root || die "Root privilege check failed"
    require_runtime_commands || die "Validation command checks failed"
    validate_local_services || die "Local service validation failed"
    validate_remote_log_directory || die "Remote log directory validation failed"
    validate_http_endpoints || die "HTTP endpoint validation failed"

    if [[ "${EXPECT_REMOTE_SENDER}" == "1" ]]; then
        wait_for_remote_log_message || die "Remote sender message validation failed"
        query_loki_for_message || die "Loki end-to-end query validation failed"
        print_end_to_end_summary
    else
        print_readiness_summary
    fi

    pass "validate-pipeline.sh completed successfully"
    return 0
}

main "$@"
