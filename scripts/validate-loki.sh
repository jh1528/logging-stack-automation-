#!/usr/bin/env bash

#

# validate-loki.sh

#

# Validates a Grafana Loki installation using staged validation.

#

# Modes:

# - Readiness (default)

# - Functional ingestion/query (EXPECT_INGESTION=1)

#

set -u

# ==============================================================================

# Path + library loading

# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/../infra-bash-lib"

source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/service.sh"

# ==============================================================================

# Config

# ==============================================================================

LOKI_HTTP_HOST="${LOKI_HTTP_HOST:-127.0.0.1}"
LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
LOKI_BASE_URL="http://${LOKI_HTTP_HOST}:${LOKI_HTTP_PORT}"

EXPECT_INGESTION="${EXPECT_INGESTION:-0}"

LOKI_QUERY_RETRIES="${LOKI_QUERY_RETRIES:-12}"
LOKI_QUERY_SLEEP_SECONDS="${LOKI_QUERY_SLEEP_SECONDS:-2}"

STREAM_JOB="loki-validation"
STREAM_SOURCE="validate-loki.sh"

# ==============================================================================

# Helpers

# ==============================================================================

require_root() {
[[ "$EUID" -eq 0 ]] || die "Must run as root"
pass "Running as root"
}

require_commands() {
step "Checking dependencies"
command -v curl >/dev/null || die "curl required"
command -v ss >/dev/null || die "ss required"
command -v python3 >/dev/null || die "python3 required"
pass "Required commands available"
}

check_service() {
step "Checking Loki service"
service_exists loki || die "loki.service missing"
service_running loki || die "loki.service not running"
pass "Service is running: loki.service"
}

check_listener() {
step "Checking Loki listener"

```
if ss -lnt | awk '{print $4}' | grep -q ":${LOKI_HTTP_PORT}$"; then
    pass "Port ${LOKI_HTTP_PORT} is listening"
    return 0
fi

die "Port ${LOKI_HTTP_PORT} is not listening"
```

}

check_ready() {
step "Checking readiness endpoint"

```
if curl -fsS "${LOKI_BASE_URL}/ready" >/dev/null; then
    pass "Readiness endpoint OK: ${LOKI_BASE_URL}/ready"
    return 0
fi

die "Readiness endpoint failed"
```

}

build_payload() {
python3 - <<EOF
import json, time
ts = str(int(time.time()*1e9))
msg = "loki validation test message id=" + str(int(time.time()))
print(json.dumps({
"streams": [{
"stream": {"job": "${STREAM_JOB}", "source": "${STREAM_SOURCE}"},
"values": [[ts, msg]]
}]
}))
EOF
}

push_log() {
step "Pushing validation log"

```
PAYLOAD="$(build_payload)"

echo "$PAYLOAD" > /tmp/loki_payload.json

curl -fsS -X POST \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/loki_payload.json \
    "${LOKI_BASE_URL}/loki/api/v1/push" >/dev/null \
    || die "Push failed"

TEST_MESSAGE="$(python3 -c "import json; print(json.load(open('/tmp/loki_payload.json'))['streams'][0]['values'][0][1])")"

pass "Log pushed"
```

}

query_log() {
step "Querying for validation log"

```
START_NS=$(($(date +%s%N) - 60000000000))
END_NS=$(date +%s%N)

for ((i=1;i<=LOKI_QUERY_RETRIES;i++)); do
    info "Query attempt $i/${LOKI_QUERY_RETRIES}"

    RESPONSE="$(curl -fsS -G \
        --data-urlencode "query={job=\"${STREAM_JOB}\",source=\"${STREAM_SOURCE}\"}" \
        --data-urlencode "start=${START_NS}" \
        --data-urlencode "end=${END_NS}" \
        --data-urlencode "limit=10" \
        "${LOKI_BASE_URL}/loki/api/v1/query_range" 2>/dev/null || true)"

    if [[ -n "$RESPONSE" ]] && grep -Fq "$TEST_MESSAGE" <<<"$RESPONSE"; then
        pass "Log successfully retrieved from Loki"
        return 0
    fi

    sleep "$LOKI_QUERY_SLEEP_SECONDS"
done

die "Log not found after retries"
```

}

functional_test() {
step "Running functional validation"

```
push_log
query_log

pass "Functional validation passed"
```

}

summary() {
step "Validation summary"
info "Endpoint: ${LOKI_BASE_URL}"

```
if [[ "$EXPECT_INGESTION" == "1" ]]; then
    info "Functional test: enabled"
else
    info "Functional test: skipped"
fi

pass "Loki validation completed successfully"
```

}

# ==============================================================================

# Main

# ==============================================================================

main() {
step "Starting Loki validation"

```
require_root
require_commands

check_service
check_listener
check_ready

if [[ "$EXPECT_INGESTION" == "1" ]]; then
    functional_test
else
    info "EXPECT_INGESTION not set; skipping functional test"
fi

summary
```

}

main "$@"
