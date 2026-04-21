#!/usr/bin/env bash
#
# install-promtail.sh
#
# Installs and configures Promtail for the logging stack.
#

set -u

# ==============================================================================
# Path discovery and shared library loading
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/../infra-bash-lib"

source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/apt.sh"
source "${LIB_DIR}/service.sh"
source "${LIB_DIR}/system.sh"

# ==============================================================================
# Configuration
# ==============================================================================

PROMTAIL_VERSION="2.9.3"
PROMTAIL_BIN="/usr/local/bin/promtail"
PROMTAIL_CONFIG="/etc/promtail/config.yml"
PROMTAIL_DATA_DIR="/var/lib/promtail"

# ==============================================================================
# Helpers
# ==============================================================================

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root"
    fi
    pass "Running as root"
}

install_dependencies() {
    step "Installing dependencies"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl >/dev/null 2>&1 || die "Failed to install curl"
    pass "Dependencies installed"
}

download_promtail() {
    step "Downloading Promtail"

    curl -L -o /tmp/promtail.zip \
        "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip" \
        || die "Failed to download Promtail"

    unzip -o /tmp/promtail.zip -d /tmp >/dev/null 2>&1 || die "Failed to unzip Promtail"
    mv /tmp/promtail-linux-amd64 "${PROMTAIL_BIN}" || die "Failed to move Promtail binary"
    chmod +x "${PROMTAIL_BIN}"

    pass "Promtail installed to ${PROMTAIL_BIN}"
}

create_directories() {
    step "Creating Promtail directories"

    mkdir -p /etc/promtail || die "Failed to create config dir"
    mkdir -p "${PROMTAIL_DATA_DIR}" || die "Failed to create data dir"

    pass "Directories created"
}

write_config() {
    step "Writing Promtail config"

    cat > "${PROMTAIL_CONFIG}" <<EOF
server:
  http_listen_port: 9080

positions:
  filename: ${PROMTAIL_DATA_DIR}/positions.yaml

clients:
  - url: http://127.0.0.1:3100/loki/api/v1/push

scrape_configs:
  - job_name: rsyslog
    static_configs:
      - targets:
          - localhost
        labels:
          job: rsyslog
          __path__: /var/log/remote/*.log
EOF

    pass "Promtail config written"
}

create_service() {
    step "Creating Promtail systemd service"

    cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail
After=network.target

[Service]
ExecStart=${PROMTAIL_BIN} -config.file=${PROMTAIL_CONFIG}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || die "Failed to reload systemd"
    systemctl enable --now promtail || die "Failed to enable/start Promtail"

    pass "Promtail service started"
}

verify_install() {
    step "Verifying Promtail service"

    service_exists promtail || die "Promtail service not found"
    service_running promtail || die "Promtail not running"

    pass "Promtail is running"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    step "Starting Promtail installation"

    require_root
    install_dependencies
    download_promtail
    create_directories
    write_config
    create_service
    verify_install

    pass "Promtail installation completed successfully"
}

main "$@"
