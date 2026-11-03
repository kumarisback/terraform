# Topic 16 — Kong: an API gateway, and the Gateway API

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `16-kong-gateway`. All in gitops (`platform/gateway-api`, `platform/kong`, the
`kong` add-on, `apps/base/routes.yaml`); in this repo only references to the edge's new
Ingress (READMEs, tfvars comments). The user guide is `gitops/docs/KONG.md`.

---

## 1. The concept

- **Ingress controller versus API gateway.** An ingress controller gets HTTP into the
  cluster and picks a Service by host and path. An API gateway works on each request as an
  API call: who is calling (keys, JWT), how often (rate limits, quotas), what it looks like
  (rewrites, headers), which version, and what it cost (per-route metrics). Many products do
  both; the jobs are different.
- **North-south and east-west.** Traffic entering from outside (north-south) goes through
  the edge and the gateway; traffic between services (east-west) is the service mesh's
  concern (step 18).
- **Declarative, database-less.** Kong can store its configuration in PostgreSQL and take
  changes through an admin API, or run DB-less from one declarative document. With a
  controller translating Kubernetes resources into that document, Git is the only source of
  truth.
- **The Gateway API** splits a load balancer into roles: `GatewayClass` (which
  implementation, cluster admin), `Gateway` (listeners and who may attach, platform team),
  `HTTPRoute` (paths to Services, application team). Matching is specified (longest path
  wins), filters are standard (rewrite, headers, mirror, weights), routes report their status,
  and the same routes work with any implementation.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `platform/gateway-api` | The v1.3.0 standard-channel release file, unchanged, pinned by SHA-256 (the version KIC 3.5 is built against); never pruned, no finalizer |
| gitops `addons/applications/kong.yaml`, `addons/values/*/kong.yaml` | Kong's `ingress` chart 0.24.0: Kong 3.9.4 (open source) DB-less, KIC 3.5.13; proxy `ClusterIP`; the edge's Ingress (ALB in the cloud with `group.name: microservices` and health checks on `/status/ready`, Traefik in the lab); 2 replicas across zones in the cloud; `X-Forwarded-For` trusted from private ranges only; Kong Manager off |
| gitops `platform/kong` | Unmanaged `GatewayClass` and the `Gateway` (HTTP :80, routes only from the app namespaces); global `prometheus` plugin; NetworkPolicy: admin API only from the controller |
| gitops `apps/base/routes.yaml` | `HTTPRoute`s for frontend `/`, user-service `/api`, order-service `/api/orders` and `/api/v1/orders` (URLRewrite) |
| gitops `observability/base` | `KongGatewayUnavailable`, `KongConfigurationPushFailing`, `KongResourcesRejected` (tested); the Kong gateway dashboard |
| gitops Alloy | Kong's NGINX access lines as `log_type="gateway"`, query-string secrets masked (tested) |
| gitops `scripts/validate.sh` | Renders and schema-checks all of it; new: no cluster-scoped object may carry a namespace |
| this repo | The edge Ingress is now `kong-gateway-proxy` in namespace `kong` (READMEs, tfvars comments, the canary variable) |

---

## 3. Real incidents

None of these happened on a cluster; all were found reading the rendered output before
committing, except 3.3, which a check found in code already pushed.

### 3.1 The gateway's master key on the cluster network

Kong's admin API, in DB-less mode, takes `POST /config`: one request replaces the whole
configuration, and with it where every user's request goes. The chart serves it over TLS but
doesn't verify callers, on a Service every pod can reach. Separately, the chart publishes Kong
Manager (the admin GUI) as a **NodePort**, on every node, and Kong keeps listening for it on
8002 even when the Service is switched off. Now: Manager off and `admin_gui_listen: off`, and a
NetworkPolicy lets only the controller's pods reach port 8444. Lesson: read what a chart
renders, not just its values.

### 3.2 Certificates that would change on every sync

The chart can make the admin API require client certificates (mutual TLS), generating them with
Helm's `genCA` and keeping them stable with `lookup`, which reads the existing Secret from the
cluster. ArgoCD renders charts without cluster access, so `lookup` finds nothing and every sync
would mint a new CA: the controller and the gateways would disagree until restarted. mTLS waits
for cert-manager (step 03's remainder); the NetworkPolicy is the protection until then.

### 3.3 A namespace on an object that has none

`platform/kong` first used a Kustomize `namespace:` for the Gateway. Kustomize only knows which
*built-in* kinds are cluster-scoped; it stamped `namespace: kong` on the GatewayClass and the
KongClusterPlugin too. Looking for the same mistake elsewhere found it already pushed: step 15's
`ClusterTriggerAuthentication` carried `namespace: keda`. Schemas don't catch this, so
`validate.sh` now collects every cluster-scoped kind (built-ins plus every rendered CRD with
`scope: Cluster`) and fails on any such object with a namespace. Both directories now set the
namespace on their namespaced objects only.

### 3.4 An editing script that ate backslashes

Adding Kong's log rule to Alloy's configuration with a Ruby `String#sub` broke the existing
Traefik rule next to it: in a replacement *string*, `sub` treats backslashes as escapes, so
`\\\"` became `\"`. `alloy validate` (run by `validate.sh`) refused the configuration at once.
Replacements are now passed as blocks (no escape processing), and it explains topic 14's JSON
pattern too. Lesson: validate generated configuration with the tool that will read it.

### 3.5 A controller that starts before its CRDs

The lab installs charts before applying Git directories, so KIC starts before the Gateway API
CRDs exist. Checked in KIC's source before relying on it: its `DynamicCRDController` watches for
the CRDs and starts the Gateway controllers when they appear, so no restart or ordering is
needed.

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh        # Gateway API CRDs, Kong in every env, routes against the CRDs, scope check, alerts, Alloy cases

# Lab or dev
kubectl get gatewayclass kong -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'   # True
kubectl get gateway kong -n kong                          # PROGRAMMED True
kubectl get httproute -n development -o custom-columns=NAME:.metadata.name,ACCEPTED:.status.parents[0].conditions[0].status
curl -sI localhost/api/orders/status | grep -i '^via'     # lab: through Traefik and Kong
kubectl get ingress kong-gateway-proxy -n kong            # cloud: the ALB's address
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| everything 404 through the edge | no route attached: `kubectl describe httproute` (`Accepted: False`: the Gateway's `allowedRoutes` refuses the namespace) |
| one path 503 | its route's backend Service or port is wrong (`ResolvedRefs: False`), or the Service has no ready pods |
| ALB targets unhealthy | the health check: Kong's `/status/ready` on 8100 is false until the controller has pushed a configuration |
| route changes don't take effect | `KongConfigurationPushFailing`: Kong refuses the new configuration and keeps the old |
| client IPs in Kong's log are the ALB's | the ALB's address isn't in `trusted_ips` (private ranges) |
| `kubectl apply` of the CRDs: annotation too long | use server-side apply (ArgoCD does); the largest, HTTPRoute, fits client-side today |

---

## 6. Exercise

1. Replace the routes with the Ingress in `docs/KONG.md` (`ingressClassName: kong`) and compare
   what each reports when a Service is missing.
2. Put AWS API Gateway (HTTP API, VPC link) in front of the same services in a scratch
   environment. What does it cost per million requests, and what would you lose compared with
   Kong (plugins, configuration in Git)?
3. Issue the admin API's certificates with cert-manager and turn on mutual TLS between the
   controller and the gateways; then decide whether the NetworkPolicy is still needed.
