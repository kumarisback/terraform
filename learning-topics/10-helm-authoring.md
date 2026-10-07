# Topic 10 — Writing Our Own Helm Chart

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

This is roadmap step `06-helm-authoring` (`LEARNING-ROADMAP.md` §06), mostly in `gitops`
(`charts/`, the order-service Applications, the lab sync and CI) with two pieces here in `tf`
(an ECR repository for charts, IMDSv2 on Jenkins). The user-facing guide is `gitops/docs/HELM.md`.

---

## 1. The concept

- **Kustomize patches YAML; Helm fills in templates.** Kustomize keeps real manifests and
  overlays changes on top — no logic, easy to read. Helm writes templates once
  (`{{ .Values.image.tag }}`) and renders them with a values file per environment —
  reusable, versioned, testable, and easy to over-engineer.
- **A chart** is `Chart.yaml` (name, *chart* version), `values.yaml` (every setting with its
  default — this is the chart's API, so design it like one), `templates/`, and optionally a
  `values.schema.json` that rejects bad values at render time.
- **Library charts** render nothing; they hold helpers (`define`/`include`) that other charts
  depend on. Dependencies are declared in `Chart.yaml`, pinned in `Chart.lock`, and fetched with
  `helm dependency build`.
- **Charts are artifacts.** `helm package` makes a versioned `.tgz`; OCI registries (ECR) store
  them like images. With immutable tags a chart version means one set of contents forever.
- **ArgoCD renders charts itself** (`helm template`) and applies the result, so there's no Helm
  release (and no `helm rollback`) in a GitOps cluster — rollback is `git revert`.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `gitops/charts/common` | Library chart: `common.name`, `common.labels` (the `app.kubernetes.io/*` set + `app`), `common.selectorLabels` (`app` only) |
| `gitops/charts/microservice` | Deployment, Service, ServiceAccount, HPA, PDB, VPA, ServiceMonitor — each switchable; probes and metrics under `contextPath`; OpenTelemetry and request-logging env; schema; 17 unit tests |
| `gitops/apps/<env>/order-service.values.yaml` | Only what differs per environment: image tag (commit SHA), environment name, payload logging, lab replicas |
| `gitops/bootstrap/projects/order-service-<env>.yaml` | ArgoCD Application: `path: charts/microservice` + the env's values file; follows the root's revision |
| `gitops/scripts/lib/addon_releases.rb`, `sync-local-stack.rb`, `validate.sh` | Treat a repo path with a `Chart.yaml` as a Helm release: dependency build, lint with every env's values, unit tests, render + schema check |
| `gitops/scripts/publish-chart.sh`, `Jenkinsfile` | On main: package, push to `oci://<ECR>/charts/microservice`; refuse changed contents under an existing version |
| `tf/infrastructure/shared-services` | ECR repository `charts/microservice` (immutable) |
| `tf/modules/jenkins` | `metadata_options`: IMDSv2 required, hop limit 1 (§3.4) |

Only order-service moved; frontend and user-service stay on Kustomize so both can be compared.

---

## 3. Real incidents

### 3.1 A Deployment's selector can't change

The Kustomize Deployment selected pods by `app: order-service`. Charts usually select on
`app.kubernetes.io/name` + `instance` — but `spec.selector` is immutable, so ArgoCD couldn't
have updated the running Deployment; it would have had to delete and recreate it. The library's
`selectorLabels` is therefore `app` alone, and the richer labels go on metadata only.

### 3.2 The lab would have installed the service before its CRDs

The lab sync installs Helm releases in alphabetical order: `order-service` came before
`vertical-pod-autoscaler`, whose CRD the chart's VPA needs. Repo charts now install after every
add-on.

### 3.3 Helm won't adopt what kubectl created

An existing lab's order-service objects were created by `kubectl apply`; `helm upgrade --install`
refuses them ("invalid ownership metadata"). The lab sync passes `--take-ownership` (Helm
3.17+) for repo charts. Two objects the chart names differently (`order-hpa`,
`order-service-monitor`) still need deleting once — two HPAs on one Deployment fight.

### 3.4 Publishing almost exposed the Jenkins role to every container

The first design let Helm, inside the CI container, log in to ECR with the instance role, which
needed IMDS hop limit 2. A security review caught what that means: *every* container on the
host, including `docker build` steps running a repository's Dockerfile, could read the role's
credentials — and that role can create IAM roles. Hop limit stays 1 (IMDSv2 required); the
publish stage runs on the host, fetches a 12-hour ECR-only token, and pipes it into the
container's `helm registry login`. Lesson: hand containers the narrowest credential, never the
host's role.

---

## 4. Verify — the full sequence

```bash
cd gitops
helm dependency build charts/microservice
helm lint charts/microservice -f apps/dev/order-service.values.yaml
helm unittest charts/microservice                   # 17 tests
helm template order-service charts/microservice -n development -f apps/dev/order-service.values.yaml | less

# The schema at work: a typo in the tag fails at render time
helm template x charts/microservice -f apps/dev/order-service.values.yaml --set image.tag=latst

# On dev after the sync: order-service is its own ArgoCD app
kubectl get applications -n argocd order-service
kubectl get deploy,hpa,pdb,vpa,servicemonitor -n development -l app=order-service

# After merge: the chart in ECR
helm show chart oci://602367507570.dkr.ecr.us-east-1.amazonaws.com/charts/microservice --version 0.1.0
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| `values don't meet the specifications of the schema` | a value the schema rejects — the message names the key |
| ArgoCD `order-service` app: `found in Chart.yaml, but missing in charts/ directory` | the `common` dependency couldn't be built: `charts/common` path or `Chart.lock` out of date (`helm dependency update`) |
| Lab: `invalid ownership metadata` | Helm older than 3.17 (no `--take-ownership`) |
| Two HPAs for order-service | the old `order-hpa` wasn't deleted (lab, §3.3) |
| Publish fails: `already published with different contents` | the chart changed without a `version` bump in `Chart.yaml` |

---

## 6. Exercise

1. Move user-service to the chart (its own values file: `image.repository`, `contextPath: /api`,
   the ALB health-check path, `ORDER_SERVICE_URL` in `extraEnv`). Then frontend: it isn't
   Spring, so decide which values the chart needs to grow — and which belong in a second chart.
2. Bump the chart to 0.2.0 with one new value, publish it, and install it from ECR into a scratch
   namespace with `helm install ... oci://...`; then `helm rollback` it.
3. Read `helm template` output for prod and compare it line by line with what Kustomize produced
   before (`git show <commit>:apps/base/order-service/deployment.yaml`).
