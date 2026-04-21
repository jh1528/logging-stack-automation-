#!/usr/bin/env bash
#
# install-grafana.sh
#
# Installs and configures Grafana for the logging stack project.
#
# Purpose:
#  - Install Grafana from the official package repository
#  - Register and trust the Grafana APT repository
#  - Install grafana package
#  - Enable and start grafana-server.service
#
# Design:
#  - Keep installation responsibilities separate from validation
#  - Use infra-bash-lib helpers where appropriate
#  - Fail fast on critical setup errors
#  - Keep functions small and focused
#
# Dependencies:
#  - Debian/Ubuntu-based system
#  - sudo/root privileges
#  - curl
#  - gpg
#  - systemd
#
# Notes:
#  - Validation belongs in scripts/validate-grafana.sh
#  - This script installs Grafana only
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

GRAFANA_APT_KEYRING="/etc/apt/keyrings/grafana.gpg"
GRAFANA_APT_SOURCE="/etc/apt/sources.list.d/grafana.list"
GRAFANA_APT_REPO="deb [signed-by=${GRAFANA_APT_KEYRING}] https://apt.grafana.com stable main"

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
	step "Checking installation command dependencies"

	command_exists curl >/dev/null || die "curl is required for Grafana installation"
	command_exists gpg >/dev/null || die "gpg is required for Grafana installation"
	command_exists systemctl >/dev/null || die "systemctl is required for Grafana installation"

	pass "Required installation commands are available"
	return 0
}

install_prerequisite_packages() {
	step "Installing prerequisite packages"

	export DEBIAN_FRONTEND=noninteractive

	apt-get update -y >/dev/null 2>&1 || die "Failed to update apt package index"
	apt-get install -y apt-transport-https software-properties-common wget >/dev/null 2>&1 || die "Failed to install prerequisite packages"

	pass "Prerequisite packages installed"
	return 0
}

ensure_apt_keyrings_directory() {
	step "Ensuring APT keyrings directory exists"

	mkdir -p /etc/apt/keyrings || die "Failed to create /etc/apt/keyrings"

	pass "APT keyrings directory is ready"
	return 0
}

install_grafana_repository_key() {
	step "Installing Grafana repository signing key"

	curl -fsSL https://apt.grafana.com/gpg.key \
		| gpg --dearmor -o "${GRAFANA_APT_KEYRING}" \
		|| die "Failed to install Grafana repository signing key"

	chmod 0644 "${GRAFANA_APT_KEYRING}" || die "Failed to set permissions on ${GRAFANA_APT_KEYRING}"

	pass "Grafana repository signing key installed"
	return 0
}

install_grafana_repository() {
	step "Configuring Grafana APT repository"

	cat > "${GRAFANA_APT_SOURCE}" <<EOF
${GRAFANA_APT_REPO}
EOF

	pass "Grafana APT repository configured"
	return 0
}

install_grafana_package() {
	step "Installing Grafana package"

	export DEBIAN_FRONTEND=noninteractive

	apt-get update -y >/dev/null 2>&1 || die "Failed to refresh apt package index"
	apt-get install -y grafana >/dev/null 2>&1 || die "Failed to install Grafana"

	pass "Grafana package installed"
	return 0
}

enable_and_start_grafana_service() {
	step "Enabling and starting Grafana service"

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable --now grafana-server >/dev/null 2>&1 || die "Failed to enable/start grafana-server.service"

	pass "Grafana service enabled and started"
	return 0
}

verify_grafana_service_registration() {
	step "Verifying Grafana service registration"

	service_exists grafana-server || die "grafana-server.service is not installed"

	pass "Grafana service is registered"
	return 0
}

print_install_summary() {
	step "Grafana installation summary"

	info "Package: grafana"
	info "Service: grafana-server.service"
	info "Web UI: http://127.0.0.1:3000"

	pass "Grafana installation completed successfully"
	return 0
}

# ==============================================================================
# Main workflow
# ==============================================================================

main() {
	step "Starting Grafana installation"

	require_root
	require_runtime_commands
	install_prerequisite_packages
	ensure_apt_keyrings_directory
	install_grafana_repository_key
	install_grafana_repository
	install_grafana_package
	enable_and_start_grafana_service
	verify_grafana_service_registration
	print_install_summary
}

main "$@"
