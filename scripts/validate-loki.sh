#!/usr/bin/env bash
#
# validate-loki.sh
#
# Validates a Grafana Loki installation in staged modes.
#
# Purpose:
#  - Verify Loki is installed and running correctly
#  - Confirm the HTTP API is reachable and healthy
#  - Optionally perform a real push/query functional validation
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Avoid false positives by using a real push/query round-trip
#  - Use shared helper libraries for service, system, and output logic
#
# Validation Modes:
#  1. Readiness Mode (default)
#     - Confirms the Loki service exists
#     - Confirms the Loki service is running
#     - Confirms port 3100 is listening
#     - Confirms the /ready endpoint responds successfully
#
#  2. Functional Validation Mode
#     - Enabled with EXPECT_INGESTION=1
#     - Includes all readiness checks
#     - Pushes a real test log entry into Loki
#     - Queries Loki for the test entry
#     - Confirms Loki can receive, store, and return log data
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Required library files are present and sourceable
#
# Postconditions:
#  - Readiness mode confirms Loki health
#  - Functional mode confirms Loki ingestion and retrieval
#
# Environment Variables:
#  - LIB_DIR
#      Override shared library path
#      Default: /home/graylog/infra-bash-lib
#
#  - LOKI_HTTP_HOST
#      Loki HTTP host
#      Default: 127.0.0.1
#
#  - LOKI_HTTP_PORT
#      Loki HTTP listen port
#      Default: 3100
#
#  - EXPECT_INGESTION
#      When set to 1, perform push/query functional validation
#      Default: 0
#
#  - LOKI_QUERY_RETRIES
#      Number of query retry attempts
#      Default: 10
#
#  - LOKI_QUERY_SLEEP_SECONDS
#      Delay between query attempts
#      Default: 2
#
# Usage:
#  sudo ./scripts/validate-loki.sh
#
# Stronger validation:
#  sudo EXPECT_INGESTION=1 ./scripts/validate-loki.sh
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
#   sudo ./scripts/validate-loki.sh
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

readonly LOKI_HTTP_HOST="${LOKI_HTTP_HOST:-127.0.0.1}"
readonly LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
readonly LOKI_BASE_URL="http://${LOKI_HTTP_HOST}:${LOKI_HTTP_PORT}"

readonly EXPECT_INGESTION="${EXPECT_INGESTION:-0}"
readonly LOKI_QUERY_RETRIES="${LOKI_QUERY_RETRIES:-10}"
readonly LOKI_QUERY_SLEEP_SECONDS="${LOKI_QUERY_SLEEP_SECONDS:-2}"

readonly VALIDATION_STREAM_JOB="loki-validation"
readonly VALIDATION_STREAM_SOURCE="validate-loki.sh"

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
#  - Verifies the commands required for Loki validation are available.
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
    command_exists python3 || return 2

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
#  - Verifies the Loki service exists.
#
# Preconditions:
#  - Shared service helper library is sourced
#
# Postconditions:
#  - loki.service exists
#
# Returns:
#  - 0 if service exists
#  - 2 if service is missing
#
validate_service_exists() {
    step "Phase 2 — Service registration validation"

    service_exists loki || return 2
    pass "Loki service registration validated"
    return 0
}

#
# validate_service_running
# Description:
#  - Verifies the Loki service is running.
#
# Preconditions:
#  - Loki service exists
#
# Postconditions:
#  - loki.service is running
#
# Returns:
#  - 0 if service is running
#  - 2 if service is not running
#
validate_service_running() {
    step "Phase 3 — Service status validation"

    service_running loki || return 2
    pass "Loki service status validated"
    return 0
}

#
# validate_listener
# Description:
#  - Verifies the Loki HTTP listener is active on the expected port.
#
# Preconditions:
#  - Loki service is running
#
# Postconditions:
#  - Port 3100 listener is validated
#
# Returns:
#  - 0 if listener validation succeeds
#  - 2 if listener validation fails
#
validate_listener() {
    step "Phase 4 — Listener validation"

    if command_exists ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|:)${LOKI_HTTP_PORT}$"; then
            pass "Port ${LOKI_HTTP_PORT} is listening"
            return 0
        fi
    elif command_exists netstat >/dev/null 2>&1; then
        if netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)${LOKI_HTTP_PORT}$"; then
            pass "Port ${LOKI_HTTP_PORT} is listening"
            return 0
        fi
    fi

    fail "Port ${LOKI_HTTP_PORT} is not listening"
    return 2
}

#
# validate_ready_endpoint
# Description:
#  - Verifies the Loki /ready endpoint responds successfully.
#
# Preconditions:
#  - Loki service is running
#
# Postconditions:
#  - /ready responds successfully
#
# Returns:
#  - 0 if readiness check succeeds
#  - 2 if readiness check fails
#
validate_ready_endpoint() {
    step "Phase 5 — Readiness endpoint validation"

    if curl -fsS "${LOKI_BASE_URL}/ready" >/dev/null 2>&1; then
        pass "Loki readiness endpoint responded successfully: ${LOKI_BASE_URL}/ready"
        return 0
    fi

    fail "Loki readiness endpoint did not respond successfully: ${LOKI_BASE_URL}/ready"
    return 2
}

#
# build_validation_payload
# Description:
#  - Builds a JSON payload for Loki push API validation.
#
# Preconditions:
#  - Accepts two arguments:
#    1. nanosecond timestamp
#    2. test message
#
# Postconditions:
#  - JSON payload is written to stdout
#
# Returns:
#  - 0 if payload generation succeeds
#  - 2 if input is invalid
#
build_validation_payload() {
    local timestamp_ns="$1"
    local test_message="$2"

    if [[ -z "${timestamp_ns}" || -z "${test_message}" ]]; then
        fail "Usage: build_validation_payload <timestamp_ns> <test_message>"
        return 2
    fi

    python3 - "${timestamp_ns}" "${test_message}" <<'PY'
import json
import sys

timestamp_ns = sys.argv[1]
test_message = sys.argv[2]

payload = {
    "streams": [
        {
            "stream": {
                "job": "loki-validation",
                "source": "validate-loki.sh",
            },
            "values": [
                [timestamp_ns, test_message]
            ],
        }
    ]
}

print(json.dumps(payload, separators=(",", ":")))
PY
}

#
# push_validation_log
# Description:
#  - Pushes a real test log entry into Loki.
#
# Preconditions:
#  - Loki is healthy
#
# Postconditions:
#  - Loki push API receives the validation payload
#
# Returns:
#  - 0 if push succeeds
#  - 2 if push fails
#
push_validation_log() {
    step "Phase 6 — Push validation log entry"

    local timestamp_ns="$1"
    local test_message="$2"
    local payload

    if [[ -z "${timestamp_ns}" || -z "${test_message}" ]]; then
        fail "Usage: push_validation_log <timestamp_ns> <test_message>"
        return 2
    fi

    payload="$(build_validation_payload "${timestamp_ns}" "${test_message}")" || return 2

    if curl -fsS \
        -X POST \
        -H "Content-Type: application/json" \
        --data-raw "${payload}" \
        "${LOKI_BASE_URL}/loki/api/v1/push" >/dev/null 2>&1; then
        pass "Validation log entry pushed to Loki"
        return 0
    fi

    fail "Failed to push validation log entry to Loki"
    return 2
}

#
# query_for_validation_log
# Description:
#  - Queries Loki until the expected validation log entry is returned
#    or retries are exhausted.
#
# Preconditions:
#  - A validation log has already been pushed
#
# Postconditions:
#  - Loki query confirms the validation message is retrievable
#
# Returns:
#  - 0 if query succeeds
#  - 2 if query fails
#
query_for_validation_log() {
    local test_message="$1"
    local attempt
    local response_body

    if [[ -z "${test_message}" ]]; then
        fail "Usage: query_for_validation_log <test_message>"
        return 2
    fi

    for (( attempt = 1; attempt <= LOKI_QUERY_RETRIES; attempt++ )); do
        info "Query attempt ${attempt}/${LOKI_QUERY_RETRIES}"

        response_body="$(curl -fsS \
            -G \
            --data-urlencode "query={job=\"${VALIDATION_STREAM_JOB}\",source=\"${VALIDATION_STREAM_SOURCE}\"}" \
            --data-urlencode "start=$(($(date +%s%N) - 300000000000))" \
            --data-urlencode "end=$(date +%s%N)" \
            --data-urlencode "limit=50" \
            --data-urlencode "direction=backward" \
            "${LOKI_BASE_URL}/loki/api/v1/query_range" 2>/dev/null || true)"

        if [[ -n "${response_body}" ]] && grep -Fq "${test_message}" <<<"${response_body}"; then
            pass "Validation log entry was returned by Loki query"
            return 0
        fi

        if (( attempt < LOKI_QUERY_RETRIES )); then
            info "Validation log entry not returned yet; waiting ${LOKI_QUERY_SLEEP_SECONDS}s"
            sleep "${LOKI_QUERY_SLEEP_SECONDS}"
        fi
    done

    fail "Validation log entry was not returned by Loki after ${LOKI_QUERY_RETRIES} attempts"
    return 2
}

#
# run_functional_validation
# Description:
#  - Performs a real Loki push/query round-trip test.
#
# Preconditions:
#  - Loki readiness checks have already passed
#
# Postconditions:
#  - Loki ingestion and retrieval are validated
#
# Returns:
#  - 0 if functional validation succeeds
#  - 2 if functional validation fails
#
run_functional_validation() {
    step "Phase 7 — Functional ingestion/query validation"

    local timestamp_ns
    local test_id
    local test_message

    timestamp_ns="$(date +%s%N)"
    test_id="$(date +%s)"
    test_message="loki validation test message id=${test_id}"

    info "Validation message: ${test_message}"

    push_validation_log "${timestamp_ns}" "${test_message}" || return 2
    query_for_validation_log "${test_message}" || return 2

    pass "Functional Loki ingestion/query validation succeeded"
    return 0
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

    info "Service: loki.service"
    info "Endpoint: ${LOKI_BASE_URL}"
    info "Readiness mode: enabled"

    if [[ "${EXPECT_INGESTION}" == "1" ]]; then
        info "Functional ingestion/query validation: enabled"
    else
        info "Functional ingestion/query validation: skipped"
    fi

    pass "Loki validation completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Validate Loki"

    require_root || die "Root privilege check failed"
    require_runtime_commands || die "Validation command checks failed"
    validate_service_exists || die "Loki service registration validation failed"
    validate_service_running || die "Loki service status validation failed"
    validate_listener || die "Loki listener validation failed"
    validate_ready_endpoint || die "Loki readiness endpoint validation failed"

    if [[ "${EXPECT_INGESTION}" == "1" ]]; then
        run_functional_validation || die "Loki functional ingestion/query validation failed"
    else
        info "EXPECT_INGESTION is not enabled; functional push/query validation skipped"
    fi

    print_validation_summary
    pass "validate-loki.sh completed successfully"
    return 0
}

main "$@"
