#!/usr/bin/env bash

#

# validate-loki.sh

#

# Validates a Grafana Loki installation in staged modes.

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

LOKI_HTTP_HOST="${LOKI_HTTP_HOST:-127.0.0.1}"
LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
LOKI_BASE_URL="http://${LOKI_HTTP_HOST}:${LOKI_HTTP_PORT}"

EXPECT_INGESTION="${EXPECT_INGESTION:-0}"

LOKI_QUERY_RETRIES="${LOKI_QUERY_RETRIES:-10}"
LOKI_QUERY_SLEEP_SECONDS="${LOKI_QUERY_SLEEP_SECONDS:-2}"

VALIDATION_STREAM_JOB="loki-validation"
VALIDATION_STREAM_SOURCE="validate-loki.sh"

# ==============================================================================

# Internal helpers

# ==============================================================================

require_root() {
if [[ "${EUID}" -ne 0 ]]; then
die "This script must be run as root"
fi

```
pass "Running as root"
return 0
```

}

require_runtime_commands() {
step "Checking validation command dependencies"

```
command_exists curl >/dev/null || die "curl is required for Loki validation"
command_exists ss >/dev/null || die "ss is required for listener validation"
command_exists python3 >/dev/null || die "python3 is required for JSON-safe payload generation"

pass "Required validation commands are available"
return 0
```

}

validate_service_exists() {
step "Checking Loki service registration"

```
service_exists loki || die "Loki service is not installed"
return 0
```

}

validate_service_running() {
step "Checking Loki service status"

```
service_running loki || die "Loki service is not running"
return 0
```

}

validate_listener() {
step "Checking Loki listener"

```
local listener_output

listener_output="$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E "(^|:)${LOKI_HTTP_PORT}$" || true)"

if [[ -n "$listener_output" ]]; then
	pass "Port ${LOKI_HTTP_PORT} is listening"
	return 0
fi

fail "Port ${LOKI_HTTP_PORT} is not listening"
return 2
```

}

validate_ready_endpoint() {
step "Checking Loki readiness endpoint"

```
if curl -fsS "${LOKI_BASE_URL}/ready" >/dev/null 2>&1; then
	pass "Loki readiness endpoint responded successfully: ${LOKI_BASE_URL}/ready"
	return 0
fi

fail "Loki readiness endpoint did not respond successfully: ${LOKI_BASE_URL}/ready"
return 2
```

}

build_validation_payload() {
local timestamp_ns="$1"
local test_message="$2"

```
if [[ -z "$timestamp_ns" || -z "$test_message" ]]; then
	fail "Usage: build_validation_payload <timestamp_ns> <test_message>"
	return 2
fi

python3 - "$timestamp_ns" "$test_message" <<EOF
```

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
EOF
}

push_validation_log() {
step "Pushing Loki validation log entry"

```
local timestamp_ns="$1"
local test_message="$2"
local payload

if [[ -z "$timestamp_ns" || -z "$test_message" ]]; then
	fail "Usage: push_validation_log <timestamp_ns> <test_message>"
	return 2
fi

payload="$(build_validation_payload "$timestamp_ns" "$test_message")" || return 2

if curl -fsS \
	-X POST \
	-H "Content-Type: application/json" \
	--data-raw "$payload" \
	"${LOKI_BASE_URL}/loki/api/v1/push" >/dev/null 2>&1; then
	pass "Validation log entry pushed to Loki"
	return 0
fi

fail "Failed to push validation log entry to Loki"
return 2
```

}

query_for_validation_log() {
local test_message="$1"
local attempt
local response_body

```
if [[ -z "$test_message" ]]; then
	fail "Usage: query_for_validation_log <test_message>"
	return 2
fi

for (( attempt = 1; attempt <= LOKI_QUERY_RETRIES; attempt++ )); do
	info "Query attempt ${attempt}/${LOKI_QUERY_RETRIES}"

	response_body="$(curl -fsS \
		-G \
		--data-urlencode "query={job=\"${VALIDATION_STREAM_JOB}\",source=\"${VALIDATION_STREAM_SOURCE}\"}" \
		--data-urlencode "start=$(($(date +%s%N) - 60000000000))" \
		--data-urlencode "end=$(date +%s%N)" \
		--data-urlencode "limit=10" \
		"${LOKI_BASE_URL}/loki/api/v1/query_range" 2>/dev/null || true)"

	if [[ -n "$response_body" ]] && grep -Fq "$test_message" <<<"$response_body"; then
		pass "Validation log entry was returned by Loki query"
		return 0
	fi

	if (( attempt < LOKI_QUERY_RETRIES )); then
		info "Validation log entry not returned yet; waiting ${LOKI_QUERY_SLEEP_SECONDS}s"
		sleep "$LOKI_QUERY_SLEEP_SECONDS"
	fi
done

fail "Validation log entry was not returned by Loki after ${LOKI_QUERY_RETRIES} attempts"
return 2
```

}

run_functional_validation() {
step "Running Loki functional validation"

```
local timestamp_ns
local test_id
local test_message

timestamp_ns="$(date +%s%N)"
test_id="$(date +%s)"
test_message="loki validation test message id=${test_id}"

info "Validation message: ${test_message}"

push_validation_log "$timestamp_ns" "$test_message" || die "Loki push API validation failed"
query_for_validation_log "$test_message" || die "Loki query API validation failed"

pass "Functional Loki ingestion/query validation succeeded"
return 0
```

}

print_validation_summary() {
step "Loki validation summary"

```
info "Service: loki.service"
info "Endpoint: ${LOKI_BASE_URL}"
info "Readiness mode: enabled"

if [[ "$EXPECT_INGESTION" == "1" ]]; then
	info "Functional ingestion/query validation: enabled"
else
	info "Functional ingestion/query validation: skipped"
fi

pass "Loki validation completed successfully"
return 0
```

}

# ==============================================================================

# Main workflow

# ==============================================================================

main() {
step "Starting Loki validation"

```
require_root
require_runtime_commands

validate_service_exists
validate_service_running
validate_listener || die "Loki is not listening on the expected port"
validate_ready_endpoint || die "Loki readiness endpoint validation failed"

if [[ "$EXPECT_INGESTION" == "1" ]]; then
	run_functional_validation
else
	info "EXPECT_INGESTION is not enabled; functional push/query validation skipped"
fi

print_validation_summary
```

}

main "$@"
