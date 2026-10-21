# Onboarding an application

One application = one ticket. The checklist below is what the ticket should contain and
what "done" means. The helpdesk API in this repository was onboarded exactly this way.

## 1. Information to collect from the application team

| Item | Example | Why |
|---|---|---|
| Service name | `helpdesk-api` | becomes `service.name` and the `service_name` label everywhere |
| Owner team and contact | Service Desk Apps, apps-support@... | alert routing |
| Runtime and framework | Python 3.12, FastAPI, PostgreSQL | decides the instrumentation |
| Servers and environments | `app-01`, `app-02`; production, test | where the agent must run |
| Critical endpoints | `POST /tickets`, `GET /tickets/{id}` | dashboard and SLO focus |
| Existing monitoring | none / Prometheus endpoint / log files | what can be reused |

Naming rules: `service.name` is lowercase with hyphens, unique, and stays the same across
environments. The environment goes in `deployment.environment.name`, never in the name
(`helpdesk-api` with `production`, not `helpdesk-api-prod`).

## 2. Choose how the telemetry gets out

| Situation | Approach |
|---|---|
| Java, Python, .NET, Node.js | automatic instrumentation: agent or package plus environment variables, no code change |
| Application already exposes Prometheus metrics | `prometheus` receiver in the local agent scrapes it |
| Only log files | `filelog` receiver in the local agent |
| Code owned by the team, custom business metrics wanted | OpenTelemetry SDK in the code |

For the helpdesk API: Python automatic instrumentation, see [`app/Dockerfile`](../app/Dockerfile)
and the `OTEL_*` variables in [`docker-compose.yml`](../docker-compose.yml).

## 3. Configuration

```bash
OTEL_SERVICE_NAME=helpdesk-api
OTEL_RESOURCE_ATTRIBUTES=service.version=1.1.0,deployment.environment.name=production
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317   # the agent on the same server
OTEL_SEMCONV_STABILITY_OPT_IN=http                   # stable HTTP metric names
OTEL_PYTHON_FASTAPI_EXCLUDED_URLS=health             # health checks are noise
OTEL_LOGS_EXPORTER=otlp                              # logs through the same agent
OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
```

The server needs the agent: `sudo bash scripts/install-otel-agent.sh --gateway <gateway>:4317 --environment production`.

## 4. Verification

Run each query in Prometheus (or Grafana Explore) after a few minutes of traffic.

| Check | Query | Expected |
|---|---|---|
| Metrics arrive | `count(http_server_request_duration_seconds_count{service_name="helpdesk-api"})` | > 0 |
| Routes are templated | `count by (http_route) (http_server_request_duration_seconds_count{service_name="helpdesk-api"})` | `/tickets/{ticket_id}`, not one series per id |
| Environment is set | `count by (deployment_environment_name) (target_info{job="helpdesk-api"})` | one value |
| Host metrics | `system_memory_utilization_ratio{host_name="app-01"}` | present |
| Traces | Tempo: `{resource.service.name="helpdesk-api"}` | recent traces with database spans |
| Logs | Loki: `{service_name="helpdesk-api"} \| trace_id != ""` | log lines linked to their trace |

Cardinality: no user ids, ticket ids or e-mail addresses in labels. Check with
`count({service_name="helpdesk-api"})` before and after onboarding.

## 5. Done when

- [ ] metrics, traces, logs and host metrics visible in the dashboards *HTTP service overview* and *Linux hosts*
- [ ] alerts `HighErrorRate` and `HighLatency` apply to the service (they work for any `service_name`)
- [ ] thresholds agreed with the team if the defaults (5 % errors, 500 ms p95) do not fit
- [ ] owner and runbook link recorded in the ticket
- [ ] application team has seen the dashboard and knows where to find it
