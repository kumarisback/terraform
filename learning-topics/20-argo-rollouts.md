# Topic 20 — Progressive delivery with Argo Rollouts

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `20-argo-rollouts`. All in gitops (the add-on, the chart's `rollout:` values,
frontend's Rollout, the mesh, ArgoCD settings, alerts) and one switch in the app; nothing in
this repo. The user guide is `gitops/docs/ROLLOUTS.md`.

---

## 1. The concept

- **Ready isn't good.** A rolling update moves on as soon as new pods pass their readiness
  check. A version that answers its health check and fails real requests passes it.
- **Canary.** Give the new version a small share of the traffic, measure it, grow the share,
  roll back automatically if the measurements fail. Cheap (a few extra pods), slow (minutes),
  and blast radius limited to the share.
- **Blue/green.** Run the whole new version beside the old one, switch all traffic at once
  when it is approved, switch back as fast. Double the resources for the duration; instant
  cutover and rollback; nothing measured on real users before the switch.
- **Analysis is the point.** The gate must be what users feel: error rate and latency of the
  *new version's own* requests, not CPU, not the service's overall numbers.
- **Who moves the traffic.** Without a router a canary's weight is a pod ratio (one in two
  pods is 50%). A gateway or a mesh makes it a share of requests; a mesh does it for every
  caller, a gateway only for traffic that passes it.
- **GitOps and a controller that edits live objects.** Argo Rollouts changes Service
  selectors and traffic weights during a release; the GitOps tool must not undo that.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `addons/applications/argo-rollouts.yaml`, `addons/values/*/argo-rollouts.yaml` | Argo Rollouts 1.10.2 (chart 2.43.9), two controllers in the cloud; RBAC for Istio only; ServiceMonitor with `namespace` restored; dashboard off |
| gitops `charts/microservice` 0.9.0 | `rollout.enabled`: a Rollout instead of the Deployment, Service `<name>-canary`, AnalysisTemplate `<name>-canary`, `podTargetLabels: [rollouts-pod-template-hash]`, HPA/KEDA/VPA pointed at the Rollout; `withoutRequests: wait|pass`; 14 new unit tests |
| gitops `apps/<env>/order-service.values.yaml` | Canary on in every env, through VirtualService `order-service`; lab 20%/50% a minute each; `pass` except in prod |
| gitops `apps/base/mesh.yaml` | Route `primary` with `order-service` 100 / `order-service-canary` 0; caller policies also on the canary and preview Services |
| gitops `apps/base/frontend/rollout.yaml` | Blue/green, `frontend-preview`, manual promotion, one preview pod |
| gitops `bootstrap/...` | `ignoreDifferences` on the weights with `RespectIgnoreDifferences`; `PruneLast` |
| gitops `observability/base/rollout-alerts.yaml`, `service-alerts.yaml` | `RolloutFailed`, `ArgoRolloutsControllerUnavailable`; `ServiceUnavailable` from `rollout_info_replicas_*` too; tested |
| app `order-service` | `app.fault.error-rate`: fails that share of API requests with 500, after the metrics filter; 5 tests |

---

## 3. Real incidents

All found while building the step; none on a cluster yet.

### 3.1 Two ways to weight traffic in the mesh, neither ideal

Istio calls VirtualServices on ambient waypoints alpha and Service-attached HTTPRoutes beta,
and says not to mix them on one Service. Argo Rollouts drives HTTPRoutes only through its
Gateway API plugin, a binary the controller downloads at start-up, one per CPU architecture:
the lab may be an ARM laptop and the cloud Intel nodes, and the controller takes one pinned
URL. The built-in Istio router needs nothing extra, and order-service already had a
VirtualService (step 18's retries). Chosen, and written down as the thing to revisit.

### 3.2 A second Service would have doubled every count

The first canary Service carried the chart's usual labels, `app` included. The ServiceMonitor
selects Services by `app`, so Prometheus would have scraped every pod twice, once per Service,
and every `sum(rate(...))`, the SLOs included, would have counted each request twice. The
canary Service has no `app` label; a unit test keeps it that way.

### 3.3 0/0

With no requests the error rate is 0/0, which is no number at all. Argo Rollouts' examples
let an empty result pass. Where traffic never stops, an empty result means the metrics broke
(a label renamed, a ServiceMonitor gone), and passing would release everything unexamined.
Where there's no traffic (the lab, dev), refusing would stop every release. So it's a
setting: `wait` makes it inconclusive (the release pauses for a person), `pass` lets it on.
Production waits.

### 3.4 A namespace that wasn't

Argo Rollouts' metrics carry the namespace of the Rollout they describe; scraped, Prometheus
renames that to `exported_namespace` and sets `namespace` to the controller's own. Every
query by namespace, the availability alert included, would have matched nothing. A metric
relabeling in the ServiceMonitor puts it back (KEDA's alerts, step 15, use
`exported_namespace` instead).

### 3.5 Invisible to the availability alert

`ServiceUnavailable` read kube-state-metrics' Deployment series. A Rollout has no Deployment:
frontend and order-service could have lost every pod without a page. The alert now also reads
`rollout_info_replicas_available/desired`, with a test for each kind.

### 3.6 Changing a kind is a delete and a create

Git's Deployment `frontend` became a Rollout `frontend`; ArgoCD would prune the Deployment in
the same sync that creates the Rollout, before its pods were ready: an outage of the frontend
and of order-service in every environment. `PruneLast` makes ArgoCD prune only after the
rest is healthy. The lab's own sync never prunes, so the old frontend Deployment would have
lived on beside the Rollout; the guide says to delete it once. Helm (order-service in the lab)
swaps at once: a minute's gap, in the lab only.

### 3.7 ArgoCD would have reset every canary

The weights are in Git (100/0); during a canary Argo Rollouts sets them to 90/10. Self-heal
would have put them back at once. `ignoreDifferences` on those paths, and
`RespectIgnoreDifferences` so a sync doesn't write them either. The Services' selectors need
nothing: ArgoCD compares only the fields Git sets, and Argo Rollouts adds one.

### 3.8 The commands that stopped working

`kubectl exec deploy/order-service`, `kubectl rollout restart|status deployment/...`, the lab's
rebuild script and the alert drill all assumed Deployments. `kubectl exec svc/order-service`
picks a pod through the Service; the scripts patch the Rollout (a new revision, so a rebuilt
image goes through the canary like any release) and `kubectl scale` works on any kind with a
scale subresource.

### 3.9 A fault the metrics wouldn't have seen

Spring records `http_server_requests` in a filter. A fault filter in front of it would have
answered 500 before anything was recorded: the canary would have failed its users and passed
its analysis. The fault filter runs last, and an integration test checks that its 500s show
up in `/actuator/prometheus`. (The first version also didn't start: two constructors and no
`@Autowired`, caught by the existing tests.)

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh         # Argo Rollouts' CRDs, the Rollouts, chart tests, alert tests
cd app/order-service && ./gradlew test      # the fault switch

# Lab or dev
kubectl argo rollouts list rollouts -n development
kubectl argo rollouts get rollout order-service -n development
kubectl get virtualservice order-service -n development -o jsonpath='{.spec.http[0].route[*].weight}'   # 100 0
kubectl get analysisrun -n development
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| a release stays at its first step, paused | an analysis was inconclusive (no requests, `withoutRequests: wait`), or frontend waiting for promotion |
| every canary is aborted | the analysis query matches the wrong series: check `rollouts_pod_template_hash` is on the metrics (ServiceMonitor `podTargetLabels`) |
| the weights jump back to 100/0 mid-release | something re-applies the VirtualService: ArgoCD without `RespectIgnoreDifferences`, or the lab's sync script |
| the weights never change | the Rollout's `trafficRouting` names another VirtualService or route, or the controller lacks Istio RBAC |
| frontend and order-service missing from `ServiceUnavailable` | Argo Rollouts' metrics not scraped (ServiceMonitor, `release` label) |
| two frontend versions after the first lab sync | the old Deployment: delete it once |

---

## 6. Exercise

1. Add a third check to the analysis: the new version's error rate may not exceed the
   stable version's by more than a point (`podTemplateHashValue: Stable` as a second arg).
2. Release user-service as a canary too: move it to the chart (gitops docs/HELM.md, "Exercise"), give
   it a VirtualService route `primary`, and compare a release's analysis with order-service's.
3. Give a tester the canary on demand: a `setHeaderRoute` step sending requests with
   `X-Canary: 1` to the new version before any weight moves.
4. Try the Gateway API plugin in a scratch cluster: an HTTPRoute attached to the Service
   instead of the VirtualService, the plugin pinned by checksum for your CPU; compare.
