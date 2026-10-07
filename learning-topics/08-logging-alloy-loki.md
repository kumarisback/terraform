# Topic 08 — Centralized Logging: Structured JSON, Alloy, Loki

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

This is roadmap step `09-elk-logging` (`LEARNING-ROADMAP.md` §09), done with the Grafana stack
(Alloy + Loki) instead of ELK — its item 9, "install Loki and compare". The ELK half is still
open (§6). Work is in the app repo (log format, the API request log) and `gitops`
(`addons/values/*/alloy.yaml`, `*/loki.yaml`, `apps/components/request-logging`). The full path
is drawn in `gitops/docs/observability-pipeline.html`.

---

## 1. The concept

- **Containers log to stdout**; the node keeps it under `/var/log/containers/`. A *shipper*
  reads it, adds Kubernetes metadata (namespace, pod, container), and sends it to a store.
- **Structured (JSON) logs** turn every field into something you can filter on, instead of
  regex-ing free text. Non-negotiable at scale.
- **Correlation**: put the request's `trace_id` on every line, and one ID finds the request's
  logs in every service *and* opens its trace.
- **Loki vs Elasticsearch**: Elasticsearch indexes every word (fast free-text search, heavy on
  RAM and disk). Loki indexes only a few labels and stores compressed lines in S3 (cheap; you
  narrow by labels, then filter text). Labels must stay low-cardinality — never a user or
  request ID.
- **Three kinds of line per request** (how enterprises split it):
  *edge* (the load balancer's access log: what the client got), *api* (one line per request
  inside the service: method, route, status, duration), *server* (everything else the code
  writes). All share the `trace_id`.
- **Logs leak secrets and personal data.** Mask at the source, mask again in the pipeline, log
  request payloads only where needed, never response bodies.

---

## 2. This repo's actual implementation

**Log format (app repo)** — `logback-spring.xml` in both services uses logstash-logback-encoder:
`@timestamp`, `service`, `environment` (from `DEPLOYMENT_ENVIRONMENT`), `level`, `logger`,
`message`, MDC (`trace_id`, `span_id` from the OpenTelemetry agent), every `kv(...)` argument as
a top-level field, and the stack trace as one escaped string so a line stays one line.

**API request log (app repo)** — `web/RequestLoggingFilter.java`: one `http_request` line per
request on logger `access.<service>.http`, with OpenTelemetry field names
(`http.request.method`, `url.path`, `http.route`, `http.response.status_code`, `duration_ms`,
`error.type`). `/actuator` isn't logged. The JSON request payload is added according to
`APP_HTTP_LOGGING_REQUEST_BODY`, set per environment by `gitops/apps/components/request-logging`:

| Environment | Level | Payload logged for |
|---|---|---|
| local, dev | `ALWAYS` | every request |
| staging, prod | `ERRORS` | 4xx/5xx only |
| unset | `NEVER` | none |

Keys containing password/token/secret/... are masked at any depth, payloads are cut at 2048
characters, response bodies are never logged. Unit tests: `RequestLoggingFilterTest`.

**Shipper: Grafana Alloy** — `gitops/addons/values/common/alloy.yaml`, one Deployment (clustered
when scaled) reading pods through the Kubernetes API (`loki.source.kubernetes`). Pipeline:
1. mask bearer tokens, JWTs, secret-like JSON keys (also inside escaped payloads), query-string
   secrets, MongoDB URI credentials;
2. join multi-line output — only for the Spring containers;
3. label `log_type`: `api` (logger `access.*`), `server` (other Spring lines and Traefik's own),
   `edge` (Traefik access lines);
4. tenant `apps` for the application namespaces, `platform` for everything else.

`tests/alloy/pipeline_cases.yaml` feeds sample lines through a **real Alloy** and checks the output.

**Store: Loki** (chart 6.6.2, single binary). Cloud: 3 replicas, replication factor 3, chunks in
S3 (topic 06), retention 30 days for `apps`, 7 for `platform`, enforced by the compactor.
Grafana queries both tenants (`X-Scope-OrgID: apps|platform`) and turns `trace_id` into a link
to Tempo.

**Edge log** — Traefik's JSON access log in the lab. In the cloud the ALB writes it to S3
(annotation documented in `gitops/apps/base/ingress.yaml`; needs a bucket in `tf` first).

---

## 3. Real incidents

### 3.1 A config that passed `alloy validate` and still stopped Alloy

The `log_type` match selectors used backtick strings. `alloy validate` only checks syntax, but
the match stage's LogQL parser rejects backticks at runtime, so Alloy wouldn't start (gitops
`fda997f`, fixed in `054932b`). That's why `tests/alloy` now runs the pipeline in a real Alloy.

### 3.2 The multiline rule glued unrelated logs together

Applied cluster-wide, "a new entry starts at `{`" joined plain-text lines from nginx, the
ingress controller, Loki and ArgoCD into blocks of up to 128 lines. Now only the Spring
containers get it (`b951770`).

### 3.3 Every log line shipped once per node

Alloy ran as a DaemonSet. `loki.source.kubernetes` reads logs through the Kubernetes API, and
without clustering each instance collects *every* pod it discovers — so each pod was tailed once
per node (twice on the kind cluster), doubling API-server log streams and Loki ingest. One
Deployment replica covers the lab; clustering shares the pods out when it's scaled (`0282f28`).

### 3.4 Redaction ate half a URL

Traefik writes `&` as `&` in JSON, so the query-string rule `token=([^&\s]+)` ran past the
real end of the value and masked the rest of the query too. The value now also stops at a
backslash (`f0bc79d`), with a test case.

### 3.5 The API log was all health checks

Kubernetes probes and Prometheus scrapes outnumbered real calls. First dropped in Alloy; then
done properly at the source — the filter skips `/actuator` — and the Alloy rule removed
(`bce7485`).

### 3.6 A chart value in the wrong place, silently ignored

`serviceAccount` sat under `loki:` in the cloud values; it's a top-level chart value, so the
chart ignored it and would have created its own ServiceAccount *without* the IRSA annotation —
no S3 access. The same values also lacked the `schemaConfig` chart 6.6.2 requires, so the
Application could never have synced (`d1da68a`). Helm doesn't warn about unknown keys: check
keys against the chart's own `values.yaml`, and render with `helm template` (validate.sh does).

### 3.7 Secrets the masking rules didn't cover

A security review flagged sensitive data reaching the log store, and four test cases proved it:
`Authorization: Basic …` and `Cookie:` values in HTTP header dumps (only Bearer was masked),
numeric values of secret keys — a card number, a CVV — in plain and escaped JSON (only string
values were masked), AWS access key IDs and PEM private keys. New rules cover each one (gitops
`2826ee9`), with replacements that keep the line valid JSON. Lesson: masking rules are a list
of *known* shapes; review them against real header dumps and payloads, and add a test case for
every shape you add.

### 3.8 A field that was both a value and a parent

The API log had `http.request.body` (the payload) next to `http.request.body.size`. Loki stores
lines as text, so it never mattered; Elasticsearch expands dotted names into objects and can't
make `body` both a string and an object. Elasticsearch 9 didn't even reject the line — it moved
it to the data stream's *failure store* and answered "created", so it simply never showed up in
searches. Renamed to `http.request.body.content` (the ECS name) in the services (app
`76da762`), with a unit test that no logged field name is the prefix of another.

---

## 4. Verify — the full sequence

```bash
./scripts/validate.sh                      # alloy validate, loki -verify-config, real-Alloy cases

# Alloy has targets and is sending
kubectl port-forward deploy/alloy-logs 12345 -n monitoring   # http://localhost:12345

# In Grafana -> Explore -> Loki
{namespace="development", log_type="api"} | json | http_response_status_code >= 400
{namespace="development", log_type="server"} | json | level="ERROR"
{namespace="traefik", log_type="edge"} | json | KubernetesIngressNamespace="development"
{log_type=~".+"} |= "<a trace_id>"          # one request across edge, api and server

# Secrets masked (should return nothing)
{namespace="development"} |~ "(?i)\"password\":\"[^<]"
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| No logs at all in Loki | Alloy not running or crash-looping on config: `kubectl logs deploy/alloy-logs -n monitoring` |
| Logs present, no `log_type` | line doesn't match a selector (logger name changed?) — add a case in `tests/alloy` |
| `| json` returns nothing | the line isn't one JSON object (a multi-line join, or plain text) |
| `429` from Loki | per-tenant ingestion limit — `limits_config` / `runtimeConfig.overrides` |
| Old logs missing in the cloud | retention (30/7 days) or the S3 bucket's safety-net expiry |

---

## 6. Exercise — close the loop on what's still open

1. Do the ELK half of the roadmap step on a throwaway branch, timeboxed: ECK with a
   single-node Elasticsearch + Kibana, Fluent Bit as a DaemonSet, an ILM policy (hot 2 days,
   delete at 7), the same masking. Then write down cost, RAM and query experience next to Loki's.
2. Turn on ALB access logs for dev (bucket in `tf`, annotation on the Ingress) and query them
   with Athena.
3. Add a log-based alert in Loki's ruler (e.g. more than N `unhandled_exception` per minute) and
   decide whether it should page or ticket.
