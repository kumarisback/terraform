# Topic 05 — Autoscaling: HPA for Pods, VPA for Sizing, Karpenter for Nodes

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → issues found and fixed → verify → troubleshooting → exercise.

This is roadmap step `04-autoscaling` (`LEARNING-ROADMAP.md` §04), across two repos: `tf`
(Karpenter's IAM, interruption queue, discovery tags) and `gitops` (the HorizontalPodAutoscalers,
metrics-server, VPA, the Karpenter chart and its NodePool, the namespace quotas).

---

## 1. The concept

Three independent axes, and they only work together:

- **HPA (more pods)** — watches a metric (here CPU) and changes a Deployment's replica count.
  It computes "% of the pod's CPU *request*", so a container with no `requests` can't be
  autoscaled at all.
- **VPA (bigger pods)** — learns each container's real CPU/memory use and recommends requests.
  It can apply them itself (evicting pods), but not together with an HPA that scales on the same
  resource: the two would fight. Here it only recommends.
- **Node autoscaling (more nodes)** — when new pods don't fit, something has to add capacity.
  *Cluster Autoscaler* resizes a node group's Auto Scaling Group; **Karpenter** skips node
  groups and launches a right-sized EC2 instance for the pending pods directly, usually in
  under a minute. It also *consolidates*: moves pods off under-used nodes and removes them.

The chain under load: CPU rises → HPA adds pods → some are `Pending` (no room) → Karpenter
launches a node → pods schedule. Scale-down runs the other way; the `PodDisruptionBudget`s from
topic 04 keep it safe, because Karpenter drains nodes respecting them.

Two things can silently stop the chain: a **ResourceQuota** smaller than what the HPAs can ask
for (§3.6), and node-level limits (the NodePool's `limits.cpu`).

**Spot** is ~70% cheaper but AWS can take the instance back with two minutes' warning. Karpenter
listens for that warning (via an SQS queue fed by EventBridge) and drains the node before it
disappears.

---

## 2. This repo's actual implementation

**metrics-server** — the HPA's and VPA's source of usage numbers:
`gitops/addons/applications/metrics-server.yaml`, in every environment and the kind lab.

**HPAs** — `gitops/apps/base/{frontend,order-service,user-service}/hpa.yaml`, all the same shape:
min 2 replicas (the PDB's `minAvailable: 1` needs a spare), max 10, target 70% of the CPU request.

**Quotas that fit the HPAs** — `gitops/apps/components/namespace-guardrails` (dev, staging,
prod): 7 CPU / 14Gi requests, 14 CPU / 28Gi limits, 40 pods — every HPA at its maximum during a
rolling update, plus headroom. The sizing is written out in the component's comment.

**VPA, recommendation only** — `gitops/addons/applications/vertical-pod-autoscaler.yaml`
(official `kubernetes/autoscaler` chart 0.13.0, VPA 1.8.0) with only the recommender running,
and one `VerticalPodAutoscaler` per service (`apps/base/*/vpa.yaml`, `updateMode: "Off"`).

**Karpenter, AWS side** — `tf/infrastructure/app-cluster/01-infra/main.tf`:

| Resource | Why |
|---|---|
| `aws_iam_role.karpenter_node` + 4 managed policies | The role the *nodes Karpenter launches* run as (worker, CNI, ECR read, SSM) |
| `aws_eks_access_entry.karpenter_nodes` (`EC2_LINUX`) | Lets those nodes join the cluster; maps them to `system:nodes` |
| `aws_iam_instance_profile.karpenter` | What the EC2NodeClass names, so the controller never creates IAM objects |
| `aws_sqs_queue.karpenter_interruption` + EventBridge rules | Spot interruption, rebalance and state-change events → queue → Karpenter |
| `irsa_roles.karpenter` | The *controller's* permissions, following Karpenter's own controller policy (§3.4) |
| `karpenter.sh/discovery` tags | On the private app subnets and the EKS cluster security group (§3.5) |

**Karpenter, cluster side** — `gitops/bootstrap/projects/karpenter-dev.yaml` installs chart
`1.14.1` (dev only); `gitops/platform/karpenter/dev/karpenter-config.yaml`, deployed by the
dev-only `karpenter-nodepools` Application, defines (v1 API):
- `NodePool default`: spot or on-demand, instance categories c/m/r/t, amd64, max 100 CPUs in
  total, replace nodes after 30 days, consolidate when empty or under-used (after 1 minute).
- `EC2NodeClass default`: Amazon Linux 2023 pinned to EKS AMI release `v20260930`, the tf
  instance profile, subnets and security group found by `karpenter.sh/discovery`.

---

## 3. Issues found in review (October 2026) — all fixed

These came from reading the code against the cluster version and Karpenter's docs, not from a
live run. Each would have stopped Karpenter from working.

### 3.1 dev's node pool was synced to staging and prod

It sat in the `platform` Application that every cluster syncs. Without Karpenter there, the
whole platform sync failed on the unknown kinds. Moved to a dev-only Application (gitops
`1070861`).

### 3.2 Kubernetes 1.36 with Karpenter 1.0.1

Karpenter's compatibility matrix needs **1.13 or later** for Kubernetes 1.36. Upgraded to
1.14.1, which serves only the `v1` API, so the manifests moved too: `nodeClassRef` gains
`group`/`kind`, `expireAfter` moves into the template, `WhenUnderutilized` becomes
`WhenEmptyOrUnderutilized` (gitops `dc2692d`). A cluster still *running* 1.0 with v1beta1
objects has to go through the latest 1.0.x first (Karpenter's v1 migration guide); dev is
rebuilt each session, so it can jump.

### 3.3 No AMI to launch

`amiFamily: AL2` — EKS publishes no Amazon Linux 2 AMIs after Kubernetes 1.32. Now
`alias: al2023@v20260930`, pinned so nodes only change when the date is bumped (and then roll
gradually within disruption budgets).

### 3.4 The controller's IAM policy was missing calls it makes on startup

No SQS access to the interruption queue, no `eks:DescribeCluster` (endpoint discovery), no
`ec2:DeleteLaunchTemplate`, `ec2:DescribeSpotPriceHistory` or `iam:GetInstanceProfile`. Rewritten
from Karpenter's controller policy (tf `78f4110`): deletion limited to resources tagged
`karpenter.sh/nodepool`, SSM limited to AWS's public AMI parameters, and no IAM write access at
all, because the node class names an existing instance profile.

### 3.5 New nodes would have been cut off from the rest

The node class picked the security group named `microservices-dev-eks-cluster-sg` — Terraform's
*additional* control-plane group, which only allows HTTPS in. The managed node group's nodes use
the security group **EKS creates** for the cluster, which lets nodes and pods reach each other.
Karpenter's nodes now get that one, found by a `karpenter.sh/discovery` tag Terraform puts on it
(`aws_ec2_tag`, since EKS creates the group).

### 3.6 The quota stopped the HPAs halfway

dev's quota (2 CPU, 20 pods) was below what three HPAs at 10 replicas ask for (6 CPU, 30 pods),
and staging/prod had no quota at all. An HPA blocked by a quota looks healthy; the only sign is
`exceeded quota` events on the ReplicaSet. Now one sized quota for every environment (gitops
`dc45a28`).

### 3.7 ArgoCD and the HPAs undid each other

The base Deployments set `replicas: 2`, the HPAs scale them 2–10, and ArgoCD syncs with
self-heal. Every time an HPA scaled up, ArgoCD saw drift from Git and set the count back to 2;
under load the services would have flapped instead of scaling. `replicas` is now removed from
the Deployments (gitops `171ba16`), as the Kubernetes HPA docs recommend: whatever an HPA
manages must not also be declared in Git. (The first sync after the change briefly drops each
Deployment to 1 replica until its HPA restores 2.)

---

## 4. Verify — the full sequence

```bash
# HPA has numbers to work with (not <unknown>), quota has room
kubectl top pods -n development
kubectl get hpa -n development             # TARGETS like 12%/70%
kubectl describe quota -n development      # Used well below Hard

# Karpenter is healthy and knows its node class
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Generate load and watch both axes
kubectl run load -n development --rm -it --image=busybox -- \
  /bin/sh -c "while true; do wget -q -O- http://frontend; done"
kubectl get hpa -n development -w          # replicas climb
kubectl get nodeclaims -w                  # Karpenter launches a node in < 60s
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# Stop the load: replicas fall back to 2, then Karpenter consolidates the node away
kubectl logs -n kube-system deploy/karpenter | grep -i -E 'disrupt|consolidat'

# VPA's suggestions after the load (compare with the requests in apps/base/*/deployment.yaml)
kubectl describe vpa -n development
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| HPA `TARGETS` shows `<unknown>` | metrics-server not ready, or the container has no CPU `requests` |
| HPA wants more replicas than exist | quota reached: `kubectl describe rs` shows `exceeded quota` |
| Pods `Pending`, no NodeClaim created | Karpenter not running, NodePool `limits` reached, or no instance type fits the pod |
| NodeClaim never `Ready` | EC2NodeClass not Ready (no subnets/SG/AMI resolved), or the node role has no access entry |
| Karpenter logs `AccessDenied` | a call missing from the IRSA policy, or `iam:PassRole` not on the node role |
| Spot node vanished without a drain | the chart's `interruptionQueue` doesn't match the SQS queue name |
| VPA shows no recommendation | needs a few minutes of metrics; recommender not running |

---

## 6. Exercise — what's left to do by hand

1. Run §4's load test on dev and time scale-up: Karpenter vs. what a node-group resize would take.
2. Trigger a spot interruption (AWS FIS "interrupt spot instance") and confirm the node is drained
   before it goes, with no failed requests.
3. After a day of normal traffic, compare VPA's targets with the requests set in topic 04, and
   change the requests in Git where they're far off — then recheck the quota sizing (§3.6).
