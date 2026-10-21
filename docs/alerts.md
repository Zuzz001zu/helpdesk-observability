# Alerts runbook

Rules: [`prometheus/rules/helpdesk.yml`](../prometheus/rules/helpdesk.yml),
tests: [`prometheus/tests/helpdesk.test.yml`](../prometheus/tests/helpdesk.test.yml).

## HighErrorRate

More than 5 % of the requests of a service return a 5xx status for 5 minutes, with at least
0.1 requests per second (low-traffic services would otherwise page on two failures).

1. *HTTP service overview* → **Requests by status code** and **Requests by route**: one route or all of them?
2. **Recent traces with errors**: open a trace, the failing span shows the exception.
3. All routes failing at once usually means a dependency: check the database spans and
   the database server in *Linux hosts*.
4. A deployment in the last hour? Compare `service_version` in `target_info{job="<service>"}`.

4xx responses are not counted: they are caller errors (validation, unknown ids, workflow conflicts).

## HighLatency

p95 above 500 ms for 10 minutes.

1. **p95 latency by route**: is it one route (a slow query) or every route (saturation)?
2. In Tempo, sort the traces of the slow route by duration and look for the longest span.
3. *Linux hosts*: CPU, memory and load of the server running the service.
4. **Database connections**: a pool that is always fully used makes requests queue.

## TelemetryPipelineDown

Prometheus cannot scrape the gateway or a collector for 2 minutes. Dashboards will
show gaps and other alerts may stay silent, so treat it as urgent.

1. `systemctl status otelcol-contrib` and `journalctl -u otelcol-contrib -n 100` on the server
   (or `docker compose ps` / `docker compose logs otel-gateway` here).
2. Health endpoint: `curl -s http://<host>:13133/`.
3. A recent configuration change: validate it with `otelcol-contrib validate --config <file>`.

## CollectorExportFailing

A collector keeps failing to send data to the next hop (gateway, Tempo, Prometheus).
Data is queued and retried, then dropped.

1. *Telemetry pipeline* dashboard: which exporter, and is its queue growing?
2. Can the collector reach the next hop? `curl -v telnet://<gateway>:4317` from the server.
3. Gateway overloaded? Check its memory and `otelcol_receiver_refused_*` metrics.

## HostMemoryHigh

More than 90 % of memory used on a host for 10 minutes. Find the process
(`ps aux --sort=-rss | head`), check whether it is expected growth or a leak, and whether
swap is being used (`free -h`, `vmstat 5`).

## HostDiskAlmostFull

A writable file system is more than 85 % full for 15 minutes. Read-only mounts
(images, snapshots) are excluded on purpose.

1. `df -h` and `du -xh --max-depth=1 <mountpoint> | sort -h | tail` to find what grew.
2. Usual suspects: logs without rotation, old releases, core dumps, `/var/tmp`.
