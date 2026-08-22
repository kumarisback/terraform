# Topic 04 — Production-Grade Deployments: Probes, PDBs, Spreading, Shutdown, SecurityContext

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents (there were five) → verify → troubleshooting →
exercise.

This is roadmap step `02-production-workloads` (`LEARNING-ROADMAP.md` §02), worked end to
end across two repos: `gitops` (the Deployment specs) and the separate `Devops_k8_manually`
app repo (two Spring Boot services + a static frontend), which is what most of the real
incidents below came from — the manifest changes were the easy part; making them actually
correct against the real running apps was not.

---

## 1. The concept

Six independent hardening pieces, each answering a different question a real production
review would ask:

- **Probes** (`startupProbe`/`readinessProbe`/`livenessProbe`) — is it done booting? should it
  get traffic right now? is it broken enough to restart? Three different questions; conflating
  them is the single most common way this goes wrong (§3.2, §3.5 below).
- **Requests/limits** — CPU limits throttle (slow, doesn't crash); memory limits OOM-kill
  (hard death, no graceful handling possible). This repo already had reasonable values before
  this lesson.
- **`PodDisruptionBudget`** — caps how many replicas can be down during *voluntary*
  disruption (drain, upgrade). Says nothing about crashes/OOMKills, and — see §3.4 — says
  nothing about a plain `kubectl delete pod` either.
- **`topologySpreadConstraints`** — spread replicas across AZs so one zone's problem isn't the
  whole service's problem. Only meaningful because this cluster actually has 2 AZs
  (`tf/environments/app-cluster/dev.tfvars`, 2 private app subnets).
- **Graceful shutdown** (`preStop` + `terminationGracePeriodSeconds`) — the k8s side is only
  half of this; see §3.6, the incident that exposed the other half.
- **`securityContext`** — `runAsNonRoot`, `readOnlyRootFilesystem`, dropped capabilities,
  `allowPrivilegeEscalation: false`. See §3.1 for the incident this actually caused.

---

## 2. This repo's actual implementation

Three services, three real runtime profiles discovered by reading the app repo
(`https://github.com/kumarisback/Devops_k8_manually`), not assumed generically:

| Service | Runtime | Health path | Notes |
|---|---|---|---|
| `frontend` | `nginx:alpine`, static SPA | `GET /` (any path 200s via `try_files ... /index.html`) | No `USER` in Dockerfile → runs root by default |
| `order-service` | Spring Boot, `server.servlet.context-path=/api/orders` | `/api/orders/actuator/health/{liveness,readiness}` | Actuator base path nests under the context path |
| `user-service` | Spring Boot, `server.servlet.context-path=/api` | `/api/actuator/health/{liveness,readiness}` | Same pattern, different prefix |

**Probes**, `gitops/apps/base/*/deployment.yaml` — all three got `startupProbe` +
`readinessProbe` + `livenessProbe`. Final form for the Spring services, after the incident in
§3.2:
```yaml
startupProbe:
  httpGet:
    path: /api/orders/actuator/health/liveness   # NOT full aggregate health — see §3.2
    port: 8080
readinessProbe:
  httpGet:
    path: /api/orders/actuator/health/readiness
livenessProbe:
  httpGet:
    path: /api/orders/actuator/health/liveness
```

**`PodDisruptionBudget`** — new file per service (`poddisruptionbudget.yaml`), `minAvailable:
1`, wired into each service's `kustomization.yaml`.

**`topologySpreadConstraints`** — `maxSkew: 1`, `topologyKey: topology.kubernetes.io/zone`,
`whenUnsatisfiable: ScheduleAnyway` (soft — won't block scheduling if perfect balance briefly
isn't achievable).

**`securityContext`** — different per service because their images are genuinely different
(see §3.1 for why this couldn't be copy-pasted):
```yaml
# frontend — image has no USER line, nginx needs to bind privileged port 80
securityContext:
  runAsNonRoot: true
  runAsUser: 101      # nginx official image's known uid
  runAsGroup: 101
  fsGroup: 101
containers:
- securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
      add: ["NET_BIND_SERVICE"]   # the one exception nginx actually needs

# order-service / user-service — Dockerfile pins USER 1000:1000 (after §3.1's fix)
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
containers:
- securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
```
All three needed `emptyDir` volumes for whatever `readOnlyRootFilesystem` now forces out of
the image (`/tmp` for the JVM; `/var/cache/nginx` + `/var/run` + `/tmp` for nginx).

**Image pinning** — still incomplete. `frontend` has a per-environment override mechanism
(`apps/dev/kustomization.yaml`'s `images:` block) but it's set to `latest`; `order-service`/
`user-service` aren't in that list at all. Deliberately left open rather than invented — see
§3.3 for why `:latest` specifically became a problem during testing, not just a style nitpick.

---

## 3. Real incidents — five of them, in the order they were hit

### 3.1 `runAsNonRoot` rejected a container that actually was non-root

**Symptom:** `container has runAsNonRoot and image has non numeric user (nonroot). cannot
verify user is non-root`, on the freshly-recreated `order-service`/`user-service` pods.

**Root cause:** the original Dockerfile did `USER spring:spring` — a **name**, not a number.
`runAsNonRoot: true` without an explicit `runAsUser` requires kubelet to statically verify the
image's declared user is non-root, and it cannot resolve a symbolic name without actually
running the container. The image genuinely never ran as root — that wasn't the problem;
kubelet's static check just can't prove it from a name alone. (`frontend` never hit this
because it got an explicit `runAsUser: 101` from the start, since its image had no `USER` line
at all and needed one regardless.)

**Fix, in two layers:**
1. **App repo**, both Dockerfiles: `RUN addgroup -g 1000 -S spring && adduser -u 1000 -S spring
   -G spring` / `USER 1000:1000` — pin a real number instead of letting Alpine allocate
   whatever system UID happens to be next-available at build time (which is a second, subtler
   risk: that allocation isn't guaranteed stable across base-image bumps, even though it
   "worked" as a name before).
2. **This repo**: add `runAsUser: 1000` / `runAsGroup: 1000` to both deployments once the new
   image was pushed.

**To find a UID without touching the app repo at all** (the stopgap used before the Dockerfile
fix landed): run a throwaway pod with no securityContext override and let the image boot under
its own default user:
```bash
kubectl run uid-check --rm -it --restart=Never --image=<image> --command -- id
```

### 3.2 The startup probe reintroduced the exact anti-pattern the liveness probe avoided

**Symptom:** none yet, in production — caught by review before it caused one. The original
`startupProbe` pointed at the full aggregate `/actuator/health`, not a specific group.

**Root cause:** the full aggregate health includes the Mongo indicator. `livenessProbe` was
correctly scoped to `/health/liveness` (Mongo-independent) from the start, but `startupProbe`
checking the aggregate meant a **fresh pod trying to boot during a real Mongo outage would
never pass startup**, and after `failureThreshold` was exceeded, kubelet restarts it — a
restart-loop caused by a downstream dependency, on the startup gate instead of the liveness
gate. Functionally the same mistake the roadmap explicitly warns about for liveness, just
smuggled in through a different probe.

**Fix:** point `startupProbe` at `/health/liveness` too — it should only ever answer "has the
process itself come up," never "is everything it depends on healthy."

### 3.3 `:latest` made a real image change invisible to GitOps

**Symptom:** after pushing new app code (the graceful-shutdown properties, then the UID fix),
running pods kept the old behavior even though ArgoCD showed `Synced`.

**Root cause:** the image tag string in the manifest (`:latest`) never changed, so ArgoCD's
diff against git saw zero drift — there was nothing to sync, regardless of what new bits
`:latest` actually pointed to in ECR now. GitOps' core promise ("git is the source of truth for
what's running") silently breaks under a mutable tag: two different manual rollout-restarts
can each pull a different real image while git — and ArgoCD's own status — shows no change at
all.

**Fix (per-incident, not structural):** `kubectl rollout restart deployment/<name> -n
development` after every push, to force new pods to actually re-pull. `imagePullPolicy`
defaults to `Always` for a `:latest` tag, so the re-pull does fetch fresh bits — it's the
*trigger* that's missing, not the pull behavior itself. The structural fix (real version
tags/digests) is still open — see §2's image-pinning note.

### 3.4 Draining a node evicted ArgoCD's own control plane, on a cluster too small to absorb it

**Symptom:** after running the roadmap's own drain test, `argocd-application-controller` /
`server` / `dex-server` went `Pending`, `Ready: false`.

**Root cause:** `kubectl drain` cordons the node (blocks *new* scheduling — the node itself
stays a live cluster member, kubelet keeps running) and evicts everything already on it except
DaemonSets. ArgoCD's own components are Deployments, so they were evicted along with app pods,
and their replacements needed somewhere else to land. On a small dev node group (this one),
one drained node can be a large fraction of total capacity — and the node was never
uncordoned, so it stayed permanently excluded from scheduling while everything competed for
whatever was left on the other node(s).

**Fix:** `kubectl uncordon <node-name>` — once capacity is back, the scheduler places every
`Pending` pod on its own, no other action needed. The general lesson: drain is genuinely safe
*if* there's slack elsewhere to absorb it, and a cost-conscious dev cluster deliberately has
none — that's an appropriate tradeoff for dev, not a bug, but it means drain tests need a
capacity gut-check first and an uncordon immediately after, every time.

### 3.5 Readiness doesn't check what you'd assume it checks, by default

**Symptom:** intentionally broke `MONGO_URI` to test "readiness fails, no restart" — but the
pod never left the Service's `Endpoints`, and stayed fully `Ready` throughout.

**Root cause:** a real misunderstanding, corrected mid-lesson. Spring Boot's built-in
`readiness` and `liveness` health groups are deliberately minimal by default — `liveness` only
reflects the app's own internal liveness state, and **`readiness` only reflects the app's own
startup/shutdown lifecycle, not any other health indicator**. Neither one automatically
includes Mongo (or any other dependency) unless explicitly configured to. The assumption that
"readiness naturally reflects DB health" is a common but incorrect one — with the stock config,
a real Mongo outage produces request-level errors and a `DOWN` full `/actuator/health`, but the
k8s-facing `/health/readiness` endpoint stays `UP` throughout, and the pod keeps receiving
traffic it can't actually serve correctly.

**Fix:** explicitly include the Mongo contributor in the readiness group —
```properties
management.endpoint.health.group.readiness.include=readinessState,mongo
```
in both Spring services' `application.properties`. (The contributor id is `mongo`, not
`mongodb` — verified against the actual running app's `/actuator/health` JSON output rather
than assumed, given the mistake above.) Only after this does a real DB outage actually pull the
pod out of rotation the way the original test intended.

### 3.6 Graceful shutdown is two halves, and only one lives in this repo

**Symptom:** `preStop` + `terminationGracePeriodSeconds` were added, but in-flight requests
still got dropped on pod termination.

**Root cause:** Spring Boot's default shutdown mode is immediate, not graceful — `SIGTERM`
kills the embedded Tomcat right away regardless of what grace period Kubernetes gives it. The
k8s-side settings (`preStop` sleep to cover LB-deregistration propagation delay, and a
`terminationGracePeriodSeconds` long enough to cover it) only create the *time window* for a
graceful drain — they don't make the app actually use it.

**Fix, app repo, both services' `application.properties`:**
```properties
server.shutdown=graceful
spring.lifecycle.timeout-per-shutdown-phase=20s
```
**Verification that this specific fix landed** (more convincing than checking the property
file, since it proves the *behavior*, not just the config): watch pod logs during a delete and
look for the log line Spring Boot only emits when graceful shutdown is actually active:
```
Commencing graceful shutdown. Waiting for active requests to complete
Graceful shutdown complete
```

---

## 4. Verify — the full sequence

```bash
# Pods stable, not crash-looping
kubectl get pods -n development -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" restarts="}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

# Actually running the new build, not a stale cached layer
kubectl get pods -n development -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].imageID}{"\n"}{end}'

# Probes green
kubectl get events -n development --field-selector reason=Unhealthy
kubectl describe pod -n development -l app=order-service | grep -A3 "Liveness\|Readiness\|Startup"

# PDB real
kubectl get pdb -n development

# Actually spread across zones
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -n development -o wide -l app=order-service

# Graceful shutdown, proven via the log line in §3.6
POD=$(kubectl get pods -n development -l app=order-service -o jsonpath='{.items[0].metadata.name}')
kubectl logs -f "$POD" -n development &
kubectl delete pod "$POD" -n development

# Readiness-vs-liveness under a real dependency outage (after §3.5's fix is applied)
aws secretsmanager update-secret --secret-id microservices/dev/app-config --region us-east-1 \
  --secret-string '<MONGO_URI pointed at something unreachable>'
kubectl annotate externalsecret app-secrets -n development force-sync="$(date +%s)" --overwrite
kubectl rollout restart deployment/order-service -n development
kubectl get endpoints order-service -n development -w    # expect: pod drops out
kubectl get pods -n development -l app=order-service -w  # expect: restarts stay at 0
# then restore the real secret value and force-sync + rollout restart again

# Real disruption test
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --timeout=120s
kubectl uncordon <node-name>   # always, immediately after
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause | Where |
|---|---|---|
| `cannot verify user is non-root` | Image's `USER` is a name, not a number, and no `runAsUser` override | §3.1 |
| Pod restart-loops only during a dependency outage, even though liveness looks Mongo-independent | Check `startupProbe` too — it needs the same scoping as liveness | §3.2 |
| New image behavior not showing up despite a successful push | Tag unchanged (`:latest`) → ArgoCD sees no diff → force a `rollout restart` | §3.3 |
| ArgoCD's own pods (or anything else) stuck `Pending` after a drain test | Node never uncordoned, or cluster had no spare capacity to absorb the drain | §3.4 |
| Readiness stays `UP` during a real dependency outage | Default readiness group doesn't include that dependency — must be added explicitly | §3.5 |
| In-flight requests dropped on pod termination despite `preStop`/grace period | App-side graceful shutdown not enabled — k8s side alone isn't sufficient | §3.6 |

---

## 6. Exercise — close the loop on what's still open

1. Apply §3.5's fix (`management.endpoint.health.group.readiness.include=readinessState,mongo`)
   to both Spring services, and re-run the full Mongo-outage test from §4. Confirm the pod
   *actually* leaves `Endpoints` this time — don't just trust the config, watch it happen.
2. Pick real version tags (or digests) from `aws ecr describe-images` for all three services,
   add `order-service`/`user-service` to `apps/dev/kustomization.yaml`'s `images:` block
   (currently only `frontend` is listed), and replace `latest` everywhere. Re-verify that a
   tag *change* (not a same-tag repush) is what actually makes ArgoCD show `OutOfSync` and
   trigger a real sync — that's the behavior §3.3 showed was missing with `:latest`.
3. Bonus, harder: decide whether `startupProbe`'s current `failureThreshold`/`periodSeconds`
   window is actually long enough for a cold JVM boot under load, by deliberately constraining
   CPU (temporarily lower the `limits.cpu`) and watching whether startup still completes in
   time — probe timing tuned against an assumption, not measured, is its own common mistake.
