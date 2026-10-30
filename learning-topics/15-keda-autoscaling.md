# Topic 15 — KEDA: event-driven autoscaling

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `15-keda-autoscaling`. All in gitops (the add-on, the chart, the services'
values, alerts) plus a setting in notification-service; nothing in this repo. The user guide
is `gitops/docs/KEDA.md`.

---

## 1. The concept

- **Scale on the work, not its side effects.** CPU is a proxy for load that holds for APIs
  doing computation. For a queue consumer the load is the backlog: one waiting on a slow
  provider uses no CPU while the queue grows. Scale it on lag, a job runner on queue length, an
  API on requests per second.
- **The HPA and the external metrics API.** An HPA computes `desired = ceil(current ×
  metric / target)` from metrics served by the Kubernetes metrics APIs: resource (CPU and
  memory, metrics-server), custom (per pod) and external (anything, per workload). KEDA is an
  adapter for the external API plus an operator: for each `ScaledObject` it creates an HPA
  whose metrics it serves.
- **Zero.** An HPA's minimum is 1. KEDA itself moves a workload between 0 and 1
  (*activation*: is there any work?) and leaves 1 to N to the HPA (*scaling*: how much
  work?). The price of zero is a cold start on the first event.
- **Bounded by parallelism.** A Kafka consumer group can't use more consumers than its
  topics have partitions; past that, replicas sit idle. Partition count is a capacity
  decision made at topic creation (topic 12).
- **Failure modes of an autoscaler.** If the metric can't be read, the HPA freezes, which at
  zero means no work is done at all. A fallback size and an alert on scaler errors cover it.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `addons/applications/keda.yaml` | KEDA 2.21.0 (tested on Kubernetes 1.34–1.36), every environment, server-side apply for its large CRDs; ServiceMonitors for operator and metrics server |
| gitops `charts/microservice` 0.5.0 | `autoscaling.keda`: a ScaledObject instead of the CPU HPA, `minReplicas: 0` only with it, `fallbackReplicas`; `podDisruptionBudget.maxUnavailable`; 6 new tests (31) |
| gitops `streaming/keda`, KafkaUser `keda` | KEDA's own Kafka identity (describe only) delivered into its namespace, named by ClusterTriggerAuthentication `kafka-lag-reader`; KEDA may read Secrets only in `keda` |
| gitops `apps/{local,dev}/notification-service.values.yaml` | Kafka triggers on `orders` and `users`, lag 50 per replica, 0 to 6 (lab 3), fallback 1, PDB max unavailable 1 |
| gitops `apps/{local,dev}/order-service.values.yaml` | Prometheus trigger (20 requests/s per replica) plus CPU 70%; staging and prod keep the CPU HPA |
| gitops `observability/base` | `ServiceUnavailable` only while replicas are wanted; `KedaScalerErrors`, `KedaMetricsMissing`; tests |
| app notification-service | `app.notifications.simulated-latency` for the exercises, with tests |

---

## 3. Real incidents

None of these happened on a cluster. All but 3.5 were found while designing the step, which
is where they are cheapest; 3.5 was found by a review after it was pushed.

### 3.1 The alert that would page for a quiet night

`ServiceUnavailable` fired when a Deployment had no available pods. With KEDA, notification-
service has none every time Kafka is drained: a critical page each quiet evening. The rule now
also requires `kube_deployment_spec_replicas > 0`. Deliberately at zero is quiet; KEDA asking
for a pod that never gets ready still pages two minutes later. A new test covers both.

### 3.2 A disruption budget that blocks every drain

The chart's PodDisruptionBudget keeps at least one pod available. For a service that usually
runs one pod, that means its pod can never be evicted, so every node drain, Karpenter's
consolidation included, waits on it forever. notification-service now allows one pod
unavailable instead; its records wait in Kafka while it moves.

### 3.3 The consumer that would never wake

With no topic named, KEDA's Kafka scaler works out the topics from the group's committed
offsets. A group scaled to zero before its first commit has none, so KEDA sees no lag and
never scales it up again. One trigger per topic avoids that; the HPA takes the larger of the
two.

### 3.4 `namespace` becomes `exported_namespace`

KEDA labels its metrics with the ScaledObject's namespace. Prometheus also sets `namespace`
on everything it scrapes (the target's, `keda`) and, as the chart's ServiceMonitor doesn't
honour scraped labels, renames KEDA's to `exported_namespace`. An alert grouping by
`namespace` would have said every problem was in `keda`.

### 3.5 An autoscaler that could read every Secret

This one shipped. The first version let KEDA read each service's Kafka certificate from the
service's namespace, which the KEDA chart allows by granting the operator `list` and `watch`
on **all** Secrets in the cluster; `list` returns their contents. A security review of the
pushed commit flagged it: one compromised operator, every database password and signing key.
The chart's allow-list option doesn't help, as it only adds a `get` rule beside that
cluster-wide one. Now `permissions.operator.restrict.secret` limits KEDA to its own namespace
(and KEDA's code then refuses Secrets elsewhere), KEDA gets its own KafkaUser that can describe
but not read, delivered into `keda` by a KafkaAccess there, and triggers name it through a
`ClusterTriggerAuthentication`. Least privilege twice over: fewer Secrets, and a weaker
credential in the one it has.

### 3.6 No fallback with a CPU trigger

KEDA's fallback replaces a failing trigger's metric with one that yields the fallback
count. It doesn't support CPU or memory triggers (those come from metrics-server, not KEDA),
so order-service, which keeps a CPU trigger, has no fallback; notification-service, Kafka
only, does.

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh       # KEDA rendered in every env, ScaledObjects against its CRDs, chart and alert tests

# Lab or dev
kubectl get pods -n keda                                  # operator, metrics server, webhooks
kubectl get apiservice v1beta1.external.metrics.k8s.io    # Available: KEDA serves external metrics
kubectl get scaledobject,hpa -n development               # READY True; keda-hpa-<service>
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/development/s0-kafka-orders?labelSelector=scaledobject.keda.sh%2Fname%3Dnotification-service"
# docs/KEDA.md "Try it": a 10,000-event burst, 0 → 3 → 0, then the same with a CPU HPA
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| ScaledObject `READY False`, "error validating" | the admission webhook refused it: a second autoscaler for the same Deployment (an old HPA), or a bad trigger spec |
| ArgoCD can't sync the ScaledObject | KEDA's CRDs not installed yet (the `keda` application syncs first; retry) |
| Kafka trigger errors `secret not found` / empty credentials | Secret `keda-kafka` missing in `keda` (`kubectl get kafkaaccess -n keda`), or a trigger names a namespaced TriggerAuthentication (KEDA can't read Secrets outside `keda`) |
| Kafka trigger errors `not authorized` | KafkaUser `keda` lacks Describe on that group or topic (`streaming/base/users.yaml`) |
| stays at 0 with lag | KEDA can't read the lag (`KedaScalerErrors`), or the trigger names the wrong group/topic |
| never above 3 (or 6) | by design: partition count, or `maxReplicas` |
| flaps between 0 and 1 | `cooldownPeriod` too short for the gaps between bursts |
| order-service scales without load | the Prometheus query counts probe traffic: check its `uri` filter |

---

## 6. Exercise

1. Run the burst in `docs/KEDA.md` and plot, in Grafana, lag, replicas
   (`kube_deployment_status_replicas`) and the HPA's desired replicas on one panel. How long
   from the first event to the first pod ready, and why?
2. Add `ensureEvenDistributionOfPartitions` to the `orders` trigger. Which replica counts
   become possible, and what changes in how evenly partitions are shared?
3. Make the Kafka trigger work with Amazon MSK (step 14): `sasl: oauthbearer`,
   `saslTokenProvider: aws_msk_iam`, and an IAM role for the KEDA operator. Which
   `kafka-cluster` actions does it need?
4. Find the requests per second one order-service replica handles at your latency objective
   (step 40's load tests) and set the Prometheus trigger's threshold from it.
