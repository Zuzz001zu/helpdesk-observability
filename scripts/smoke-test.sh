#!/usr/bin/env bash
# End-to-end check of the running stack: does telemetry really get from the
# application to Prometheus, Tempo and Grafana?
#
#   docker compose up -d
#   python3 scripts/generate_traffic.py --duration 60 &
#   bash scripts/smoke-test.sh

set -euo pipefail

API_URL=${API_URL:-http://localhost:8000}
PROMETHEUS_URL=${PROMETHEUS_URL:-http://localhost:9090}
TEMPO_URL=${TEMPO_URL:-http://localhost:3200}
LOKI_URL=${LOKI_URL:-http://localhost:3100}
GRAFANA_URL=${GRAFANA_URL:-http://localhost:3000}
GRAFANA_USER=${GRAFANA_USER:-admin}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD:-admin}
SERVICE=${SERVICE:-helpdesk-api}
TIMEOUT=${TIMEOUT:-180}

failures=0

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

# eventually <description> <command...>: retry until the command succeeds or TIMEOUT expires
eventually() {
    local description=$1
    shift
    local deadline=$((SECONDS + TIMEOUT))
    until "$@" >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            fail "$description (gave up after ${TIMEOUT}s)"
            return 0
        fi
        sleep 5
    done
    pass "$description"
}

prometheus_has() {
    local query=$1
    curl -fsS --get "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$query" |
        jq -e '.data.result | length > 0'
}

tempo_has_traces() {
    curl -fsS --get "$TEMPO_URL/api/search" \
        --data-urlencode "q={resource.service.name=\"$SERVICE\"}" --data-urlencode "limit=5" |
        jq -e '.traces | length > 0'
}

loki_has_logs() {
    curl -fsS --get "$LOKI_URL/loki/api/v1/query_range" \
        --data-urlencode "query={service_name=\"$SERVICE\"}" --data-urlencode "limit=5" |
        jq -e '.data.result | length > 0'
}

loki_logs_have_trace_ids() {
    curl -fsS --get "$LOKI_URL/loki/api/v1/query_range" \
        --data-urlencode "query={service_name=\"$SERVICE\"} | trace_id != \"\"" --data-urlencode "limit=5" |
        jq -e '.data.result | length > 0'
}

prometheus_has_rule() {
    curl -fsS "$PROMETHEUS_URL/api/v1/rules" | jq -e --arg name "$1" '[.data.groups[].rules[].name] | index($name)'
}

grafana_dashboards() {
    curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$GRAFANA_URL/api/search?type=dash-db" | jq -e 'length >= 3'
}

grafana_datasource_ok() {
    curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$GRAFANA_URL/api/datasources/uid/$1/health" |
        jq -e '.status == "OK"'
}

# Tempo has no backend health check in Grafana: call Tempo through Grafana's proxy instead
grafana_reaches() {
    curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$GRAFANA_URL/api/datasources/proxy/uid/$1$2"
}

echo "Application"
eventually "API answers on $API_URL/health" curl -fsS "$API_URL/health"

echo "Metrics"
eventually "HTTP metrics of $SERVICE in Prometheus" \
    prometheus_has "http_server_request_duration_seconds_count{service_name=\"$SERVICE\"}"
eventually "host metrics from the agent" prometheus_has 'system_memory_utilization_ratio'
eventually "all collectors scraped" prometheus_has 'sum(up{job=~"otel-gateway|otel-collectors"}) == 3'
eventually "alert rules loaded" prometheus_has_rule HighErrorRate

echo "Traces"
eventually "traces of $SERVICE in Tempo" tempo_has_traces

echo "Logs"
eventually "logs of $SERVICE in Loki" loki_has_logs
eventually "log lines carry the trace id" loki_logs_have_trace_ids

echo "Grafana"
eventually "Grafana is up" curl -fsS "$GRAFANA_URL/api/health"
eventually "dashboards provisioned" grafana_dashboards
eventually "Prometheus data source works" grafana_datasource_ok prometheus
eventually "Grafana reaches Tempo" grafana_reaches tempo /api/echo
eventually "Grafana reaches Loki" grafana_reaches loki /loki/api/v1/labels

echo
if ((failures > 0)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
