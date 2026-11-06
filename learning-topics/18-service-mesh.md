# Topic 18 — Service mesh: Istio in ambient mode

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `18-service-mesh`. All in gitops (the Istio add-ons, `apps/base/mesh.yaml`,
`platform/mesh`); nothing in this repo or the app. The user guide is `gitops/docs/MESH.md`.

---

## 1. The concept

- **What a mesh adds that a gateway doesn't.** A gateway guards the way in (north-south). A
  mesh is between the services (east-west): every workload gets a cryptographic identity
  (a SPIFFE ID from its ServiceAccount), every connection is mutually authenticated and
  encrypted, and policies say which identity may call what. Retries, timeouts and request
  metrics come without code.
- **Sidecar versus ambient.** Sidecar meshes put a proxy in every pod: memory per pod,
  restarts to join, two proxies per hop. Istio's ambient mode uses a per-node proxy (ztunnel)
  for identity, mutual TLS and connection-level policy, and per-namespace waypoints (Envoy)
  only where HTTP-level features are needed.
- **Layer 4 and layer 7 policy.** ztunnel sees connections and the peer's identity: it can
  say who may connect. A waypoint sees requests: it can say who may call which method and path.
  Requests to a Service go through its waypoint; the destination's ztunnel then sees the
  waypoint as the caller.
- **Gateway and mesh together.** The common enterprise shape: a gateway at the edge for the
  outside world (Kong), a mesh inside, the gateway itself a member of the mesh so the
  services can name it in their policies.
- **Do you need one?** For a handful of services, rarely: the operational cost (another
  control plane, new failure modes) is real. Encryption in transit everywhere, identity-based
  policy and uniform telemetry are what justify it.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `addons/applications/{istio-base,istiod,istio-cni,ztunnel}.yaml` | Istio 1.31.3 from `blob.istio.io` (`profile: ambient`), every environment; istiod two replicas in the cloud; ztunnel sized down from the chart's 512 Mi |
| gitops `apps/*/namespace.yaml` | `istio.io/dataplane-mode: ambient`, `istio.io/use-waypoint: waypoint` |
| gitops `apps/base/mesh.yaml` | PeerAuthentication STRICT; Gateway `waypoint` (class `istio-waypoint`, HPA 2-4 and PDB; one in the lab); per-workload L4 policies (waypoint and Prometheus only); per-Service L7 policies (callers and paths); VirtualServices: 10 s timeout, 2 retries on `connect-failure,refused-stream,reset-before-request` |
| gitops `apps/local/mongodb.yaml` | ServiceAccount `mongodb-init`; MongoDB reachable only from the two services and the Job |
| gitops chart 0.7.0, `apps/base/*/service.yaml` | `ingress.kubernetes.io/service-upstream: "true"`, so Kong calls Services, through the waypoint |
| gitops values for kong, kube-prometheus-stack, blackbox-exporter | Their pods in the mesh (pod label); NetworkPolicies allow HBONE (15008) from Prometheus and ambient's probe address `169.254.7.127` |
| gitops `platform/mesh`, `observability/base/mesh-alerts.yaml` | PodMonitors for istiod, ztunnel, waypoints; `ZtunnelUnavailable`, `WaypointUnavailable`, `IstiodUnavailable`, tested |

---

## 3. Real incidents

All found while designing the step; none on a cluster yet.

### 3.1 Kong would have walked around the waypoint

The Kong Ingress Controller configures Kong with the *pod* addresses behind a Service, for its
own load balancing. Pod-addressed traffic doesn't go through the waypoint, so Kong's requests
would have skipped every HTTP-level policy and retry, and the pods' ztunnel (which allows only
the waypoint) would have refused them. The `service-upstream` annotation on each Service makes
Kong call the Service address; the chart sets it by default.

### 3.2 Strict mTLS would have blinded the monitoring

With the namespace refusing plain text, Prometheus's scrapes and the blackbox exporter's checks
(both outside the mesh) would have been refused: every service would have looked down. Both
joined the mesh with a pod label (ambient enrols single pods too), and the policies name their
identities.

### 3.3 NetworkPolicies meet HBONE

Between two meshed pods, traffic arrives on port 15008 (HBONE), not the application port, and
in ambient mode the kubelet's health checks come from the link-local address `169.254.7.127`.
The blackbox exporter's and Kong's NetworkPolicies allowed only application ports from
specific pods: once those pods were meshed, Prometheus's scrapes and the exporter's own health
checks would have been dropped. Both policies now allow 15008 from Prometheus, and the
exporter's allows the probe address on its port.

### 3.4 A retry that creates a second order

The obvious retry setting, `5xx`, would retry a `POST /api/orders` that timed out after the
order was saved: a duplicate order. The waypoint retries only failures where the request
certainly wasn't sent (`connect-failure`, `refused-stream`, `reset-before-request`); the rest
go back to the caller. Retries are an application-level decision dressed as infrastructure.

### 3.5 The chart repository moved

`istio-release.storage.googleapis.com/charts` lists stable charts only up to 1.30.7: 1.31
appears there only as pre-releases, and the OCI registry had none either. Istio's own install
guide now points at `blob.istio.io/istio-release/charts`, which has 1.31.3, the first 1.31 patch
without known CVEs (per Istio's support page). Checked in the project's documentation, not
guessed.

### 3.6 Namespaces in identities

A principal names the namespace (`cluster.local/ns/development/sa/user-service`), but
`apps/base` serves development, staging and production. Policies write callers in the same
namespace as `*/sa/user-service`. That matches any namespace's `user-service` account; it's
exact here only because each environment is its own cluster with one application namespace,
and only while nobody creates a ServiceAccount of that name elsewhere: 3.8 says how it is bound
to the namespace now.

### 3.7 Exercises that would have broken

The KEDA guide's load test ran a pod inside the application namespace and called order-service
directly. In the mesh that pod has an identity no policy names: 403. It now runs outside and
goes through Kong, as real traffic does.

### 3.8 What a review of the pushed mesh found

These shipped, and a security review of the commit caught them:

- **Prometheus could call the APIs.** The layer-4 rule let Prometheus's identity open
  connections to the pods on any port, the API's included, without passing the waypoint's
  rules. Restricting it to the metrics port wasn't possible: actuator shared port 8080 (and the
  `/api` path) with the API, which also meant the gateway exposed health and metrics to
  anyone. The services now serve actuator on `management.server.port` 8081 (tested in the
  app repo: 404 on the API port), and Prometheus may reach only 8081.
- **`*/sa/user-service` matched any namespace.** Callers in the app namespace now carry
  `namespaces: [development]` as well, which each overlay replaces with its own namespace (a
  Kustomize replacement on policies labelled `same-namespace-callers`); the lab's MongoDB
  policy names full principals.
- **The tunnel bypassed the NetworkPolicy.** Kong's NetworkPolicy allowed Prometheus on 15008,
  and inside that tunnel ztunnel delivers to any port, the admin API's included. An Istio
  `DENY` on the gateways refuses every mesh identity on port 8444. Lesson: with a mesh, a
  NetworkPolicy sees the tunnel, not the destination port; port rules for meshed traffic
  belong in the mesh's policies.

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh       # Istio in every env, mesh objects against Istio's CRDs, alert tests

# Lab or dev
kubectl get pods -n istio-system
kubectl get gateway waypoint -n development
kubectl run probe -n development --rm -it --image=busybox:1.37 --restart=Never -- \
  wget -qO- http://order-service/api/orders/status                       # 403 RBAC: access denied
kubectl exec -n development deploy/order-service -- wget -qO- http://user-service/api/auth/jwks.json   # allowed
curl -s localhost/api/orders/status                                      # through Kong and the waypoint: fine
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| everything through Kong fails, services healthy | waypoint down (`WaypointUnavailable`), or Kong's pods not in the mesh yet (they restart to join) |
| Prometheus shows services down, they aren't | Prometheus's pod not in the mesh (label missing) or its identity missing from the L4 policies |
| 403 `RBAC: access denied` | the caller or path isn't in the Service's `*-callers` policy |
| connection reset, no 403 | refused by ztunnel: caller not the waypoint or Prometheus, or not in the mesh |
| pods unready after joining the mesh | a NetworkPolicy blocks 15008 or ambient's probe address `169.254.7.127` |
| policies apply nowhere | istiod down, or the waypoint Gateway not Programmed (`kubectl describe gateway waypoint`) |

---

## 6. Exercise

1. Roll the mesh out the production way: `PERMISSIVE` first, confirm in the waypoint's metrics
   (`istio_requests_total{connection_security_policy="mutual_tls"}`) that everything is mutual
   TLS, then `STRICT`.
2. Install Linkerd (edge release) in a scratch KinD cluster with cert-manager issuing its
   trust anchor; mesh the same services and compare memory, setup steps and what its viz
   extension shows against Istio's metrics.
3. Deploy `order-service-v2` and split 90/10 between the versions with an HTTPRoute attached
   to the Service (Gateway API's mesh support), then hand that job to Argo Rollouts (step 20).
4. Turn on waypoint access logs (`meshConfig.accessLogFile`) and find a refused request in
   Loki by its source identity.
