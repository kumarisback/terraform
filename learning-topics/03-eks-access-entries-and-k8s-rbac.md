# Topic 03 — EKS Access Entries & Kubernetes RBAC, Step by Step

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → manual walkthrough → real incident → verify → troubleshooting →
exercise.

This is roadmap step `01-k8s-rbac` (`LEARNING-ROADMAP.md` §01), worked end to end: create an
IAM user with a deliberately irrelevant AWS permission (`ec2:Describe*`), map it into the
cluster's `sre` RBAC group via an EKS access entry, and prove that only the Kubernetes-side
RBAC — never the IAM policy — decides what that identity can do once it's inside the cluster.
Every snag below is a real one hit while running this test, not a hypothetical.

---

## 1. The concept

**Two separate, independent auth layers**, and this topic is entirely about not confusing them:

- **AWS IAM** decides who can reach the EKS API server at all (authentication). This is what
  `eks_admin_users` / an access entry controls.
- **Kubernetes RBAC** decides what an already-authenticated identity can do once inside
  (authorization) — `Role`/`ClusterRole` + `RoleBinding`/`ClusterRoleBinding`.

An IAM policy attached to a user/role (like `ec2:Describe*`) only ever governs calls to AWS
APIs directly. It has **zero** bearing on either layer above — not on whether you can reach
the cluster, not on what you can do inside it. That's the whole point of using it as the test
identity's policy: whatever access you end up with is provably not coming from IAM permissions.

**EKS Access Entries** are the bridge between the two layers. Each entry maps one IAM
principal ARN to a Kubernetes identity, in one of two ways:

| Entry type | What it grants | Where authorization happens |
|---|---|---|
| Access entry + AWS-managed access policy (`AmazonEKSClusterAdminPolicy`, `AmazonEKSViewPolicy`) | A fixed, AWS-defined permission set | Enforced by EKS itself — no in-cluster RBAC objects involved |
| Access entry + `kubernetes_groups` only, no access policy | Nothing on its own | 100% delegated to whatever `ClusterRole`/`RoleBinding` in the cluster binds that group name |

This repo's cluster runs `authentication_mode = "API_AND_CONFIG_MAP"`
(`tf/modules/eks/main.tf:138`), so access entries (the modern path) and the legacy `aws-auth`
ConfigMap approach are both technically live — this doc only covers access entries, which is
what the repo actually uses.

---

## 2. This repo's actual implementation

**Three access tiers**, all built on the same `aws_eks_access_entry` resource, in
`tf/modules/eks/main.tf`:

```hcl
# Tier 1 — full admin, AWS-managed policy (tf/modules/eks/main.tf:229-245)
resource "aws_eks_access_entry" "admins" { for_each = toset(var.admin_users) ... }
resource "aws_eks_access_policy_association" "admins" {
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  ...
}

# Tier 2 — read-only, AWS-managed policy (tf/modules/eks/main.tf:250-266)
resource "aws_eks_access_entry" "viewers" { for_each = toset(var.viewer_users) ... }
resource "aws_eks_access_policy_association" "viewers" {
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  ...
}

# Tier 3 — custom, no AWS-managed policy at all (tf/modules/eks/main.tf:275-281)
resource "aws_eks_access_entry" "group_mapped" {
  for_each          = var.group_mapped_users
  principal_arn     = each.key
  kubernetes_groups = each.value   # e.g. ["sre"]
}
```
Tier 3 deliberately has no matching `aws_eks_access_policy_association` — that absence is the
whole mechanism. EKS authenticates the principal and stamps their token with the group name;
everything past that point is ordinary Kubernetes RBAC.

**Wiring for this test** (`tf/environments/app-cluster/dev.tfvars:40-42`):
```hcl
eks_group_mapped_users = {
  "arn:aws:iam::602367507570:user/SRE_TEST" = ["sre"]
}
```

**What group `sre` can actually do**, in `gitops/platform/rbac/`, applied via ArgoCD's
`platform` Application (`bootstrap/projects/platform.yaml` → `platform/kustomization.yaml` →
`rbac/`), never `kubectl apply`:
- `sre-clusterrole.yaml` + `sre-clusterrolebinding.yaml`: cluster-wide `get/list/watch` on
  pods, logs, services, deployments, nodes, events — no writes, no Secrets.
- `sre-exec-role.yaml` + `sre-exec-rolebinding.yaml`: `pods/exec` + `pods/portforward`, but as
  a namespace-scoped `Role`/`RoleBinding` in `development` only — so `sre` can't exec into
  `kube-system`/`argocd` pods that hold real credentials.

`developer-readonly-clusterrole.yaml` + `-rolebinding.yaml` exist in the same folder but are
**not wired to any IAM principal yet** — see the Exercise below.

---

## 3. Manual walkthrough — wiring a brand-new principal by hand

Generalized version of what `dev.tfvars:40-42` does automatically on the next `terraform apply`:

1. Create the IAM identity and, if it needs programmatic access, a key:
   ```bash
   aws iam create-access-key --user-name <exact-case-username>
   ```
2. Create (or extend) the access entry, mapping it to a group name of your choosing:
   ```bash
   aws eks create-access-entry \
     --cluster-name <cluster> --region <region> \
     --principal-arn arn:aws:iam::<account>:user/<name> \
     --kubernetes-groups <group-name>
   ```
   (In this repo, Terraform does this — you'd only run it by hand for a one-off test outside
   the IaC flow.)
3. Write (or reuse) a `ClusterRole`/`Role` describing the permissions, and a
   `ClusterRoleBinding`/`RoleBinding` with `subjects: [{kind: Group, name: <group-name>}]`
   pointing at it. The group name in the binding must match the `kubernetes-groups` value from
   step 2 exactly — that string is the only thing connecting the two halves.
4. Apply the RBAC objects to the cluster (via GitOps here — never by hand in this repo).

---

## 4. Real incident — three snags hit testing SRE_TEST end to end

### 4.1 Laptop couldn't reach the cluster at all
**Symptom:** every `kubectl` command failed with `dial tcp <ip>: i/o timeout`.

**Root cause:** `dev.tfvars` had
```hcl
eks_endpoint_public_access = false
eks_public_access_cidrs    = []
```
— the dev EKS API endpoint was private-only, reachable from nowhere outside the VPC, not even
a permitted IP. This directly contradicts `tf/README.md`'s own description of dev
("its EKS API endpoint is public, restricted to the IP in `eks_public_access_cidrs`") — the
docs assumed a state the tfvars didn't actually have.

**Fix:** set `eks_endpoint_public_access = true` and `eks_public_access_cidrs =
["<your-ip>/32"]`, re-apply Layer 1 (`01-infra`) only — it's an in-place endpoint-config update,
not a cluster replace. (Alternative: tunnel through the Jenkins EC2 instance via SSM, the same
pattern already documented for staging/prod, since Jenkins already sits inside the VPC.)

### 4.2 Even cluster-admin couldn't impersonate
**Symptom:** `kubectl auth can-i --list --as-group=sre -n development` failed with a
"cannot impersonate resource ... in API group \"\" at the cluster scope" error — using the
`terraform` admin identity, which has `AmazonEKSClusterAdminPolicy`.

**Root cause:** broad object access and impersonation rights are two separate grants.
`AmazonEKSClusterAdminPolicy` doesn't include the RBAC `impersonate` verb on
`users`/`groups`/`serviceaccounts` (and `userextras`/`uids` in `authentication.k8s.io`) — so
`--as`/`--as-group` is blocked regardless of how much direct access the calling identity has.

**Fix / workaround:** skip impersonation entirely and authenticate as the real test identity
instead (§5) — strictly more convincing anyway, since it exercises the actual IAM → access-entry
→ RBAC chain rather than a proxy for just the RBAC half. (Impersonation *can* be enabled by
granting an explicit `impersonate` ClusterRole/ClusterRoleBinding if the shortcut is wanted for
future tests — see the command history for the exact manifest.)

### 4.3 "whoami" kept reporting the wrong identity
**Symptom:** after `aws configure --profile sre-test`, both `aws sts get-caller-identity` and
`kubectl auth whoami` still reported the `terraform` admin ARN — looking exactly like the RBAC
mapping wasn't working.

**Root cause:** neither command was told which profile to use, so both silently fell back to
whatever `AWS_PROFILE`/`default` already resolved to (`terraform`). This was a credential
*resolution* mistake, not an authorization failure — nothing about RBAC was actually being
tested yet.

**Fix:** `export AWS_PROFILE=sre-test` for the whole test session (not just one command), and
confirm `kubectl config current-context` is the context created via
`update-kubeconfig --alias sre-test-ctx` before trusting any output.

### 4.4 Local CLI profile name vs. actual IAM username
Minor but worth stating plainly: `--user-name SRE_TEST` in `aws iam create-access-key` must
match the real IAM username exactly (IAM names are case-sensitive). The `--profile sre-test`
label used afterward is a purely local nickname in `~/.aws/credentials` — AWS never sees it,
and it doesn't need to match the IAM username's case or spelling at all.

---

## 5. Verify — the full command sequence that ended up working

```bash
# 0. Sanity check as admin
AWS_PROFILE=terraform aws eks update-kubeconfig \
  --name microservices-dev-eks-cluster --region us-east-1
kubectl get nodes

# Confirm the access entry actually exists in AWS
aws eks describe-access-entry \
  --cluster-name microservices-dev-eks-cluster --region us-east-1 \
  --principal-arn arn:aws:iam::602367507570:user/SRE_TEST
# expect: "kubernetesGroups": ["sre"]

# 1. Build the test identity (once)
aws iam create-access-key --user-name SRE_TEST
aws configure --profile sre-test
aws sts get-caller-identity --profile sre-test

# 2. A kubeconfig context that authenticates as SRE_TEST
AWS_PROFILE=terraform aws eks update-kubeconfig \
  --name microservices-dev-eks-cluster --region us-east-1 --alias sre-test-ctx
kubectl config use-context sre-test-ctx

# 3. Confirm the switch actually took
export AWS_PROFILE=sre-test
aws sts get-caller-identity          # arn:...:user/SRE_TEST
kubectl auth whoami                  # same ARN, groups: ["sre"]

# 4. The access battery
POD=$(kubectl get pods -n development -o jsonpath='{.items[0].metadata.name}')

kubectl get pods -A                                   # WORKS  — sre ClusterRole, cluster-wide read
kubectl get nodes                                      # WORKS
kubectl logs "$POD" -n development                      # WORKS
kubectl exec -it "$POD" -n development -- sh            # WORKS  — sre-exec Role, development only
kubectl delete pod "$POD" -n development                # FORBIDDEN — no write verbs granted
kubectl get secrets -n development                       # FORBIDDEN — Secrets deliberately excluded
kubectl exec -it <pod> -n argocd -- sh                   # FORBIDDEN — exec is not cluster-wide
aws ec2 describe-instances --region us-east-1            # WORKS  — but proves nothing k8s-side
aws eks describe-cluster --name microservices-dev-eks-cluster --region us-east-1
                                                          # FORBIDDEN — SRE_TEST never got eks:DescribeCluster
```

---

## 6. Troubleshooting checklist

| Symptom | Likely cause | Where to look |
|---|---|---|
| `dial tcp ... i/o timeout` on any `kubectl`/`aws eks` call | Private-only endpoint, your IP isn't in `eks_public_access_cidrs` | §4.1 |
| `cannot impersonate resource "groups"...` | Current identity's access policy doesn't grant `impersonate` | §4.2 |
| `whoami`/`get-caller-identity` shows the wrong user | `AWS_PROFILE` not exported for that shell/command | §4.3 |
| Access entry exists but RBAC still denies everything | Group name in the access entry and the `RoleBinding`/`ClusterRoleBinding` subject don't match character-for-character | §2 |
| `AccessDenied` calling `aws eks describe-cluster`/`update-kubeconfig` as the test user | Expected — that call needs `eks:DescribeCluster`, which the group-mapped tier deliberately never grants | §5 |

---

## 7. Exercise — wire up `developer-readonly` yourself

`gitops/platform/rbac/developer-readonly-clusterrole.yaml` and
`developer-readonly-rolebinding.yaml` already exist but aren't mapped to any real IAM
principal — the comment in the rolebinding says so directly.

1. Create a second test IAM user (or reuse one), and add it to
   `eks_group_mapped_users` in `dev.tfvars` mapped to `["developer-readonly"]` instead of
   `["sre"]`.
2. Re-apply, then repeat the §5 sequence with this identity.
3. Confirm the permission surface is genuinely different from `sre`, not a copy-paste of it:
   - `kubectl get pods -n development` → works (both roles allow this)
   - `kubectl get nodes` → **forbidden** (`developer-readonly` has no cluster-wide rule at all —
     it's not bound via a `ClusterRoleBinding`, only a namespaced `RoleBinding`)
   - `kubectl exec -it <pod> -n development -- sh` → **forbidden** (no `sre-exec`-equivalent
     `Role` exists for this group)
   - `kubectl get events -n development` → **forbidden** (`events` is in `sre`'s rules, not
     `developer-readonly`'s)

If all four come out as expected, you've confirmed the two roles are actually independently
scoped — not two names pointing at the same effective access.
