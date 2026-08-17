# Topic 02 — ArgoCD App-of-Apps & Environment Isolation, Step by Step

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → manual
walkthrough → GitOps/Terraform walkthrough → real incident → troubleshooting → exercise.

This one exists because of a real, previously-unnoticed bug in this repo: every environment's
ArgoCD was deploying **all three** environments' full app sets into whichever single cluster
installed it first — a subtle App-of-Apps mistake that's easy to make and easy to miss,
because everything *looks* correctly configured at a glance.

---

## 1. The concept

**App-of-Apps** is a pattern, not an ArgoCD feature — it's just: one ArgoCD `Application`
(the "root") whose source is a directory of *other* `Application` manifests, instead of raw
Kubernetes YAML. ArgoCD doesn't care that what it's syncing happens to be more Applications;
it applies them like any other resource. Once applied, each of those child Applications is
independently reconciled by ArgoCD the normal way — including reconciling and syncing *their*
own source paths.

**Why use it:** one thing to point at (the root), which then fans out to as many
environments/teams/services as you need, each independently manageable, all still declared
in git.

**The critical detail that's easy to miss:** `spec.destination.server` on an `Application`
is *not* a hostname you configure per-target — `https://kubernetes.default.svc` is a fixed,
special alias meaning **"whichever cluster ArgoCD itself is running in."** It is not a
placeholder for "the dev cluster" or "the staging cluster" — it always means *this* cluster,
full stop. If you deploy the same root Application (with the same static source path) into
three different clusters, expecting each to pick up "its own" child Applications by some kind
of environment matching — **nothing does that matching for you.** Every one of those three
clusters syncs the exact same source tree and deploys the exact same set of child
Applications, because `https://kubernetes.default.svc` resolves identically on all three.

---

## 2. Prerequisites checklist

Before wiring up an App-of-Apps across multiple environments/clusters, decide explicitly:

- [ ] **Is one ArgoCD instance managing multiple remote clusters, or is there one ArgoCD per
  cluster?** These need entirely different `destination.server` strategies (see §3).
- [ ] **What should be shared across every environment, and what's environment-specific?**
  (In this repo: `platform/` — cluster add-ons like External Secrets — is shared; `apps/dev`,
  `apps/staging`, `apps/prod` are not.)
- [ ] **Does every child Application need cascade-delete?** If an Application manages real
  cloud resources (a `type: LoadBalancer` Service, an `Ingress` backed by a real ALB), it
  needs `finalizers: [resources-finalizer.argocd.argoproj.io]` on itself — see §5.

---

## 3. Manual walkthrough — two valid patterns, and why the wrong pairing breaks

There are two legitimate ways to run App-of-Apps across multiple environments. The bug in
this repo was mixing up which one it was doing.

**Pattern A — one ArgoCD instance, multiple remote clusters.** A single central ArgoCD
manages dev/staging/prod, each running in its *own* separate cluster, by registering each as
a named cluster (`argocd cluster add <context>`) and giving each child Application a
*different, explicit* `destination.server` (the target cluster's real API server URL, not the
`kubernetes.default.svc` alias) or `destination.name` (a registered cluster nickname). Root
Application's source stays a single shared directory; each child inside it targets a
different real cluster.

**Pattern B — one ArgoCD instance per cluster, each self-contained (this repo's design).**
Every environment gets its *own* completely separate ArgoCD install, each only ever managing
the cluster it lives in. There is no cross-cluster registration at all. Every
`destination.server` is `https://kubernetes.default.svc` — correctly, because from each
ArgoCD's own point of view, "this cluster" *is* the one cluster it's supposed to manage.

**The bug was Pattern B's ArgoCD instances all pointing their root Application at the exact
same static source path** — which is a Pattern-A-shaped setup (one shared list of children)
grafted onto Pattern-B's deployment model (separate ArgoCD per cluster, no cross-cluster
awareness). Each self-contained ArgoCD faithfully deployed *everything* in that shared path,
because nothing told it to filter down to "just my environment."

**To do Pattern B correctly by hand:** each cluster's root Application source path must be
*specific to that cluster* — either a different git path per cluster (this repo's fix), or a
different git branch/tag per cluster, or a separate repo per environment entirely. The
common thread: **the root Application's source must already be scoped to one environment
before ArgoCD ever reads it** — you can't rely on `destination.server` to do that filtering
in a same-cluster, in-cluster-alias setup, because it's the same value everywhere.

---

## 4. This repo's actual implementation

**Before the fix**, every environment's Terraform-installed ArgoCD created a root Application
identically:
```hcl
# infrastructure/app-cluster/02-services/main.tf
resource "helm_release" "argocd_root_app" {
  values = [yamlencode({
    applications = {
      root-app = {
        source = {
          path = tostring(var.argocd_gitops_repo_path)  # SAME value for every environment
        }
        destination = {
          server = "https://kubernetes.default.svc"      # always "this cluster"
        }
      }
    }
  })]
}
```
And every environment's tfvars set the *same* value:
```hcl
# dev.tfvars, staging.tfvars, prod.tfvars — all identical
argocd_gitops_repo_path = "bootstrap/projects"
```
`bootstrap/projects/` contained `dev.yaml`, `staging.yaml`, `prod.yaml`, and `platform.yaml`
— all four, together, always. So dev's ArgoCD deployed all four. So did staging's. So did
prod's, if ever applied.

**After the fix**, each environment gets its own entry-point directory:
```
gitops/bootstrap/
  envs/
    dev/kustomization.yaml       # -> ../../projects/platform.yaml, ../../projects/dev.yaml
    staging/kustomization.yaml   # -> ../../projects/platform.yaml, ../../projects/staging.yaml
    prod/kustomization.yaml      # -> ../../projects/platform.yaml, ../../projects/prod.yaml
  projects/
    dev.yaml       # Application: dev-env,     path: apps/dev,     ns: development
    staging.yaml   # Application: staging-env, path: apps/staging, ns: staging
    prod.yaml      # Application: prod-env,    path: apps/prod,    ns: production
    platform.yaml  # Application: platform,    path: platform,     ns: kube-system
```
And each environment's tfvars now sets a *different* path:
```hcl
# dev.tfvars
argocd_gitops_repo_path = "bootstrap/envs/dev"
# staging.tfvars
argocd_gitops_repo_path = "bootstrap/envs/staging"
# prod.tfvars
argocd_gitops_repo_path = "bootstrap/envs/prod"
```
Now dev's root Application only ever reads `bootstrap/envs/dev/kustomization.yaml`, which
only ever references `dev.yaml` + `platform.yaml`. `staging.yaml` and `prod.yaml` are never
part of dev's source tree at all — not filtered out at sync time, just never referenced in
the first place. That's the actual fix: scope the *source*, don't try to filter after the
fact.

---

## 5. The finalizer detail this bug exposed

Every child Application (`dev.yaml`, `staging.yaml`, `prod.yaml`, `platform.yaml`) got
`finalizers: [resources-finalizer.argocd.argoproj.io]` added to itself, in addition to
root-app already having one. Here's why that's not redundant.

**Case that already worked:** deleting `root-app` entirely (a full `terraform destroy`).
`root-app`'s own finalizer cascades through the whole nested tree — deleting root-app deletes
its managed child Applications, and (per ArgoCD's own nested-Application handling) that
cascades further down to *their* managed resources too. This already worked correctly before
this fix, which is why the original destroy-bug fix (finalizer on root-app alone) was
sufficient for that specific scenario.

**Case that didn't work without this addition:** migrating an *already-running* cluster onto
this fix by re-applying Layer 2 with the new, narrower source path. Root-app's `prune: true`
now sees `staging-env` and `platform.yaml`'s Application... no wait — sees `staging-env` and
`prod-env` are no longer in its source tree, and prunes (deletes) *just those two* Application
objects — a partial deletion, not a full-tree delete. Without their own finalizers, deleting
those two Application objects directly would leave everything *they* were managing (their
namespaces, Deployments, Services, and any Ingress/ALB) orphaned, with no controller left
watching to clean them up. Adding the finalizer to the child Applications themselves makes
this partial-prune case behave the same safe way as the full-tree-delete case always did.

**The general lesson:** any Application that manages real cloud-provisioned resources (a
`LoadBalancer` Service, an `Ingress`-backed ALB, an RDS instance via a Crossplane-style
operator, anything AWS keeps billing for after the Kubernetes object is gone) needs its own
finalizer — not just the root of whatever tree it happens to sit in. Don't assume the parent's
finalizer covers every deletion path; it only covers *that specific* deletion path (deleting
the parent). Any other way that Application could get deleted — pruning, a manual
`kubectl delete`, an `ApplicationSet` generator no longer producing it — needs the same
protection on the resource itself.

---

## 6. Troubleshooting checklist

If you suspect an App-of-Apps setup is deploying more (or less, or the wrong thing) than
intended:

1. **List every Application and where its resources actually landed.**
   `kubectl get applications -n argocd -o wide` — check `DESTINATION NAMESPACE` and, if
   multi-cluster, `DESTINATION SERVER` for each. If two environments' Applications both show
   the *same* destination server, they're being reconciled by the *same* ArgoCD instance —
   ask whether that's actually intended (Pattern A) or a mistake (this repo's bug, Pattern B
   done wrong).
2. **Check what's actually in the synced source path**, not what you *think* is there:
   `argocd app manifests <app-name>` or just read the git path ArgoCD reports in
   `spec.source.path` directly. If a root Application's path is a shared directory, list
   everything in it — every file there is something every consumer of that path is deploying.
3. **For orphan-resource suspicions**, check finalizers before assuming cascade delete will
   work: `kubectl get application <name> -n argocd -o jsonpath='{.metadata.finalizers}'`. An
   empty result means deleting that Application will **not** clean up what it manages.
4. **After a source-path change** (like this fix), watch `prune` do its work once:
   `kubectl get applications -n argocd -w` — you should see the now-unreferenced
   Applications transition to being deleted, and (if they have finalizers) their own
   resources disappearing shortly after, not immediately vanishing while orphans remain.

---

## 7. Exercise — reproduce the bug, then fix it, yourself

1. In a scratch cluster, install ArgoCD and create a root Application pointed at a directory
   containing two child Application manifests — pretend they're "dev" and "staging," each
   deploying a trivial `nginx` Deployment into a different namespace, both with
   `destination.server: https://kubernetes.default.svc`.
2. Confirm both namespaces get created and both nginx Deployments come up — in the *same*
   cluster, from one root Application, exactly as this repo's bug did.
3. Now fix it the way this repo did: split the source into two directories, one containing
   only the "dev" child (plus anything shared), point this cluster's root Application at just
   that directory.
4. Watch `kubectl get applications -n argocd -w` as you re-apply — confirm the "staging"
   Application gets pruned, and (if you added a finalizer to it) its namespace/Deployment
   actually disappear rather than being left behind.
5. Now do it without the finalizer on the child, and watch the difference: the Application
   object disappears, but the namespace/Deployment it created do not. That's the orphan case
   §5 describes — reproduce it once so you believe it, then add the finalizer back.

If you can explain, from memory, why `destination.server: https://kubernetes.default.svc`
being identical everywhere is *the* root cause — not "ArgoCD has a bug," not "the finalizer
was missing" (that was a second, related bug) — you've actually understood this one.
