#!/usr/bin/env bash
#
# install-loki.sh
#
# Installs Grafana Loki as a single-binary local service.
#
# Purpose:
#  - Install Loki using the official release archive
#  - Create a minimal single-node filesystem-backed configuration
#  - Register Loki as a systemd service
#  - Start and enable the service for later validation
#
# Design:
#  - Follow the staged-model used by the logging stack project
#  - Keep install responsibilities separate from validation responsibilities
#  - Use infra-bash-lib helpers for output, health checks, filesystem, and service control
#  - Fail fast on critical installation steps
#
# Notes:
#  - This script installs Loki only
#  - It does not install Grafana or Promtail
#  - It does not validate end-to-end ingestion
#  - Validation should be handled by validate-loki.sh
#
# Environment Variables:
#  - LOKI_VERSION
#      Loki release version to install
#      Default: 3.7.1
#
#  - LOKI_ARCH
#      Loki architecture suffix used in release artifacts
#      Default: amd64
#
#  - LOKI_USER
#      Service account used to run Loki
#      Default: loki
#
#  - LOKI_GROUP
#      Service group used to run Loki
#      Default: loki
#
#  - LOKI_INSTALL_DIR
#      Directory used for the Loki binary
#      Default: /usr/local/bin
#
#  - LOKI_CONFIG_DIR
#      Directory used for Loki configuration
#      Default: /etc/loki
#
#  - LOKI_DATA_DIR
#      Directory used for Loki local storage
#      Default: /var/lib/loki
#
#  - LOKI_HTTP_PORT
#      HTTP listen port for Loki
#      Default: 3100
#
# Usage:
#  sudo ./scripts/install-loki.sh
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
# shellcheck source=../../infra-bash-lib/health.sh
source "${LIB_DIR}/health.sh"
# shellcheck source=../../infra-bash-lib/system.sh
source "${LIB_DIR}/system.sh"

# ==============================================================================
# Configuration
# ==============================================================================

LOKI_VERSION="${LOKI_VERSION:-3.7.1}"
LOKI_ARCH="${LOKI_ARCH:-amd64}"

LOKI_USER="${LOKI_USER:-loki}"
LOKI_GROUP="${LOKI_GROUP:-loki}"

LOKI_INSTALL_DIR="${LOKI_INSTALL_DIR:-/usr/local/bin}"
LOKI_CONFIG_DIR="${LOKI_CONFIG_DIR:-/etc/loki}"
LOKI_DATA_DIR="${LOKI_DATA_DIR:-/var/lib/loki}"

LOKI_BINARY_NAME="loki"
LOKI_BINARY_PATH="${LOKI_INSTALL_DIR}/${LOKI_BINARY_NAME}"
LOKI_CONFIG_PATH="${LOKI_CONFIG_DIR}/config.yml"

LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"

LOKI_RELEASE_FILE="loki-linux-${LOKI_ARCH}.zip"
LOKI_DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/${LOKI_RELEASE_FILE}"

TMP_DIR="/tmp/loki-install"
TMP_ARCHIVE_PATH="${TMP_DIR}/${LOKI_RELEASE_FILE}"
TMP_EXTRACT_DIR="${TMP_DIR}/extract"

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

ensure_group_exists() {
	local group_name="$1"

	if [[ -z "$group_name" ]]; then
		fail "Usage: ensure_group_exists <group_name>"
		return 2
	fi

	if getent group "$group_name" >/dev/null 2>&1; then
		pass "Group already exists: ${group_name}"
		return 0
	fi

	if groupadd --system "$group_name" >/dev/null 2>&1; then
		pass "Group created: ${group_name}"
		return 0
	fi

	fail "Failed to create group: ${group_name}"
	return 2
}

ensure_user_exists() {
	local user_name="$1"
	local group_name="$2"

	if [[ -z "$user_name" || -z "$group_name" ]]; then
		fail "Usage: ensure_user_exists <user_name> <group_name>"
		return 2
	fi

	if id "$user_name" >/dev/null 2>&1; then
		pass "User already exists: ${user_name}"
		return 0
	fi

	if useradd \
		--system \
		--gid "$group_name" \
		--home-dir "$LOKI_DATA_DIR" \
		--no-create-home \
		--shell /usr/sbin/nologin \
		"$user_name" >/dev/null 2>&1; then
		pass "User created: ${user_name}"
		return 0
	fi

	fail "Failed to create user: ${user_name}"
	return 2
}

prepare_temp_workspace() {
	ensure_directory "$TMP_DIR" || return 2
	ensure_directory "$TMP_EXTRACT_DIR" || return 2
	return 0
}

install_runtime_dependencies() {
	step "Installing runtime dependencies"

	apt_update || return 2
	apt_install curl unzip || return 2

	return 0
}

run_preflight_checks() {
	step "Running install preflight checks"

	info "Checking free disk space on /"
	check_disk_free_gb / 5 2
	case $? in
	0) ;;
	1) warn "Disk space is below the recommended level, but installation may continue" ;;
	2) die "Disk free-space check failed or minimum capacity is not met" ;;
	esac

	info "Checking total system memory"
	check_memory_total_gb 2 1
	case $? in
	0) ;;
	1) warn "System memory is below the recommended level, but installation may continue" ;;
	2) die "System memory is below the minimum required level or could not be checked" ;;
	esac

	info "Checking current CPU load"
	check_cpu_load 4.00 8.00
	case $? in
	0) ;;
	1) warn "CPU load is elevated; installation may continue" ;;
	2) die "CPU load is too high or could not be checked" ;;
	esac

	pass "Preflight checks completed"
	return 0
}

prepare_directories() {
	step "Preparing Loki directories"

	ensure_directory "$LOKI_INSTALL_DIR" || return 2
	ensure_directory "$LOKI_CONFIG_DIR" || return 2
	ensure_directory "$LOKI_DATA_DIR" || return 2
	ensure_directory "${LOKI_DATA_DIR}/chunks" || return 2
	ensure_directory "${LOKI_DATA_DIR}/rules" || return 2
	ensure_directory "${LOKI_DATA_DIR}/index" || return 2
	ensure_directory "${LOKI_DATA_DIR}/index_cache" || return 2
	ensure_directory "${LOKI_DATA_DIR}/compactor" || return 2

	if chown -R "${LOKI_USER}:${LOKI_GROUP}" "$LOKI_CONFIG_DIR" "$LOKI_DATA_DIR" >/dev/null 2>&1; then
		pass "Ownership applied to Loki directories"
		return 0
	fi

	fail "Failed to apply ownership to Loki directories"
	return 2
}

download_loki_archive() {
	step "Downloading Loki release archive"

	prepare_temp_workspace || return 2

	if [[ -f "$TMP_ARCHIVE_PATH" ]]; then
		info "Removing existing temporary archive"
		rm -f "$TMP_ARCHIVE_PATH" || return 2
	fi

	if download_file "$LOKI_DOWNLOAD_URL" "$TMP_ARCHIVE_PATH"; then
		return 0
	fi

	fail "Failed to download Loki archive from: ${LOKI_DOWNLOAD_URL}"
	return 2
}

extract_loki_archive() {
	step "Extracting Loki release archive"

	if [[ ! -f "$TMP_ARCHIVE_PATH" ]]; then
		fail "Cannot extract missing archive: ${TMP_ARCHIVE_PATH}"
		return 2
	fi

	rm -rf "$TMP_EXTRACT_DIR" || return 2
	ensure_directory "$TMP_EXTRACT_DIR" || return 2

	if unzip -o "$TMP_ARCHIVE_PATH" -d "$TMP_EXTRACT_DIR" >/dev/null 2>&1; then
		pass "Archive extracted: ${TMP_ARCHIVE_PATH}"
		return 0
	fi

	fail "Failed to extract archive: ${TMP_ARCHIVE_PATH}"
	return 2
}

install_loki_binary() {
	step "Installing Loki binary"

	local extracted_binary_path="${TMP_EXTRACT_DIR}/loki-linux-${LOKI_ARCH}"

	if [[ ! -f "$extracted_binary_path" ]]; then
		fail "Expected binary not found after extraction: ${extracted_binary_path}"
		return 2
	fi

	if install -m 0755 "$extracted_binary_path" "$LOKI_BINARY_PATH" >/dev/null 2>&1; then
		pass "Loki binary installed: ${LOKI_BINARY_PATH}"
		return 0
	fi

	fail "Failed to install Loki binary: ${LOKI_BINARY_PATH}"
	return 2
}

write_loki_config() {
	step "Writing Loki configuration"

	write_file "$LOKI_CONFIG_PATH" <<EOF
# config.yml
#
# Minimal local Loki configuration for single-binary deployment.
#
# Purpose:
#  - Run Loki locally for the logging stack project
#  - Store data on the local filesystem
#  - Keep configuration simple and suitable for staged validation
#
# Notes:
#  - Authentication is disabled for lab simplicity
#  - Local filesystem storage is used
#  - Replication factor is set to 1 because this is a single-node deployment

auth_enabled: false

server:
  http_listen_address: 0.0.0.0
  http_listen_port: ${LOKI_HTTP_PORT}
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: ${LOKI_DATA_DIR}
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
  storage:
    filesystem:
      chunks_directory: ${LOKI_DATA_DIR}/chunks
      rules_directory: ${LOKI_DATA_DIR}/rules

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: ${LOKI_DATA_DIR}/index
    cache_location: ${LOKI_DATA_DIR}/index_cache

limits_config:
  allow_structured_metadata: false
  volume_enabled: true

compactor:
  working_directory: ${LOKI_DATA_DIR}/compactor

analytics:
  reporting_enabled: false
EOF
	if [[ $? -ne 0 ]]; then
		fail "Failed to write Loki configuration"
		return 2
	fi

	if chown "${LOKI_USER}:${LOKI_GROUP}" "$LOKI_CONFIG_PATH" >/dev/null 2>&1; then
		pass "Ownership applied to Loki configuration"
		return 0
	fi

	fail "Failed to apply ownership to Loki configuration"
	return 2
}

write_loki_service() {
	step "Writing Loki systemd service"

	write_systemd_unit "loki" <<EOF
[Unit]
Description=Grafana Loki
Documentation=https://grafana.com/oss/loki/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LOKI_USER}
Group=${LOKI_GROUP}
WorkingDirectory=${LOKI_DATA_DIR}
ExecStart=${LOKI_BINARY_PATH} -config.file=${LOKI_CONFIG_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
	if [[ $? -ne 0 ]]; then
		fail "Failed to write Loki systemd unit"
		return 2
	fi

	reload_systemd || return 2
	return 0
}

start_and_enable_loki() {
	step "Starting and enabling Loki service"

	enable_service loki || return 2
	start_service loki || return 2

	if service_running loki; then
		return 0
	fi

	fail "Loki service did not reach running state"
	return 2
}

cleanup_temp_workspace() {
	step "Cleaning temporary installation files"

	if [[ -d "$TMP_DIR" ]]; then
		if rm -rf "$TMP_DIR" >/dev/null 2>&1; then
			pass "Temporary files removed: ${TMP_DIR}"
			return 0
		fi

		warn "Failed to remove temporary files: ${TMP_DIR}"
		return 1
	fi

	pass "No temporary files needed cleanup"
	return 0
}

print_install_summary() {
	step "Loki installation summary"

	info "Version: ${LOKI_VERSION}"
	info "Binary: ${LOKI_BINARY_PATH}"
	info "Config: ${LOKI_CONFIG_PATH}"
	info "Data directory: ${LOKI_DATA_DIR}"
	info "Service: loki.service"
	info "HTTP endpoint: http://localhost:${LOKI_HTTP_PORT}"

	pass "Loki installation completed"
	return 0
}

# ==============================================================================
# Main workflow
# ==============================================================================

main() {
	step "Starting Loki installation"

	require_root
	run_preflight_checks
	install_runtime_dependencies || die "Failed to install required runtime dependencies"

	step "Creating Loki service account"
	ensure_group_exists "$LOKI_GROUP" || die "Failed to prepare Loki group"
	ensure_user_exists "$LOKI_USER" "$LOKI_GROUP" || die "Failed to prepare Loki user"

	prepare_directories || die "Failed to prepare Loki directories"
	download_loki_archive || die "Failed to download Loki release archive"
	extract_loki_archive || die "Failed to extract Loki release archive"
	install_loki_binary || die "Failed to install Loki binary"
	write_loki_config || die "Failed to write Loki configuration"
	write_loki_service || die "Failed to write Loki systemd service"
	start_and_enable_loki || die "Failed to start or enable Loki service"

	cleanup_temp_workspace
	print_install_summary
}

main "$@"
