# Topic 05 — Autoscaling: HPA for Pods, Karpenter for Nodes

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → issues found → verify → troubleshooting → exercise.

This is roadmap step `04-autoscaling` (`LEARNING-ROADMAP.md` §04), across two repos: `tf`
(Karpenter's IAM role, instance profile, interruption queue, IRSA) and `gitops` (the
HorizontalPodAutoscalers, metrics-server, the Karpenter chart and its NodePool).

---

## 1. The concept

Three independent axes, and they only work together:

- **HPA (more pods)** — watches a metric (here CPU) and changes a Deployment's replica count.
  It computes "% of the pod's CPU *request*", so a container with no `requests` can't be
  autoscaled at all.
- **VPA (bigger pods)** — recommends or sets requests/limits from observed usage. Not used
  here yet (§6).
- **Node autoscaling (more nodes)** — when new pods don't fit, something has to add capacity.
  *Cluster Autoscaler* resizes a node group's Auto Scaling Group; **Karpenter** skips node
  groups and launches a right-sized EC2 instance for the pending pods directly, usually in
  under a minute. It also *consolidates*: moves pods off under-used nodes and removes them.

The chain under load: CPU rises → HPA adds pods → some are `Pending` (no room) → Karpenter
launches a node → pods schedule. Scale-down runs the other way, and the `PodDisruptionBudget`s
from topic 04 are what keep it safe: Karpenter drains nodes respecting them.

**Spot** is ~70% cheaper but AWS can take the instance back with two minutes' warning. Karpenter
listens for that warning (via an SQS queue fed by EventBridge) and drains the node before it
disappears.

---

## 2. This repo's actual implementation

**metrics-server** — the HPA's source of CPU numbers: `gitops/addons/applications/metrics-server.yaml`,
installed in every environment (and in the kind lab).

**HPAs** — `gitops/apps/base/{frontend,order-service,user-service}/hpa.yaml`, all the same shape:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 2          # never below 2: the PDB (minAvailable: 1) needs a spare
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70   # % of the container's CPU request
```

**Karpenter, AWS side** — `tf/infrastructure/app-cluster/01-infra/main.tf` (commit `88bd793`):

| Resource | Why |
|---|---|
| `aws_iam_role.karpenter_node` + 4 managed policies | The role the *nodes Karpenter launches* run as (worker, CNI, ECR read, SSM) |
| `aws_eks_access_entry.karpenter_nodes` (`EC2_LINUX`) | Lets those nodes join the cluster; maps them to `system:nodes` |
| `aws_iam_instance_profile.karpenter` | EC2 needs an instance profile, not a role, to attach it |
| `aws_sqs_queue.karpenter_interruption` + EventBridge rules | Spot interruption, rebalance and state-change events → queue → Karpenter |
| `irsa_roles.karpenter` | The *controller's* permissions: `ec2:CreateFleet`, `RunInstances`, ..., `iam:PassRole` on the node role only |

`02-services/main.tf` creates the IRSA-annotated `karpenter` ServiceAccount.

**Karpenter, cluster side** — `gitops/bootstrap/projects/karpenter-dev.yaml` installs chart
`1.0.1` (dev only), and `gitops/platform/karpenter/dev/karpenter-config.yaml` defines:
- `NodePool default`: spot or on-demand, instance categories c/m/r/t, amd64, max 100 CPUs
  in total, consolidate when under-utilised, replace every node after 30 days.
- `EC2NodeClass default`: AMI family, node role, and which subnets/security groups to use
  (found by tag, the same tags the ALB controller uses).

Until October 2026 the NodePool lived in the shared `platform/` folder that *every* cluster
syncs — see §3.1.

---

## 3. Issues found in review (October 2026)

These came from reading the code against the cluster version, not from a live run, so treat
them as the first things to fix before relying on Karpenter.

### 3.1 dev's node pool was synced to staging and prod

`platform/karpenter-config.yaml` named dev's node role and security group, but sat in the
`platform` Application that staging and prod sync too. Karpenter isn't installed there, so the
`NodePool`/`EC2NodeClass` kinds don't exist and the *whole* platform sync fails — RBAC, the
secret store and the StorageClasses with it. **Fixed:** moved to `platform/karpenter/dev`,
deployed by the dev-only `karpenter-nodepools` Application (gitops commit `1070861`).

### 3.2 `amiFamily: AL2` on a 1.36 cluster

AWS stopped publishing EKS-optimised Amazon Linux 2 AMIs after Kubernetes 1.32. The cluster
runs 1.36 (`cluster_version`), so an AL2 node class has no AMI to launch. **Open:** switch to
Amazon Linux 2023 (`amiFamily: AL2023`, or in the v1 API `amiSelectorTerms: [{alias: al2023@latest}]`
— pin a version rather than `latest` once it works).

### 3.3 v1beta1 API on Karpenter 1.0

The manifests use `karpenter.sh/v1beta1` (and `consolidationPolicy: WhenUnderutilized`).
Karpenter 1.0 still accepts v1beta1 through a conversion webhook, but later versions don't.
**Open:** migrate to `karpenter.sh/v1` (`WhenEmptyOrUnderutilized`, `nodeClassRef` gains
`group`/`kind`, `expireAfter` moves into the NodePool template) and check Karpenter's
compatibility matrix: chart `1.0.1` predates Kubernetes 1.36.

---

## 4. Verify — the full sequence

```bash
# HPA has numbers to work with (not <unknown>)
kubectl top pods -n development
kubectl get hpa -n development           # TARGETS like 12%/70%

# Generate load and watch both axes
kubectl run load -n development --rm -it --image=busybox -- \
  /bin/sh -c "while true; do wget -q -O- http://frontend; done"
kubectl get hpa -n development -w        # replicas climb
kubectl get pods -n development -w       # some Pending...
kubectl get nodeclaims -w                # ...until Karpenter launches a node
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# Stop the load; after the HPA's scale-down window, replicas fall back to 2 and
# Karpenter consolidates the extra node away
kubectl logs -n kube-system deploy/karpenter | grep -i -E 'disrupt|consolidat'
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| HPA `TARGETS` shows `<unknown>` | metrics-server not ready, or the container has no CPU `requests` |
| Pods `Pending`, no NodeClaim created | Karpenter not running, NodePool `limits` reached, or the pod's requirements match no allowed instance type |
| NodeClaim created but never `Ready` | AMI not found (§3.2), wrong node role in `EC2NodeClass`, or the role has no access entry |
| Karpenter logs `AccessDenied` | IRSA role missing an action, or `iam:PassRole` not on the node role |
| Spot node vanished without a drain | interruption queue name in the chart values doesn't match the SQS queue |

---

## 6. Exercise — close the loop on what's still open

1. Fix §3.2 and §3.3, run the load test, and time scale-up (Karpenter should beat a node
   group resize by minutes).
2. Install VPA in recommendation-only mode (`updateMode: "Off"`) and compare its suggested
   requests with the ones set in topic 04.
3. Replace CPU with a request-rate metric for one service (the Prometheus adapter, or KEDA in
   roadmap step 15) and explain why it reacts better to traffic than CPU does.
