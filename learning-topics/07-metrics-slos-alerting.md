# Topic 07 — Metrics, SLOs and Alerting: Prometheus, Grafana, Alertmanager

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

This covers roadmap steps `07-prometheus-grafana` and `08-alerting-slo` (`LEARNING-ROADMAP.md`
§07–08). The work is in `gitops` (`addons/`, `observability/`, `tests/prometheus`) and the app
repo (Spring Boot Actuator/Micrometer metrics). A plain-language map of the layout is in
`gitops/docs/STRUCTURE.md`.

---

## 1. The concept

- **Prometheus pulls.** Every 15–30s it scrapes `/metrics`-style endpoints and stores time
  series. A *ServiceMonitor* (Prometheus Operator CRD) tells it which Services to scrape.
- **Metric types**: counters (only go up: requests), gauges (go up and down: memory),
  histograms (bucketed observations: latency). Percentiles come from histograms with
  `histogram_quantile`; you can't average p95s across pods.
- **Cardinality** is the way to break Prometheus: every label value combination is a new
  series. Never put user IDs, request IDs or raw URLs in labels.
- **Symptom-based alerting**: page on what users feel (errors, slowness), not on causes
  (CPU at 90%). Every alert needs a runbook and a person who can act on it.
- **SLI / SLO / error budget**: the SLI is the measurement (share of requests that
  succeeded), the SLO the target (99.5% over 30 days), the budget what's left to fail (0.5%).
- **Burn rate**: how fast the budget is being spent. 1× spends it in exactly 30 days; 14.4×
  spends 2% of it in an hour. **Multi-window multi-burn-rate** alerts (Google SRE workbook)
  page on fast burns and open tickets on slow ones, and need a short and a long window to
  agree so a single spike doesn't page anyone.
- **Dead man's switch**: an alert that always fires. If the heartbeat stops arriving, the
  alerting pipeline itself is broken.

---

## 2. This repo's actual implementation

**Installation** — `gitops/addons/applications/kube-prometheus-stack.yaml` (chart 61.3.0), with
layered values: `addons/values/common` (every environment), `local` or `cloud`, then
`<env>`. Cloud: 2 Prometheus replicas, 30 days / 45 GB retention on `gp3` (prod `gp3-retain`, see
topic 06), 3 Alertmanager replicas, exemplar storage on.

**App metrics** — Spring Boot Actuator + Micrometer expose `/actuator/prometheus`; both
services publish latency histograms with SLO buckets (`application.properties`:
`percentiles-histogram`, `slo=100ms,250ms,500ms,...`). Scraped by
`gitops/apps/base/{order,user}-service/servicemonitor.yaml`.

**SLOs** — `gitops/observability/base/slo-rules.yaml`:

| SLO | Target (30 days) | Budget |
|---|---|---|
| Availability: requests without a 5xx | 99.5% | 0.5% |
| Latency: requests within 500ms | 99% | 1% |

Recording rules `slo:sli_error:ratio_rate{5m,30m,1h,2h,6h,1d,3d,30d}` (and `sli_latency_slow`)
feed four alerts: `SLO{Availability,Latency}BudgetBurn{Fast,Slow}` — fast = 14.4× over 1h *and*
5m, or 6× over 6h *and* 30m (critical, pages); slow = 3× over 1d or 1× over 3d (warning).
Actuator endpoints are excluded from the SLIs.

**Other alerts** — `service-alerts.yaml` (`ServiceDown`, `ServiceMetricsMissing`) and
`pipeline-alerts.yaml` (logs or traces stopped reaching Loki/Tempo). Every alert has a
`runbook_url` into `gitops/docs/runbooks.md`.

**Routing** — `addons/values/cloud/kube-prometheus-stack.yaml`:
```
Watchdog         -> heartbeat webhook, every minute
severity=critical -> PagerDuty (and Slack, via continue: true)
severity=warning  -> Slack
inhibit: critical silences warning/info of the same alert; ServiceDown silences that job's SLO alerts
```
Receiver credentials come from AWS Secrets Manager through an ExternalSecret
(`observability/components/cloud-secrets`), never from Git.

**Dashboards as code** — JSON in `observability/base/dashboards/`, shipped as ConfigMaps that
Grafana's sidecar loads: *Microservices* (CPU, memory, rate, 5xx, p95, logs, traces) and
*Service Level Objectives* (budget left, burn rates).

**Tests** — `tests/prometheus/*.yaml` are `promtool test rules` unit tests: synthetic series in,
expected alerts out. `scripts/validate.sh` runs them with every other check.

---

## 3. Real incidents

### 3.1 Prometheus wasn't scraping the backends at all

A ServiceMonitor's `selector` matches labels on the **Service object**, not the pods. Neither
Service had any `metadata.labels`, the two `servicemonitor.yaml` files were swapped between the
services, and the `release:` label didn't match the Helm release name. Result: no target, empty
API panels, and a "metrics missing" alert firing permanently — while nothing looked broken in
Git. Fixed in gitops `5fa6e53`. Lesson: check *Status → Targets* before trusting a dashboard.

### 3.2 An "absent" alert that only fired when *both* services were gone

`absent_over_time(up{service=~"order-service|user-service"}[10m])` returns something only when
*no* series match the regex, so one missing service went unnoticed while the other was still
scraped. Fixed in `3b7c94e` with one `absent_over_time` per service joined by `or` (which also
puts the missing service's name on the alert). Absent-checks over a regex are a classic trap.

### 3.3 Alerts and dashboards existed only in the lab

They had been added under the local overlay, so dev/staging/prod had none. Moved to
`observability/base` for every environment (`c99860f`).

### 3.4 Flaky rule tests

Unit tests that asserted on annotation text containing `{{ $value }}` broke whenever the
evaluation step changed the computed value slightly. They now assert on the `ALERTS` series
(fired or not, with which labels) — what actually matters.

### 3.5 Metric names change between versions

The collector's own span counter is `otelcol_receiver_accepted_spans` in the 0.160 collector
used here, but depending on version and exporter settings it can carry a `_total` suffix; the
dashboard matches both
(`{__name__=~"otelcol_receiver_accepted_spans(_total)?"}`, `5f725a4`). Check the real name in
Prometheus before writing a query against it.

### 3.6 A total outage paged nobody for 12 minutes

Found while writing the alert drill. `ServiceDown` is `up == 0`, but a service scaled to 0 (or
crash-looping, or unschedulable) has *no* scrape target, so there's no `up` series to be 0. The
SLO alerts were blind too: they're computed from the services' own request metrics, which
disappear with the pods. Only `ServiceMetricsMissing` fired, after 10 + 2 minutes, describing it
as a configuration problem — and the frontend had no such alert at all. The fix is a signal
that doesn't depend on the pods existing: `ServiceUnavailable` reads ready replicas from
kube-state-metrics (critical, 2 minutes, all three services), and inhibits the alerts it implies
so on-call gets one page (gitops `698f996`). Lesson: test alerts by *breaking things*, not by
reading the rules — `scripts/alert-drill.sh` now does exactly that.

---

## 4. Verify — the full sequence

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090 -n monitoring
# Status -> Targets: serviceMonitor/<ns>/order-service-monitor/0 and user-service UP
# Status -> Rules: slo-rules loaded, no evaluation errors

# The SLIs have data
curl -s 'localhost:9090/api/v1/query?query=slo:sli_error:ratio_rate5m' | jq '.data.result | length'

# Alerting pipeline alive: Watchdog firing
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.labels.alertname=="Watchdog") | .state'

# Rules and tests, offline
./scripts/validate.sh        # includes promtool check rules + promtool test rules

# Break it on purpose: scales order-service to 0, waits for ServiceUnavailable in
# Alertmanager, restores it and waits for the resolve (~4 minutes, lab or EKS)
./scripts/alert-drill.sh order-service development
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| Target missing in *Status → Targets* | ServiceMonitor selector/port name doesn't match the Service, or Prometheus' `serviceMonitorSelector` ignores it |
| Recording rule empty | its input metric name or labels differ from what's scraped (check in *Graph* first) |
| Alert `pending` forever | the `for:` window hasn't elapsed, or the condition flaps |
| No Slack/PagerDuty message | the `alertmanager-receivers` secret is missing (ExternalSecret not synced) or routing sends it to `null` |
| Grafana dashboard edits vanish | dashboards are code: edit the JSON in Git, not the UI |

---

## 6. Exercise — close the loop on what's still open

1. Put real Slack and PagerDuty keys in Secrets Manager for dev (`microservices/dev/alerting`),
   run `scripts/alert-drill.sh`, and check the page *and* the resolve arrive. Then break things
   the drill doesn't: the DB connection (bad `MONGO_URI`), a full PVC, CPU exhaustion — and note
   which alert fired for each and how long it took.
2. Compute by hand how many failed requests a month the 99.5% availability SLO allows at your
   current traffic, and check it against the SLO dashboard.
3. Turn on remote write to Amazon Managed Prometheus (commented in the cloud values) and
   compare 30-day local retention with long-term remote storage.
