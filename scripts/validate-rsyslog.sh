#!/usr/bin/env bash
#
# validate-rsyslog.sh
#
# Validates rsyslog as the centralized log collection layer.
#
# Purpose:
#  - Verify rsyslog is installed and running
#  - Verify remote syslog configuration is present and valid
#  - Verify port 514 listener availability
#  - Verify the remote log directory is prepared
#  - Optionally verify a real external sender writes a test message to disk
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep validation first-class and fail fast on critical checks
#  - Avoid fake loopback assumptions where real remote behavior matters
#  - Support readiness validation by default
#  - Support true remote sender validation when explicitly enabled
#
# Validation Modes:
#  1. Readiness Mode (default)
#     - Validates installation, service, config, listener, and directory setup
#     - Does NOT pretend loopback traffic is a real remote sender
#
#  2. Remote Sender Mode
#     - Enabled with EXPECT_REMOTE_SENDER=1
#     - Waits for a real external sender
#     - Verifies the test message is written under /var/log/remote
#
# Preconditions:
#  - Script is run with sufficient privileges
#  - Required library files are present and sourceable
#
# Postconditions:
#  - Readiness mode confirms rsyslog layer health
#  - Remote sender mode confirms real remote log write behavior
#
# Environment Variables:
#  - LIB_DIR
#      Override shared library path
#      Default: /home/graylog/infra-bash-lib
#
#  - ENABLE_TCP_SYSLOG
#      Set to 1 to enable TCP 514 listener in generated config
#      Default: 0
#
#  - EXPECT_REMOTE_SENDER
#      Set to 1 to require a real external sender
#      Default: 0
#
#  - REMOTE_SENDER_HOSTNAME
#      Optional expected sender hostname directory under /var/log/remote
#      Default: unset
#
#  - REMOTE_TEST_TIMEOUT
#      Seconds to wait for remote test log
#      Default: 30
#
#  - REMOTE_TEST_POLL_INTERVAL
#      Seconds between checks
#      Default: 2
#
# Usage:
#  sudo ./scripts/validate-rsyslog.sh
#
# Real remote sender validation:
#  sudo EXPECT_REMOTE_SENDER=1 ./scripts/validate-rsyslog.sh
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
#   sudo ./scripts/validate-rsyslog.sh
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
readonly RSYSLOG_CONFIG_FILE="/etc/rsyslog.d/10-remote.conf"
readonly REMOTE_LOG_DIR="/var/log/remote"

readonly TEST_MESSAGE_TAG="rsyslog-validation"
readonly TEST_MESSAGE="rsyslog validation test message"

readonly ENABLE_TCP_SYSLOG="${ENABLE_TCP_SYSLOG:-0}"
readonly EXPECT_REMOTE_SENDER="${EXPECT_REMOTE_SENDER:-0}"
readonly REMOTE_SENDER_HOSTNAME="${REMOTE_SENDER_HOSTNAME:-}"
readonly REMOTE_TEST_TIMEOUT="${REMOTE_TEST_TIMEOUT:-30}"
readonly REMOTE_TEST_POLL_INTERVAL="${REMOTE_TEST_POLL_INTERVAL:-2}"

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
# require_commands
# Description:
#  - Verifies the commands required for rsyslog validation are available.
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
require_commands() {
    step "Phase 1 — Required command checks"

    command_exists rsyslogd || return 2
    command_exists logger || return 2
    command_exists grep || return 2
    command_exists awk || return 2
    command_exists sleep || return 2
    command_exists find || return 2

    if command_exists ss >/dev/null 2>&1; then
        pass "Socket inspection command available: ss"
        return 0
    fi

    if command_exists netstat >/dev/null 2>&1; then
        pass "Socket inspection command available: netstat"
        return 0
    fi

    fail "Neither ss nor netstat is available for port validation"
    return 2
}

#
# check_rsyslog_service
# Description:
#  - Verifies the rsyslog service exists and is running.
#
# Preconditions:
#  - Shared service helper library is sourced
#
# Postconditions:
#  - rsyslog.service exists
#  - rsyslog.service is running
#
# Returns:
#  - 0 if service validation succeeds
#  - 2 if a critical service check fails
#
check_rsyslog_service() {
    step "Phase 2 — Service validation"

    service_exists "${RSYSLOG_SERVICE}" || return 2
    service_running "${RSYSLOG_SERVICE}" || return 2

    pass "rsyslog service validation completed"
    return 0
}

#
# prepare_remote_log_directory
# Description:
#  - Verifies the remote log directory exists and is accessible.
#
# Preconditions:
#  - Shared system helper library is sourced
#
# Postconditions:
#  - /var/log/remote exists
#
# Returns:
#  - 0 if directory validation succeeds
#  - 2 if a critical directory check fails
#
prepare_remote_log_directory() {
    step "Phase 3 — Remote log directory validation"

    ensure_directory "${REMOTE_LOG_DIR}" || return 2
    directory_exists "${REMOTE_LOG_DIR}" || return 2

    pass "Remote log directory is ready: ${REMOTE_LOG_DIR}"
    return 0
}

#
# write_rsyslog_remote_config
# Description:
#  - Writes the rsyslog remote input and remote file storage configuration.
#  - Enables UDP 514 by default and TCP 514 optionally.
#
# Preconditions:
#  - Remote log directory exists
#  - Shared filesystem helper functions are sourced
#
# Postconditions:
#  - /etc/rsyslog.d/10-remote.conf exists
#
# Returns:
#  - 0 if config writing succeeds
#  - 2 if config writing fails
#
write_rsyslog_remote_config() {
    step "Phase 4 — Write rsyslog remote logging configuration"

    backup_file "${RSYSLOG_CONFIG_FILE}" >/dev/null 2>&1 || true

    write_file "${RSYSLOG_CONFIG_FILE}" <<EOF
# Remote syslog input and file storage
# Generated by validate-rsyslog.sh

module(load="imudp")
input(type="imudp" port="514")
$(if [[ "${ENABLE_TCP_SYSLOG}" == "1" ]]; then
cat <<'TCPBLOCK'
module(load="imtcp")
input(type="imtcp" port="514")
TCPBLOCK
fi)

template(name="RemoteLogsPath" type="string"
         string="${REMOTE_LOG_DIR}/%HOSTNAME%/%PROGRAMNAME%.log")

*.* ?RemoteLogsPath
& stop
EOF

    file_exists "${RSYSLOG_CONFIG_FILE}" || return 2
    pass "rsyslog remote configuration written"
    return 0
}

#
# validate_rsyslog_config
# Description:
#  - Validates rsyslog configuration syntax.
#
# Preconditions:
#  - rsyslog config file exists
#
# Postconditions:
#  - rsyslogd syntax validation succeeds
#
# Returns:
#  - 0 if configuration is valid
#  - 2 if configuration validation fails
#
validate_rsyslog_config() {
    step "Phase 5 — rsyslog configuration syntax check"

    if rsyslogd -N1 >/dev/null 2>&1; then
        pass "rsyslog configuration syntax is valid"
        return 0
    fi

    fail "rsyslog configuration syntax validation failed"
    return 2
}

#
# restart_rsyslog_service
# Description:
#  - Restarts rsyslog after configuration changes and confirms it is running.
#
# Preconditions:
#  - rsyslog config is valid
#
# Postconditions:
#  - rsyslog is restarted
#  - rsyslog is running
#
# Returns:
#  - 0 if restart succeeds
#  - 2 if restart fails
#
restart_rsyslog_service() {
    step "Phase 6 — Restart rsyslog"

    if systemctl restart "${RSYSLOG_SERVICE}.service" >/dev/null 2>&1; then
        pass "rsyslog service restarted"
    else
        fail "Failed to restart rsyslog service"
        return 2
    fi

    service_running "${RSYSLOG_SERVICE}" || return 2
    return 0
}

#
# is_udp_514_listening_with_ss
# Description:
#  - Checks whether UDP 514 is listening using ss.
#
# Preconditions:
#  - ss command is available
#
# Postconditions:
#  - Exit status reflects listener presence
#
# Returns:
#  - 0 if UDP 514 is listening
#  - 1 if UDP 514 is not listening
#
is_udp_514_listening_with_ss() {
    ss -H -lun 2>/dev/null | awk '
        $0 ~ /(^|[[:space:]])[^[:space:]]+:514([[:space:]]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

#
# is_tcp_514_listening_with_ss
# Description:
#  - Checks whether TCP 514 is listening using ss.
#
# Preconditions:
#  - ss command is available
#
# Postconditions:
#  - Exit status reflects listener presence
#
# Returns:
#  - 0 if TCP 514 is listening
#  - 1 if TCP 514 is not listening
#
is_tcp_514_listening_with_ss() {
    ss -H -ltn 2>/dev/null | awk '
        $0 ~ /(^|[[:space:]])[^[:space:]]+:514([[:space:]]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

#
# is_udp_514_listening_with_netstat
# Description:
#  - Checks whether UDP 514 is listening using netstat.
#
# Preconditions:
#  - netstat command is available
#
# Postconditions:
#  - Exit status reflects listener presence
#
# Returns:
#  - 0 if UDP 514 is listening
#  - 1 if UDP 514 is not listening
#
is_udp_514_listening_with_netstat() {
    netstat -lun 2>/dev/null | awk '
        $0 ~ /(^|[[:space:]])[^[:space:]]+:514([[:space:]]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

#
# is_tcp_514_listening_with_netstat
# Description:
#  - Checks whether TCP 514 is listening using netstat.
#
# Preconditions:
#  - netstat command is available
#
# Postconditions:
#  - Exit status reflects listener presence
#
# Returns:
#  - 0 if TCP 514 is listening
#  - 1 if TCP 514 is not listening
#
is_tcp_514_listening_with_netstat() {
    netstat -ltn 2>/dev/null | awk '
        $0 ~ /(^|[[:space:]])[^[:space:]]+:514([[:space:]]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

#
# check_syslog_port
# Description:
#  - Verifies UDP 514 is listening.
#  - Verifies TCP 514 is listening when explicitly enabled.
#
# Preconditions:
#  - rsyslog has been restarted successfully
#
# Postconditions:
#  - Listener validation is completed
#
# Returns:
#  - 0 if port validation succeeds
#  - 2 if port validation fails
#
check_syslog_port() {
    step "Phase 7 — Listener validation"

    if command_exists ss >/dev/null 2>&1; then
        if is_udp_514_listening_with_ss; then
            pass "UDP 514 is listening"
        else
            warn "Current UDP listeners from ss:"
            ss -lun 2>/dev/null || true
            fail "UDP 514 is not listening"
            return 2
        fi

        if [[ "${ENABLE_TCP_SYSLOG}" == "1" ]]; then
            if is_tcp_514_listening_with_ss; then
                pass "TCP 514 is listening"
            else
                warn "Current TCP listeners from ss:"
                ss -ltn 2>/dev/null || true
                fail "TCP 514 is not listening"
                return 2
            fi
        fi

        return 0
    fi

    if command_exists netstat >/dev/null 2>&1; then
        if is_udp_514_listening_with_netstat; then
            pass "UDP 514 is listening"
        else
            warn "Current UDP listeners from netstat:"
            netstat -lun 2>/dev/null || true
            fail "UDP 514 is not listening"
            return 2
        fi

        if [[ "${ENABLE_TCP_SYSLOG}" == "1" ]]; then
            if is_tcp_514_listening_with_netstat; then
                pass "TCP 514 is listening"
            else
                warn "Current TCP listeners from netstat:"
                netstat -ltn 2>/dev/null || true
                fail "TCP 514 is not listening"
                return 2
            fi
        fi

        return 0
    fi

    fail "Unable to validate syslog listener port"
    return 2
}

#
# send_test_message
# Description:
#  - In readiness mode, explicitly skips self-injection by design.
#  - In remote sender mode, prints instructions for a real remote sender.
#
# Preconditions:
#  - Listener validation has completed
#
# Postconditions:
#  - Operator is informed of the expected sender behavior
#
# Returns:
#  - 0 if the phase completes successfully
#
send_test_message() {
    step "Phase 8 — Test message phase"

    if [[ "${EXPECT_REMOTE_SENDER}" == "1" ]]; then
        info "Remote sender mode enabled"
        info "Waiting for a real external sender to transmit the test message"
        info "Expected tag: ${TEST_MESSAGE_TAG}"
        info "Expected message: ${TEST_MESSAGE}"
        info "Example command from remote host:"
        info "logger -n <this-server-ip> -P 514 -d -t '${TEST_MESSAGE_TAG}' -- '${TEST_MESSAGE}'"

        if [[ "${ENABLE_TCP_SYSLOG}" == "1" ]]; then
            info "TCP is enabled, but the example still uses UDP unless the sender is changed explicitly"
        fi

        pass "Remote sender instructions issued"
        return 0
    fi

    warn "Skipping self-injection because loopback traffic is not a trustworthy remote syslog test"
    info "Set EXPECT_REMOTE_SENDER=1 and send the test message from another machine"
    pass "Self-injection skipped by design"
    return 0
}

#
# verify_test_log_written
# Description:
#  - In remote sender mode, waits for the expected test message to appear
#    under /var/log/remote.
#  - In readiness mode, skips remote write validation by design.
#
# Preconditions:
#  - rsyslog is listening for remote messages
#
# Postconditions:
#  - Remote sender mode confirms the test message is written to disk
#
# Returns:
#  - 0 if validation succeeds
#  - 2 if validation fails
#
verify_test_log_written() {
    step "Phase 9 — Log write validation"

    local elapsed=0
    local search_root="${REMOTE_LOG_DIR}"
    local expected_file=""
    local found_file=""

    if [[ "${EXPECT_REMOTE_SENDER}" != "1" ]]; then
        warn "Remote log write validation skipped because no real external sender was required"
        info "This run validated rsyslog readiness only: service, config, listener, and directory setup"
        return 0
    fi

    if [[ -n "${REMOTE_SENDER_HOSTNAME}" ]]; then
        search_root="${REMOTE_LOG_DIR}/${REMOTE_SENDER_HOSTNAME}"
        expected_file="${search_root}/${TEST_MESSAGE_TAG}.log"
        info "Restricting search to expected sender hostname path: ${search_root}"
    else
        info "Searching entire remote log tree: ${REMOTE_LOG_DIR}"
    fi

    while (( elapsed < REMOTE_TEST_TIMEOUT )); do
        if [[ -n "${expected_file}" && -f "${expected_file}" ]]; then
            if grep -F -- "${TEST_MESSAGE}" "${expected_file}" >/dev/null 2>&1; then
                pass "Validation test message was written to disk: ${expected_file}"
                return 0
            fi
        fi

        found_file="$(grep -R -l -F -- "${TEST_MESSAGE}" "${search_root}" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${found_file}" ]]; then
            pass "Validation test message was written to disk: ${found_file}"
            return 0
        fi

        sleep "${REMOTE_TEST_POLL_INTERVAL}"
        elapsed=$((elapsed + REMOTE_TEST_POLL_INTERVAL))
    done

    if [[ -n "${expected_file}" ]]; then
        warn "Expected file not found or did not contain the test message: ${expected_file}"
    fi

    warn "Current remote log tree under ${search_root}:"
    find "${search_root}" -maxdepth 3 -type f 2>/dev/null || true

    fail "Validation test message was not found under ${search_root} within ${REMOTE_TEST_TIMEOUT} seconds"
    return 2
}

#
# print_success_summary
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
print_success_summary() {
    step "Validation Summary"

    pass "Using shared library path: ${LIB_DIR}"
    pass "rsyslog is installed and running"
    pass "Remote syslog reception is configured"
    pass "Port 514 listener validation passed"

    if [[ "${EXPECT_REMOTE_SENDER}" == "1" ]]; then
        pass "Remote sender end-to-end validation passed"
    else
        info "Remote sender end-to-end validation was intentionally skipped"
        info "To fully validate remote ingestion, rerun with EXPECT_REMOTE_SENDER=1 and send a test message from another machine"
    fi

    info "rsyslog layer is ready for upper logging stack components"
    info "Next stages: Loki, Grafana, and Promtail"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Validate rsyslog"

    require_root || die "Root privileges are required"
    require_commands || die "Required command validation failed"
    check_rsyslog_service || die "rsyslog service validation failed"
    prepare_remote_log_directory || die "Remote log directory validation failed"
    write_rsyslog_remote_config || die "Failed to write rsyslog remote configuration"
    validate_rsyslog_config || die "rsyslog configuration syntax validation failed"
    restart_rsyslog_service || die "Failed to restart rsyslog"
    check_syslog_port || die "Syslog listener validation failed"
    send_test_message || die "Failed during test message phase"
    verify_test_log_written || die "rsyslog log write validation failed"

    print_success_summary
    pass "validate-rsyslog.sh completed successfully"
    return 0
}

main "$@"
