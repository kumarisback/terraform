# Topic 01 — VPC Peering, Step by Step

**How this folder works:** each file here is one focused, standalone deep-dive on a single
topic — not part of the numbered branch roadmaps (`01-LEARNING-ROADMAP-OWN-YOUR-STACK.md`,
`LEARNING-ROADMAP.md`), just a reference you can read anytime a topic needs a closer look.
To add another topic, drop a new file in this same folder named `02-<topic>.md`,
`03-<topic>.md`, and so on — same structure as this one (Concept → Manual walkthrough →
Terraform walkthrough → Real incident → Troubleshooting → Verify → Exercise).

This one exists because we hit a real, subtle VPC peering bug in this repo (Jenkins could
reach the peered VPC's network but not resolve the EKS private endpoint's hostname) — that
incident is used throughout as the worked example, because debugging it taught the concept
better than a clean example would have.

---

## 1. The concept

**What it is:** a VPC Peering Connection is a private network link between two VPCs. Once
established, resources in either VPC can talk to resources in the other using **private IP
addresses**, as if they were on the same network — no internet gateway, no NAT, no VPN.

**What it is *not*:**
- **Not transitive.** If VPC A peers with B, and B peers with C, A cannot reach C through B.
  Each pair needs its own peering connection (or you need a Transit Gateway instead — see §7).
- **Not automatic for DNS.** Connecting the networks and resolving private hostnames across
  that connection are two *separate* settings. This is the exact thing that bit us — see §5.
- **Not a router.** It doesn't push routes into your route tables for you. You still add
  explicit routes on both sides pointing at the peering connection.

**When to use it vs. the alternatives:**
| Need | Use |
|---|---|
| 2 VPCs, same account or a small number of accounts, simple hub-or-mesh | **VPC Peering** (this doc) |
| Many VPCs, want a single hub, need transitivity | **Transit Gateway** |
| Connecting to on-prem or a non-AWS network | **VPN / Direct Connect** |
| Just calling an AWS *service* (S3, DynamoDB, etc.) privately | **VPC Endpoint** — different problem, no peering needed |

This repo uses peering because it's exactly the first case: one shared-services VPC (Jenkins)
needs to reach a small, fixed number of app-cluster VPCs (dev/staging/prod).

---

## 2. Prerequisites checklist

Before creating anything, confirm:

- [ ] **No overlapping CIDR blocks.** Peering two VPCs with overlapping ranges is not
  possible — the connection will accept but routing will never work correctly. Check with
  a CIDR calculator or just eyeball the ranges (this repo: shared-services `10.50.0.0/16`,
  dev `10.10.0.0/16`, staging `10.20.0.0/16`, prod `10.30.0.0/16` — all disjoint).
- [ ] **Know which account/region each VPC is in.** Same-account-same-region (this repo's
  case) is the simple path — one side can `auto_accept`. Cross-account or cross-region needs
  an explicit accept step and, for cross-region, different DNS/pricing considerations.
- [ ] **Decide the direction of "requester" vs "accepter."** Doesn't functionally matter
  which VPC initiates, but pick one convention and stay consistent (this repo: each
  app-cluster environment is the requester, shared-services is always the accepter).

---

## 3. Manual walkthrough (AWS Console) — do this once by hand first

Doing this by hand once, before automating it, is worth the 15 minutes — it makes every step
Terraform does later concrete instead of abstract.

1. **VPC Console → Peering Connections → Create Peering Connection.**
   - Name it something identifiable, e.g. `dev-to-shared-services`.
   - "VPC (Requester)" = the VPC initiating the connection (e.g. dev's VPC).
   - "Account" = same account (or "Another account" + their ID for cross-account).
   - "VPC (Accepter)" = the other VPC's ID (e.g. shared-services' VPC).
   - Create.
2. **Accept it.** Same-account connections still start in `pending-acceptance` state. Select
   it → Actions → Accept Request. (This is the step Terraform's `auto_accept = true` does for
   you automatically — only works same-account/region.)
3. **Add routes, both sides.** Peering alone routes nothing.
   - In dev's route table(s) (the ones used by subnets that need to reach shared-services):
     add a route with destination = shared-services' CIDR (`10.50.0.0/16`), target = the
     peering connection.
   - In shared-services' route table (the one used by the subnet Jenkins is in): add a route
     with destination = dev's CIDR (`10.10.0.0/16`), target = the same peering connection.
   - **Both directions are required.** Forgetting the return route is the single most common
     peering mistake — traffic goes out fine, replies have nowhere to come back through.
4. **Update security groups, both sides.** A route existing doesn't mean anything is allowed
   through it — security groups still apply. Add an inbound rule on whatever you're trying to
   reach (e.g. the EKS control plane's security group) allowing the port you need (443) from
   the peer VPC's CIDR.
5. **Enable DNS resolution across the peering, both sides** (Peering Connections → select it
   → Actions → Edit DNS Settings): check "Allow DNS resolution from the requester/accepter
   VPC" — **this is the step almost everyone forgets, including this repo's first attempt.**
   See §5 for exactly why it matters.

At this point, an instance in either VPC should be able to reach a private IP (or a
privately-resolvable hostname) in the other.

---

## 4. Terraform walkthrough — matching this repo's real implementation

Same five steps as §3, as Terraform resources. File references are to this repo's actual
`infrastructure/app-cluster/01-infra/main.tf`.

**Step 1+2 — create and accept the connection:**
```hcl
resource "aws_vpc_peering_connection" "shared_services" {
  vpc_id      = module.networking.vpc_id                 # requester (this env's VPC)
  peer_vpc_id = data.terraform_remote_state.shared_services.outputs.vpc_id  # accepter
  auto_accept = true  # only valid same-account + same-region
}
```
`auto_accept = true` collapses steps 1 and 2 into one resource — Terraform creates the
connection and immediately accepts it in the same apply, because both VPCs are in the
same AWS account. Cross-account peering needs a separate
`aws_vpc_peering_connection_accepter` resource run with the *other* account's credentials.

**Step 3 — routes, both directions:**
```hcl
# This env's private route table → shared-services
resource "aws_route" "to_shared_services" {
  route_table_id            = module.networking.private_route_table_id
  destination_cidr_block    = data.terraform_remote_state.shared_services.outputs.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_services.id
}

# shared-services' route table → this env
# (owned by THIS state even though the route table belongs to shared-services' state —
# Terraform tracks an aws_route resource independently of the route table it's attached to)
resource "aws_route" "from_shared_services" {
  route_table_id            = data.terraform_remote_state.shared_services.outputs.private_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_services.id
}
```
Notice both routes are declared in the *same* Terraform state (this env's `01-infra`), even
though one of them modifies a route table that belongs to a *different* state
(shared-services'). That's legal and safe — an `aws_route` is tracked as its own resource,
independent of the route table object — but it does mean shared-services' route table must
never be destroyed/recreated without also re-running this env's apply, or the route becomes
orphaned in Terraform's eyes.

**Step 4 — security group rule:**
```hcl
resource "aws_security_group_rule" "eks_cluster_ingress_private" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.private_access_cidrs   # shared-services' CIDR, passed in
  security_group_id = aws_security_group.eks_cluster.id
}
```

**Step 5 — DNS resolution, both sides, one resource (same account):**
```hcl
resource "aws_vpc_peering_connection_options" "shared_services" {
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_services.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }
}
```

---

## 5. Real incident: the DNS gotcha (why step 5 exists)

This actually happened in this repo, and is worth reading in full because it's a genuinely
common, easy-to-miss failure mode — it will happen to you again on some other project if you
don't internalize *why* it happens, not just *that* it happens.

**Setup:** Jenkins lives in `shared-services`' VPC. It needs to reach the EKS cluster's API
endpoint in `dev`'s VPC, which is private-only (no public access). We peered the two VPCs,
added routes both directions, and added the security group rule allowing 443 from
shared-services' CIDR.

**Symptom:** `terraform apply` on the services layer (which runs `helm_release`/Kubernetes
resources against the cluster) failed with a **connection timeout** — not "connection
refused," not "no such host," a timeout.

**Why a timeout specifically, and not a cleaner error:** EKS automatically creates a private
Route53 hosted zone for the cluster's API endpoint hostname
(`https://XXXX.gr7.us-east-1.eks.amazonaws.com`), associated **only with the cluster's own
VPC** by default. Peering two VPCs connects their *networks* — it does nothing to their *DNS
resolvers*. Jenkins' VPC resolver had never heard of that hostname, so:
1. Jenkins asks its own resolver to look up the hostname.
2. Not finding a private hosted zone match, the resolver falls back to public DNS.
3. Depending on exact resolver behavior, this can return nothing, return a stale/irrelevant
   answer, or (in some setups) partially succeed enough to attempt a connection that then
   hangs — the network route exists (peering + routes + SG are all correct), so the *TCP
   connection attempt* doesn't get an immediate rejection, it just never completes. Hence:
   timeout, not a DNS error, even though DNS is the actual root cause.

This is what makes this bug specifically nasty: every individual piece you'd normally check
first (peering status, route tables, security groups) looks completely correct, because they
*are* correct. The missing piece is a setting on the peering connection itself that has
nothing to do with routing.

**Fix:** `aws_vpc_peering_connection_options` (§4, step 5) — this is the AWS-documented,
correct way to extend private DNS resolution across a peering connection. It's simpler and
more general than the alternative fix (manually finding EKS's auto-created hosted zone ID and
associating it with the peer VPC via `aws_route53_zone_association`) because it covers *any*
private hosted zone either VPC might need to resolve, not just this one.

**The lesson to keep:** whenever you peer two VPCs specifically so one side can reach a
*private endpoint by hostname* in the other (EKS, RDS, an internal ALB, anything using a
private hosted zone) — not just a bare IP — check DNS resolution settings on the peering
connection immediately. Don't wait to be bitten by it.

---

## 6. Troubleshooting checklist

Work through these **in order** — each rules out one layer before you look at the next:

1. **Is the peering connection `active`?**
   `aws ec2 describe-vpc-peering-connections --filters "Name=status-code,Values=active"`
   — if it's `pending-acceptance`, it was never accepted (cross-account peering needs an
   explicit accept from the other account).
2. **Do routes exist, both directions?** Check both route tables — the one used by the
   subnet you're calling *from*, and the one used by the subnet you're calling *to*.
   `aws ec2 describe-route-tables --route-table-ids <id>` and look for a route with
   `VpcPeeringConnectionId` set to your connection.
3. **Does the security group on the target allow the port, from the source CIDR?** Not the
   peering connection's own settings — the actual resource you're trying to reach (an EC2
   instance, an EKS control plane, an RDS instance) has its own SG that must explicitly allow
   the traffic. Peering never bypasses security groups.
4. **Does DNS resolve to the right thing?** `nslookup <hostname>` from inside the source VPC.
   If it fails or looks wrong, check `allow_remote_vpc_dns_resolution` on both sides (§5), and
   confirm both VPCs have `enable_dns_support`/`enable_dns_hostnames` set to `true` (peering
   DNS resolution requires both, on both VPCs).
5. **Does a raw TCP connection succeed?** `curl -v --connect-timeout 5 https://<host>` or
   `nc -zv <ip> <port>`. If DNS resolves correctly but this still hangs, you're back to
   routes/security-groups (steps 2-3) — double check them with the *specific* IP DNS returned,
   not just the hostname.

---

## 7. When peering isn't the right answer anymore

Peering doesn't scale past a handful of VPCs, because it's not transitive — N VPCs that all
need to reach each other require `N×(N-1)/2` separate peering connections. The moment you're
drawing more than 3-4 lines between VPCs on a whiteboard, switch to a **Transit Gateway**: one
hub, every VPC attaches to it once, and it *is* transitive (subject to route table
associations you control). Same DNS caveat applies there too, but it's solved once at the
Transit Gateway level instead of once per pair.

---

## 8. Exercise — build it yourself

Don't just read this — rebuild it in a scratch AWS setup to make it real:

1. Create two VPCs by hand (Console or `aws ec2 create-vpc`), non-overlapping CIDRs, one
   public subnet each.
2. Launch one EC2 instance in each (a plain Amazon Linux instance, no special setup).
3. Confirm they **cannot** reach each other's private IP yet (`ping` from one to the other's
   private IP — should fail/timeout).
4. Work through §3 by hand, one step at a time, testing after each: peering created (still
   can't ping — no routes yet) → routes added (still might fail — check SGs) → SG rule added
   (ping should work now) → done, that part doesn't need DNS.
5. Now the DNS part: create a private Route53 hosted zone in VPC A only, with one record. From
   an instance in VPC B, try to resolve that record — it will fail. Enable
   `allow_remote_vpc_dns_resolution` both directions, try again — it will now resolve.
6. Tear it all down. Then do the same thing again, this time entirely in Terraform, mirroring
   §4 — and compare your version against this repo's actual `01-infra/main.tf` when you're
   done.

If you can explain, from memory, *why* step 5's DNS setting is separate from step 3's
routing, you've actually learned this — not just copied it.
