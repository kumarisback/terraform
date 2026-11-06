# Topic 19 — Network policies: deny by default

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `19-network-policies`. Mostly gitops (the policies, the test); in this repo, the
VPC CNI's enforcement on by default and the database and MSK security groups. The user guide
is `gitops/docs/NETWORK-POLICIES.md`.

---

## 1. The concept

- **Open until selected.** Kubernetes lets every pod reach every other pod and the internet.
  A NetworkPolicy that selects a pod isolates it in the directions it names (ingress,
  egress); from then on only what some policy allows passes. Policies only add: there is no
  "deny" rule, so a `default-deny` policy (selects every pod, allows nothing) is how a
  namespace starts closed.
- **Both ends must agree.** A connection between two pods passes the sender's egress
  policies and the receiver's ingress policies. Traffic from a pod's own node always gets
  in (the kubelet's health checks), whatever the policies say.
- **Something must enforce them.** The API accepts NetworkPolicies on any cluster; only the
  network plugin drops packets. The AWS VPC CNI does it with its node agent (eBPF) once
  `enableNetworkPolicy` is on; KinD's plugin does since 0.24; Calico and Cilium always do.
- **Addresses and ports, not names.** Peers are pods (by labels), namespaces (by labels) or
  IP ranges. "Only MongoDB Atlas" or "only AWS STS" can't be said, because their addresses
  change; a port can. Cilium and Calico's commercial tiers add DNS-name egress.
- **The metadata service.** `169.254.169.254` hands out the node's IAM credentials to anyone
  who asks from the node, and from a pod too when the launch template allows two hops (the
  common default, needed by add-ons that read it from a pod). With IRSA, pods don't need it.
- **Security groups are the same idea one layer down.** In a VPC, a rule that admits an
  address range admits anything that ever gets an address there; a rule that names a
  security group admits only its members.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `01-infra/variables.tf` `enable_network_policy` | Default `true` now (dev had it since step 13): the VPC CNI as a managed add-on with `enableNetworkPolicy`. The explicit setting left `dev.tfvars` |
| `modules/database` | RDS and ElastiCache security groups admit `client_security_group_ids` (01-infra passes the EKS cluster security group), only the engine's port (3306 or 5432; 6379), no egress rules. `vpc_cidr` input removed. New `tests/database.tftest.hcl` (mocked AWS) |
| `modules/msk` | `client_cidr_blocks` (the pod subnets) replaced by `client_security_group_ids`; test updated, plus one that refuses an empty list |
| gitops `apps/base/network-policies.yaml` | `default-deny`, `dns`, and one policy per workload (waypoint, frontend, user-, order-, notification-service) |
| gitops `apps/components/kafka-clients`, `kafka-msk`; `apps/local/mongodb.yaml` | Egress to the brokers (9093) and registry (8080); to MSK (9098) and STS (443); the lab's MongoDB in the mesh |
| gitops `platform/kong/network-policy.yaml` | `default-deny` and `dns` in kong; the gateways' egress (waypoint 15008, kong-redis 6379); the controller's webhook and metrics, egress anywhere but the metadata service |
| gitops `streaming/base/kafka.yaml` | `networkPolicyPeers` on the TLS listener: app namespaces, keda, kafka |
| gitops `tests/network-policies/` | `check.rb` evaluates each environment's rendered policies against `flows.yaml` (60 to 80 connections that must work or must not, and "every pod in the app and kong namespaces is isolated both ways"); `scripts/validate.sh` runs it |

---

## 3. Real incidents

All found while designing the step; none on a cluster yet.

### 3.1 A policy can't see inside the mesh's tunnel

Between two meshed pods, ztunnel carries everything to port 15008 (HBONE). A policy that
allows "port 8080 from Kong" would have matched nothing: every request to a Service arrives
at the waypoint on 15008, and at the pod from the waypoint on 15008. So the backends accept
15008 from the waypoint (and Prometheus), not from their callers, and the mesh's own
policies decide what happens inside the tunnel. Step 18's review had already shown the
reverse danger: allowing 15008 opens every port behind it unless the mesh says otherwise.

### 3.2 Health checks from an address nobody would guess

In ambient mode, istio-cni rewrites the kubelet's checks of meshed pods to come from
`169.254.7.127`. A default deny without that address on the probe port would have turned
every meshed pod unready, and the whole application would have dropped out of its Services.
Istio's documentation asks for exactly this exception; pods outside the mesh (the waypoint,
Kong's controller, Valkey) are checked from their node, which policies can't block.

### 3.3 Exercises that started a pod in the namespace

Three guides ran `kubectl run` inside the application namespace. With a default deny such a
pod gets DNS and nothing else. One of them, the step-05 load test, had already stopped
working with step 18 (the mesh refuses an identity it doesn't know) and nobody had noticed.
They now run from namespace `default` and go through Kong, as real traffic does. On EKS,
AWS documents that policies may not be enforced reliably on pods without a controller, so
the checks use the services' own pods.

### 3.4 AWS would have rejected the new rule

The first version described the database rule as "from the clients' security groups". The
module test (`terraform test`, mocked AWS) failed at plan: AWS allows only letters, digits,
spaces and `._-:/()#,@[]+=&;{}!$*` in a rule description, and the apostrophe isn't one. A
mocked provider still runs the provider's own validation, which is why the tests are worth
having even with nothing created.

### 3.5 A description that can't be corrected

The groups' descriptions say "from within the VPC", which is no longer true. A security
group's description can't change: Terraform replaces the group, and staging and production
run ElastiCache, which holds on to its group, so the replacement would fail halfway. The
descriptions stay; a comment explains; the rules (which update in place) are what count.

### 3.6 Kong phoned home

Kong sends anonymous usage reports to Kong Inc. unless `anonymous_reports` is off. With the
gateways' egress limited to the waypoint and Valkey, those connections would have failed
forever in the background. They're off now, which is also what you want from a gateway
regardless.

### 3.7 A default deny that changed nothing

Checking that the test catches mistakes, removing the kong namespace's `default-deny` made no
difference: every pod there was already selected in both directions by another policy (the
`dns` policy selects every pod for egress). That's how the semantics work, not a bug: the
`default-deny` is for the next pod someone adds, and the test's "every pod is isolated"
check is what catches that pod without a policy.

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh       # "<env>: network policies" for each environment
cd tf/modules/database && terraform init && terraform test
cd tf/modules/msk && terraform init && terraform test

# Lab or dev
kubectl get networkpolicy -n development
kubectl exec -n development deploy/frontend -- wget -T 3 -qO- http://user-service/api/auth/jwks.json   # fails after a wait
kubectl exec -n development deploy/user-service -- wget -qO- http://order-service/api/orders/status    # 403: the network allows, the mesh refuses
curl -s localhost/api/orders/status                                                                     # through Kong: fine

# dev only
kubectl exec -n development deploy/order-service -- wget -T 3 -qO- http://169.254.169.254/   # fails after a wait
kubectl get policyendpoints -n development                                                  # one per policy: the agent has them
aws ec2 describe-security-groups --group-ids <redis-sg> --query 'SecurityGroups[0].IpPermissions'   # a UserIdGroupPair, no IpRanges
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| meshed pods unready after a policy change | `169.254.7.127` missing on the probe port |
| a call hangs, then fails; ztunnel logs a timeout | a NetworkPolicy dropped it: the sender's egress or the receiver's ingress lacks the rule |
| 403 `RBAC: access denied` | the network let it through; the mesh refused it (topic 18) |
| a new service unreachable through Kong | its policy doesn't accept 15008 from the waypoint |
| policies have no effect on EKS | `enable_network_policy` off, or the add-on not yet updated; no `policyendpoints` in the namespace |
| works in KinD, not on EKS | a Service whose port differs from its container port, reached outside the mesh; or a pod without a controller |
| database or MSK times out from pods | nodes without the EKS cluster security group (a node group launched with its own) |

---

## 6. Exercise

1. Lower the nodes' metadata hop limit to 1 (`modules/eks`, the launch template) in a
   scratch cluster. Find what breaks: the AWS Load Balancer Controller first (give it
   `vpcId` and `region`), then anything else. That is the cluster-wide version of what
   the policies do for two namespaces.
2. Give `monitoring` a default deny with the test's help: list its flows in `flows.yaml`
   first (Prometheus scraping everything, Grafana to Prometheus, Loki and Tempo, Alloy to
   Loki, the collector to Tempo), add `monitoring` to `isolated_namespaces`, then write
   policies until the check passes.
3. Install Cilium in a scratch KinD cluster (`disableDefaultCNI: true`), write a
   CiliumNetworkPolicy that allows `GET /api/orders` but not `DELETE`, and watch a refused
   request in Hubble. Compare it with the waypoint's AuthorizationPolicy doing the same.
4. Use security groups for pods so that only order-service and user-service reach the
   database, not every pod on their nodes; remember `POD_SECURITY_GROUP_ENFORCING_MODE=standard`
   for the mesh's health checks.
