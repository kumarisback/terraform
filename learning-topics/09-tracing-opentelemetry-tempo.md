# Topic 09 — Distributed Tracing: OpenTelemetry, Tail Sampling, Tempo

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

This is roadmap step `10-tracing-otel` (`LEARNING-ROADMAP.md` §10), across the app repo (the
Java agent in the images, the browser SDK in the frontend) and `gitops` (the collector tiers,
Tempo, Grafana's links between logs, metrics and traces). The full path is drawn in
`gitops/docs/observability-pipeline.html`.

---

## 1. The concept

- **Trace and spans**: one request = one *trace*; every hop or operation in it = a *span* with a
  start, a duration, a parent, and attributes. The waterfall answers "which of these services
  made this request slow or fail?" — something logs and metrics can't.
- **Context propagation**: each hop passes the W3C `traceparent` header
  (`00-<trace id>-<parent span id>-<flags>`) to the next, so spans from different processes join
  into one trace.
- **OpenTelemetry** is the vendor-neutral standard: SDKs/agents create spans, the *Collector*
  receives, processes and exports them, and any backend (Tempo, Jaeger, X-Ray) can store them.
- **Sampling**: storing every trace is expensive. *Head* sampling decides at the start (cheap,
  but blind: a 10% sample throws away 90% of the error traces). *Tail* sampling decides after
  the whole trace has arrived, so it can keep every error and every slow request.
- **Tail sampling needs the whole trace in one place**: with several sampler replicas, all spans
  of a trace must reach the same one — the job of a load-balancing tier routing by trace ID.
- **Correlation**: the `trace_id` on log lines (topic 08) and on metric exemplars (topic 07) is
  what lets Grafana jump between the three.

---

## 2. This repo's actual implementation

**Java services** — the OpenTelemetry Java agent 2.13.3 is baked into each image
(`-javaagent` in the Dockerfile): HTTP server/client, MongoDB and Spring spans with no code
changes. Its settings come from `gitops/apps/components/otel-instrumentation` (endpoint
`otel-collector...:4318`, `http/protobuf`, propagators `tracecontext,baggage`, `OTEL_SERVICE_NAME`
from the pod's `app` label) plus each overlay's `otel-environment` ConfigMap. The agent sends
every span (`parentbased_always_on`); sampling happens later. Its logback-MDC instrumentation
puts `trace_id`/`span_id` on every log line by default.

**Browser** — the frontend uses the OpenTelemetry web SDK (`src/lib/otel.js`): fetch
instrumentation adds `traceparent` to API calls, `traceFetch` wraps each call in its own span,
and spans are exported to `/otlp/v1/traces` on the same origin. The backend's CORS config allows
`traceparent`, `tracestate`, `baggage` (app `a48f5e9`).

**Ingress** — Traefik (lab) records a span per request and continues the browser's trace; in the
cloud `/otlp` is routed through the ALB (`observability/components/browser-otlp-alb`).

**Collector, two tiers** (`addons/values/common/otel-collector*.yaml`, chart 0.173.1):
```
apps, Traefik :4317/:4318 ─┐
browser :4319 (1 MiB cap) ─┴─► gateway: k8sattributes (pod, namespace, deployment)
                                  └─ loadbalancing exporter, routed by trace ID
                                       └─► sampler (headless Service):
                                             spanmetrics + servicegraph from 100% of spans -> Prometheus
                                             tail_sampling: keep ERROR, keep > 500ms,
                                                            keep N% of the rest -> Tempo
```
N = 100% in the lab and dev, 50% in staging, 10% in prod (`TAIL_SAMPLING_PERCENTAGE`).

**Tempo** (chart 1.24.4) — local disk in the lab, S3 in the cloud (14 days; bucket and IRSA from
topic 06). Grafana: log line → trace via the `trace_id` link; span → "Logs for this span";
latency/error panels → exemplar dots that open the trace; a service map from `servicegraph`.

---

## 3. Real incidents

### 3.1 Head sampling threw away the traces that mattered

Apps sampled at the source (10% in prod), so 90% of production *error* traces were dropped
before anyone could look. Replaced with the two-tier tail-sampling setup above (gitops `3fe54c6`);
span metrics are computed from all spans *before* sampling, so dashboards stay exact.

### 3.2 The ingress continued traces it never recorded

The Ingress annotations enabled tracing, but the controller's defaults were "no collector host"
and an `AlwaysOff` sampler. Context still propagated, so every backend trace started under a
parent span Tempo never received — a hole at the top of each waterfall (`e0aae15`). (The lab has
since moved to Traefik, configured in `local-setup/traefik-values.yaml`.)

### 3.3 A setting that did nothing, but looked important

`OTEL_INSTRUMENTATION_LOGBACK_MDC_TRACE_ID` was set in every overlay. It isn't an agent setting;
`trace_id` reached the logs because the agent's logback-MDC instrumentation is on by default.
Removed (`0570938`) so nobody believes it's the switch that makes correlation work. Check every
setting against the docs.

### 3.4 Browser spans arrive from the internet

The browser's export endpoint is public, so it got its own receiver (port 4319, traces only,
1 MiB request cap) and its own pipeline without `k8sattributes` — through the ingress, the
"client pod" would be the proxy (`27a149d`). Rate-limit `/otlp` (WAF) before relying on it in prod.

---

## 4. Verify — the full sequence

```bash
# Send a request through the front door (lab), then find its trace
curl -s http://localhost/api/orders/status
# Grafana -> Explore -> Tempo -> Search: service.name = order-service, last 5 minutes

# Spans arrive at the collector and leave for Tempo
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090 -n monitoring
#   sum(rate(otelcol_receiver_accepted_spans[5m]))       > 0
#   sum(rate(otelcol_exporter_sent_spans[5m])) by (job)  > 0 for the sampler

# Tail sampling keeps errors: cause a 500 and confirm its trace is in Tempo
# TraceQL: { status = error }

# Correlation: a log line's trace_id link opens the same trace; the trace's
# "Logs for this span" shows that log line
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| Each service shows its own one-span trace | `traceparent` not forwarded (CORS, proxy stripping headers, or a client the agent doesn't instrument) |
| Trace missing its top span | the ingress/browser doesn't export (sampler off, wrong endpoint) |
| Traces missing at random | sampler overloaded: `num_traces` too small (`TailSamplerOverloaded` alert) |
| `TraceGatewayHasNoSamplers` | sampler pods down; the gateway resolves them by DNS |
| Tempo has spans, logs have no `trace_id` | log written outside a request span, or the JSON encoder lacks `<mdc/>` |

---

## 6. Exercise — close the loop on what's still open

1. Add an artificial 2s delay in order-service, find it in the waterfall, and check it's kept by
   the latency policy even at prod's 10%.
2. Add one manual span in a Java service (`@WithSpan` or the OpenTelemetry API) around a piece of
   business logic, with an attribute, and find it in Tempo.
3. Turn Tempo's metrics-generator on and compare its span metrics with the collector's
   `spanmetrics` connector — then decide which one to keep.
