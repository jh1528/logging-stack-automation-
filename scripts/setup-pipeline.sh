#!/usr/bin/env bash
#
# setup-pipeline.sh
#
# Configures the centralized logging pipeline connection between:
#  - rsyslog remote log files under /var/log/remote
#  - Promtail file scraping
#  - Loki log ingestion
#  - Grafana Loki data source provisioning
#
# Purpose:
#  - Generate a Promtail configuration that watches rsyslog's remote log tree
#  - Configure Promtail to push scraped logs into Loki
#  - Provision Grafana with Loki as the default data source
#  - Restart affected services safely
#  - Validate local service health after configuration changes
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep setup readable, repeatable, and fail-fast
#  - Use shared infra-bash-lib helpers for consistent output and health checks
#  - Back up existing configuration files before overwriting them
#  - Keep Promtail labels aligned with validate-pipeline.sh
#  - Avoid pretending setup alone proves end-to-end ingestion
#
# Important Label Contract:
#  - Promtail writes logs with label: job="rsyslog"
#  - validate-pipeline.sh queries Loki with: {job="rsyslog"}
#  - Do not change this label unless the validator is updated too
#
# Preconditions:
#  - Script is run with root privileges
#  - Required library files are present and sourceable
#  - Promtail, Loki, Grafana, and rsyslog are already installed
#  - /var/log/remote is the rsyslog remote log directory
#  - Loki listens on the configured HTTP endpoint
#  - Grafana provisioning directory is writable
#
# Postconditions:
#  - Promtail config exists at /etc/promtail/config.yaml
#  - Grafana Loki data source provisioning file exists
#  - Promtail and Grafana services are restarted
#  - Loki, Promtail, Grafana, and rsyslog are locally checked
#  - Loki and Grafana HTTP endpoints are reachable
#
# Environment Variables:
#  - LIB_DIR
#      Override shared library path
#      Default: /home/graylog/infra-bash-lib
#
#  - PROMTAIL_CONFIG
#      Override Promtail config path
#      Default: /etc/promtail/config.yaml
#
#  - PROMTAIL_POSITIONS_FILE
#      Override Promtail positions file path
#      Default: /var/lib/promtail/positions.yaml
#
#  - GRAFANA_DATASOURCE_DIR
#      Override Grafana data source provisioning directory
#      Default: /etc/grafana/provisioning/datasources
#
#  - GRAFANA_LOKI_DATASOURCE_FILE
#      Override Grafana Loki data source provisioning file path
#      Default: ${GRAFANA_DATASOURCE_DIR}/loki.yaml
#
#  - REMOTE_LOG_DIR
#      Override rsyslog remote log directory
#      Default: /var/log/remote
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
#  - HTTP_ENDPOINT_RETRIES
#      Number of endpoint readiness attempts after service restart
#      Default: 15
#
#  - HTTP_ENDPOINT_SLEEP_SECONDS
#      Seconds to sleep between endpoint readiness attempts
#      Default: 2
#
#  - PROMTAIL_HTTP_PORT
#      Promtail HTTP listen port
#      Default: 9080
#
# Usage:
#  sudo ./scripts/setup-pipeline.sh
#
# Returns:
#  - 0 if setup succeeds
#  - 2 if a critical setup step fails
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
#   sudo ./scripts/setup-pipeline.sh
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

readonly PROMTAIL_CONFIG="${PROMTAIL_CONFIG:-/etc/promtail/config.yaml}"
readonly PROMTAIL_CONFIG_DIR="$(dirname "${PROMTAIL_CONFIG}")"
readonly PROMTAIL_POSITIONS_FILE="${PROMTAIL_POSITIONS_FILE:-/var/lib/promtail/positions.yaml}"
readonly PROMTAIL_POSITIONS_DIR="$(dirname "${PROMTAIL_POSITIONS_FILE}")"
readonly PROMTAIL_HTTP_PORT="${PROMTAIL_HTTP_PORT:-9080}"

readonly GRAFANA_DATASOURCE_DIR="${GRAFANA_DATASOURCE_DIR:-/etc/grafana/provisioning/datasources}"
readonly GRAFANA_LOKI_DATASOURCE_FILE="${GRAFANA_LOKI_DATASOURCE_FILE:-${GRAFANA_DATASOURCE_DIR}/loki.yaml}"

readonly REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-/var/log/remote}"

readonly LOKI_HTTP_HOST="${LOKI_HTTP_HOST:-127.0.0.1}"
readonly LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
readonly LOKI_BASE_URL="http://${LOKI_HTTP_HOST}:${LOKI_HTTP_PORT}"
readonly LOKI_PUSH_URL="${LOKI_BASE_URL}/loki/api/v1/push"

readonly GRAFANA_HTTP_HOST="${GRAFANA_HTTP_HOST:-127.0.0.1}"
readonly GRAFANA_HTTP_PORT="${GRAFANA_HTTP_PORT:-3000}"
readonly GRAFANA_BASE_URL="http://${GRAFANA_HTTP_HOST}:${GRAFANA_HTTP_PORT}"

readonly PROMTAIL_JOB_NAME="system_remote_logs"
readonly PROMTAIL_LOKI_LABEL_JOB="rsyslog"

readonly HTTP_ENDPOINT_RETRIES="${HTTP_ENDPOINT_RETRIES:-15}"
readonly HTTP_ENDPOINT_SLEEP_SECONDS="${HTTP_ENDPOINT_SLEEP_SECONDS:-2}"

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
#  - Verifies the commands required for pipeline setup are available.
#
# Preconditions:
#  - Shared system helper library is sourced
#
# Postconditions:
#  - Required setup commands are available
#
# Returns:
#  - 0 if all required commands exist
#  - 2 if a critical command is missing
#
require_runtime_commands() {
    step "Phase 1 — Setup command checks"

    command_exists cat || return 2
    command_exists chmod || return 2
    command_exists chown || return 2
    command_exists cp || return 2
    command_exists curl || return 2
    command_exists date || return 2
    command_exists dirname || return 2
    command_exists install || return 2
    command_exists mkdir || return 2
    command_exists systemctl || return 2
    command_exists tee || return 2

    pass "Setup command checks completed"
    return 0
}

#
# validate_required_services_exist
# Description:
#  - Verifies the required pipeline services exist before configuration begins.
#
# Preconditions:
#  - Shared service helper library is sourced
#  - systemd is available
#
# Postconditions:
#  - rsyslog, loki, promtail, and grafana-server services are known to systemd
#
# Returns:
#  - 0 if all services exist
#  - 2 if a critical service is missing
#
validate_required_services_exist() {
    step "Phase 2 — Required service existence checks"

    service_exists "${RSYSLOG_SERVICE}" || return 2
    service_exists "${LOKI_SERVICE}" || return 2
    service_exists "${PROMTAIL_SERVICE}" || return 2
    service_exists "${GRAFANA_SERVICE}" || return 2

    pass "Required service existence checks completed"
    return 0
}

#
# validate_required_paths
# Description:
#  - Verifies required input directories exist before writing configuration.
#  - Creates owned configuration directories when safe to do so.
#
# Preconditions:
#  - Script is running as root
#  - Shared system helper library is sourced
#
# Postconditions:
#  - Remote log directory exists
#  - Promtail config directory exists
#  - Promtail positions directory exists
#  - Grafana data source provisioning directory exists
#
# Returns:
#  - 0 if required paths are ready
#  - 2 if a critical path cannot be prepared
#
validate_required_paths() {
    step "Phase 3 — Required path checks"

    directory_exists "${REMOTE_LOG_DIR}" || return 2

    mkdir -p "${PROMTAIL_CONFIG_DIR}" || {
        fail "Failed to create Promtail config directory: ${PROMTAIL_CONFIG_DIR}"
        return 2
    }
    pass "Promtail config directory ready: ${PROMTAIL_CONFIG_DIR}"

    mkdir -p "${PROMTAIL_POSITIONS_DIR}" || {
        fail "Failed to create Promtail positions directory: ${PROMTAIL_POSITIONS_DIR}"
        return 2
    }
    pass "Promtail positions directory ready: ${PROMTAIL_POSITIONS_DIR}"

    mkdir -p "${GRAFANA_DATASOURCE_DIR}" || {
        fail "Failed to create Grafana data source directory: ${GRAFANA_DATASOURCE_DIR}"
        return 2
    }
    pass "Grafana data source directory ready: ${GRAFANA_DATASOURCE_DIR}"

    pass "Required path checks completed"
    return 0
}

#
# backup_file_if_present
# Description:
#  - Creates a timestamped backup of a target file if it already exists.
#
# Preconditions:
#  - Accepts one argument:
#    1. Absolute or relative file path to back up
#  - Parent directory is readable
#
# Postconditions:
#  - If the file exists, a timestamped backup is created beside it
#  - If the file does not exist, no backup is created
#
# Returns:
#  - 0 if backup is successful or unnecessary
#  - 2 if backup is required but fails
#
backup_file_if_present() {
    local target_file="$1"
    local timestamp
    local backup_file

    if [[ -z "${target_file}" ]]; then
        fail "Usage: backup_file_if_present <file>"
        return 2
    fi

    if [[ ! -f "${target_file}" ]]; then
        info "No existing file to back up: ${target_file}"
        return 0
    fi

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_file="${target_file}.bak.${timestamp}"

    cp -a "${target_file}" "${backup_file}" || {
        fail "Failed to back up ${target_file} to ${backup_file}"
        return 2
    }

    pass "Backed up ${target_file} to ${backup_file}"
    return 0
}

#
# write_promtail_config
# Description:
#  - Writes Promtail configuration for scraping rsyslog remote log files.
#  - Configures Promtail to push logs into Loki.
#  - Uses job="rsyslog" to stay aligned with validate-pipeline.sh.
#
# Preconditions:
#  - Promtail config directory exists
#  - Promtail positions directory exists
#  - Loki base URL constants are initialized
#  - REMOTE_LOG_DIR points to rsyslog's remote log directory
#
# Postconditions:
#  - Promtail config file exists at PROMTAIL_CONFIG
#  - Config contains the expected Loki push URL
#  - Config scrapes ${REMOTE_LOG_DIR}/**/*.log
#  - Config labels logs with job="rsyslog"
#
# Returns:
#  - 0 if Promtail configuration is written successfully
#  - 2 if writing or permission updates fail
#
write_promtail_config() {
    step "Phase 4 — Write Promtail pipeline configuration"

    backup_file_if_present "${PROMTAIL_CONFIG}" || return 2

    cat > "${PROMTAIL_CONFIG}" <<EOF
server:
  http_listen_port: ${PROMTAIL_HTTP_PORT}
  grpc_listen_port: 0

positions:
  filename: ${PROMTAIL_POSITIONS_FILE}

clients:
  - url: ${LOKI_PUSH_URL}

scrape_configs:
  - job_name: ${PROMTAIL_JOB_NAME}
    static_configs:
      - targets:
          - localhost
        labels:
          job: ${PROMTAIL_LOKI_LABEL_JOB}
          source: rsyslog_remote
          __path__: ${REMOTE_LOG_DIR}/**/*.log
EOF

    chmod 0644 "${PROMTAIL_CONFIG}" || {
        fail "Failed to set permissions on Promtail config: ${PROMTAIL_CONFIG}"
        return 2
    }

    pass "Promtail config written: ${PROMTAIL_CONFIG}"
    info "Promtail will scrape: ${REMOTE_LOG_DIR}/**/*.log"
    info "Promtail will push to Loki: ${LOKI_PUSH_URL}"
    info "Promtail Loki label contract: job=\"${PROMTAIL_LOKI_LABEL_JOB}\""

    return 0
}

#
# write_grafana_loki_datasource
# Description:
#  - Writes Grafana provisioning config for a Loki data source.
#  - Sets Loki as the default Grafana data source.
#
# Preconditions:
#  - Grafana data source provisioning directory exists
#  - Loki base URL constants are initialized
#
# Postconditions:
#  - Grafana Loki data source file exists
#  - Grafana is configured to use Loki through proxy access
#  - Loki is marked as the default data source
#
# Returns:
#  - 0 if Grafana data source configuration is written successfully
#  - 2 if writing or permission updates fail
#
write_grafana_loki_datasource() {
    step "Phase 5 — Write Grafana Loki data source provisioning"

    backup_file_if_present "${GRAFANA_LOKI_DATASOURCE_FILE}" || return 2

    cat > "${GRAFANA_LOKI_DATASOURCE_FILE}" <<EOF
apiVersion: 1

datasources:
  - name: loki
    type: loki
    access: proxy
    url: ${LOKI_BASE_URL}
    isDefault: true
    editable: true
EOF

    chmod 0644 "${GRAFANA_LOKI_DATASOURCE_FILE}" || {
        fail "Failed to set permissions on Grafana Loki data source file: ${GRAFANA_LOKI_DATASOURCE_FILE}"
        return 2
    }

    pass "Grafana Loki data source provisioning written: ${GRAFANA_LOKI_DATASOURCE_FILE}"
    info "Grafana Loki data source URL: ${LOKI_BASE_URL}"

    return 0
}

#
# validate_generated_files
# Description:
#  - Performs basic validation that generated configuration files exist and are non-empty.
#  - Runs promtail config validation when supported by the installed Promtail binary.
#
# Preconditions:
#  - Promtail and Grafana provisioning files have been written
#  - Shared system helper library is sourced
#
# Postconditions:
#  - Generated files are confirmed present
#  - Promtail configuration syntax is checked when possible
#
# Returns:
#  - 0 if generated files pass validation
#  - 2 if generated files are missing, empty, or invalid
#
validate_generated_files() {
    step "Phase 6 — Generated file validation"

    [[ -s "${PROMTAIL_CONFIG}" ]] || {
        fail "Promtail config is missing or empty: ${PROMTAIL_CONFIG}"
        return 2
    }
    pass "Promtail config exists and is non-empty: ${PROMTAIL_CONFIG}"

    [[ -s "${GRAFANA_LOKI_DATASOURCE_FILE}" ]] || {
        fail "Grafana Loki data source file is missing or empty: ${GRAFANA_LOKI_DATASOURCE_FILE}"
        return 2
    }
    pass "Grafana Loki data source file exists and is non-empty: ${GRAFANA_LOKI_DATASOURCE_FILE}"

    if command -v promtail >/dev/null 2>&1; then
        if promtail -config.file="${PROMTAIL_CONFIG}" -check-syntax >/dev/null 2>&1; then
            pass "Promtail configuration syntax check passed"
        else
            fail "Promtail configuration syntax check failed: ${PROMTAIL_CONFIG}"
            return 2
        fi
    else
        info "Promtail binary not found in PATH; skipping Promtail syntax check"
    fi

    pass "Generated file validation completed"
    return 0
}

#
# restart_pipeline_services
# Description:
#  - Restarts services affected by pipeline configuration changes.
#  - Promtail is restarted to load file scraping configuration.
#  - Grafana is restarted to load provisioned Loki data source.
#
# Preconditions:
#  - Promtail service exists
#  - Grafana service exists
#  - Generated configuration files have passed validation
#
# Postconditions:
#  - Promtail has been restarted
#  - Grafana has been restarted
#
# Returns:
#  - 0 if service restarts succeed
#  - 2 if a critical restart fails
#
restart_pipeline_services() {
    step "Phase 7 — Restart pipeline services"

    systemctl restart "${PROMTAIL_SERVICE}" || {
        fail "Failed to restart service: ${PROMTAIL_SERVICE}"
        return 2
    }
    pass "Restarted service: ${PROMTAIL_SERVICE}"

    systemctl restart "${GRAFANA_SERVICE}" || {
        fail "Failed to restart service: ${GRAFANA_SERVICE}"
        return 2
    }
    pass "Restarted service: ${GRAFANA_SERVICE}"

    pass "Pipeline service restart completed"
    return 0
}

#
# validate_local_services_running
# Description:
#  - Verifies all required pipeline services are running after setup.
#
# Preconditions:
#  - Shared service helper library is sourced
#  - Services have been installed
#  - Promtail and Grafana have been restarted
#
# Postconditions:
#  - rsyslog, loki, promtail, and grafana-server are verified as running
#
# Returns:
#  - 0 if all required services are running
#  - 2 if a critical service is not running
#
validate_local_services_running() {
    step "Phase 8 — Post-setup service health checks"

    service_running "${RSYSLOG_SERVICE}" || return 2
    service_running "${LOKI_SERVICE}" || return 2
    service_running "${PROMTAIL_SERVICE}" || return 2
    service_running "${GRAFANA_SERVICE}" || return 2

    pass "Post-setup service health checks completed"
    return 0
}

#
# wait_for_http_endpoint
# Description:
#  - Waits for an HTTP endpoint to respond successfully.
#  - Retries because services can be marked running by systemd before their HTTP
#    readiness endpoint is available.
#
# Preconditions:
#  - curl is available
#  - Accepts two arguments:
#    1. Human-readable endpoint name
#    2. Endpoint URL
#
# Postconditions:
#  - Endpoint has responded successfully, or retries have been exhausted
#
# Returns:
#  - 0 if endpoint responds successfully
#  - 2 if endpoint does not respond successfully after all attempts
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
#  - Verifies Loki and Grafana HTTP endpoints respond successfully after setup.
#  - Uses retries because service restart completion does not guarantee HTTP
#    readiness has completed.
#
# Preconditions:
#  - curl is available
#  - Loki and Grafana services are running
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
    step "Phase 9 — Post-setup HTTP endpoint checks"

    wait_for_http_endpoint "Loki readiness endpoint" "${LOKI_BASE_URL}/ready" || return 2
    wait_for_http_endpoint "Grafana HTTP endpoint" "${GRAFANA_BASE_URL}/login" || return 2

    pass "Post-setup HTTP endpoint checks completed"
    return 0
}

#
# print_setup_summary
# Description:
#  - Prints the final setup summary and next validation command.
#
# Preconditions:
#  - Setup and health checks have completed successfully
#
# Postconditions:
#  - Operator receives a concise explanation of what was configured
#  - Operator receives the next command for validation
#
# Returns:
#  - 0
#
print_setup_summary() {
    step "Setup Summary"

    info "Promtail config: ${PROMTAIL_CONFIG}"
    info "Promtail positions file: ${PROMTAIL_POSITIONS_FILE}"
    info "Promtail scrape path: ${REMOTE_LOG_DIR}/**/*.log"
    info "Promtail Loki push URL: ${LOKI_PUSH_URL}"
    info "Promtail Loki labels include: job=\"${PROMTAIL_LOKI_LABEL_JOB}\""
    info "Grafana Loki data source file: ${GRAFANA_LOKI_DATASOURCE_FILE}"
    info "Grafana Loki data source URL: ${LOKI_BASE_URL}"
    info "Next readiness validation command: sudo ./scripts/validate-pipeline.sh"
    info "Next true end-to-end validation command: sudo EXPECT_REMOTE_SENDER=1 ./scripts/validate-pipeline.sh"

    pass "Pipeline setup completed successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    step "Set up centralized logging pipeline"

    require_root || die "Root privilege check failed"
    require_runtime_commands || die "Setup command checks failed"
    validate_required_services_exist || die "Required service existence checks failed"
    validate_required_paths || die "Required path checks failed"
    write_promtail_config || die "Promtail configuration failed"
    write_grafana_loki_datasource || die "Grafana Loki data source provisioning failed"
    validate_generated_files || die "Generated file validation failed"
    restart_pipeline_services || die "Pipeline service restart failed"
    validate_local_services_running || die "Post-setup service health checks failed"
    validate_http_endpoints || die "Post-setup HTTP endpoint checks failed"
    print_setup_summary

    pass "setup-pipeline.sh completed successfully"
    return 0
}

main "$@"
