# Topic 23 — PostgreSQL on RDS, production-grade, and change data capture

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `23-rds-production`, which also takes step 13's change data capture. In this
repo: `modules/database` (the instance, its parameter group, monitoring, alarms, the optional
replica and RDS Proxy, tests), `01-infra` (the wiring, the alarm topic, External Secrets' and
Grafana's roles, outputs for gitops). In gitops: Unleash on RDS (`feature-flags/components/rds`),
Reloader, Debezium (`streaming/components/flag-changes`), the CloudWatch dashboard. In the app:
Debezium in the Kafka Connect image. The user guide is `gitops/docs/DATABASE.md`.

---

## 1. The concept

- **Availability vs scale.** Multi-AZ: a synchronous standby in another zone, no queries,
  automatic failover (same endpoint, 1–2 minutes). Read replica: asynchronous, readable, for
  reads; its lag is the price. Different problems; a replica is not a failover plan.
- **Connections are expensive.** One PostgreSQL process per connection; `max_connections`
  follows memory (about 80 on db.t4g.micro). Pods × pool size runs out fast when something
  scales. Pool in front: RDS Proxy (managed) or PgBouncer (self-run).
- **Credentials nobody types.** RDS-managed master secret, rotated by RDS; a client either
  re-reads it (and restarts) or signs in with IAM tokens instead of a password.
- **Encryption in transit means verification.** `sslmode=require` encrypts; only
  `verify-full` (or Node's `rejectUnauthorized` with the CA) stops a man in the middle.
- **Change data capture.** The database's log as the event source: committed, ordered,
  nothing changed in the writer. The cost: table-shaped records and a replication slot that
  keeps log until its reader confirms it.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `modules/database/main.tf` | `aws_db_parameter_group` (`rds.force_ssl`, `rds.logical_replication`, `log_min_duration_statement`); `aws_db_instance.rds` (PostgreSQL 17, Multi-AZ, gp3 with autoscaling, `ca_cert_identifier`, managed master password, IAM auth, Database Insights standard, Enhanced Monitoring role, log exports, final snapshot, deletion protection); `rds_replica`; RDS Proxy (security group with standalone rules, IAM role reading the secret, proxy requiring TLS, target group with pool limits); five or six CloudWatch alarms |
| `modules/database/tests/database.tftest.hcl` | 7 runs against a mocked provider: the security group, the production settings, the replica's alarm, the proxy, the proxy's precondition, the engine and client validations |
| `01-infra/main.tf` | Unleash's database name and user, `rds_multi_az`, `rds_read_replica`, `rds_proxy`; the SNS topic and e-mail subscription for the alarms; IRSA role `unleash_rds_secret`: the RDS master secret (that ARN only), for a SecretStore in namespace `feature-flags`; External Secrets' cluster-wide role keeps to `microservices/*` |
| `01-infra/observability.tf` | IRSA role `grafana_cloudwatch`: CloudWatch metrics and alarms, read-only |
| `01-infra/outputs.tf` | `rds_address`, `rds_master_secret_arn`, `rds_proxy_address`, `database_subnet_cidrs`: what gitops' ConfigMaps take |
| `environments/app-cluster/dev.tfvars` | The block to uncomment for the exercises (RDS is off by default) |

---

## 3. Real incidents

All found while building the step; none on a running instance yet.

### 3.1 A switch that couldn't be turned off

`manage_master_user_password = var.rds_manage_master_user_password` looks right. With the
variable false and a `password` given, the provider refuses the plan: the two arguments
conflict *when both are set*, and `false` counts as set. Nobody had ever planned that
combination; the new proxy precondition test did. The fix is `? true : null`: an argument
that is off should be absent.

### 3.2 A test that couldn't see a value

The proxy's IAM policy and auth block use the managed secret's ARN, which exists only after
the instance does: `command = plan` had nothing to compare. `override_during = plan` on the
mocked `aws_db_instance` and `aws_security_group` supplies those values at plan time, so the
test stays a plan (fast, nothing "created") and still checks the wiring.

### 3.3 Two security groups that refer to each other

The proxy's group must reach the database's; the database's must admit the proxy's. Inline
rules on both would be a dependency cycle. The database's group keeps its inline rules (a
running database holds on to its group, so it isn't rebuilt) plus a dynamic one from the
proxy; the proxy's group has no inline rules, only `aws_vpc_security_group_*_rule` resources.
Mixing inline and standalone rules on one group makes Terraform fight itself; this layout
never does.

### 3.4 The proxy's certificate isn't RDS's

RDS Proxy presents an ACM certificate (Amazon's public roots), not one from the RDS CA. A
client given only AWS's RDS bundle refuses the proxy. The bundle in gitops is both: RDS's CAs
and Amazon Root CA 1–4, rebuilt by `scripts/update-rds-ca.sh`, which refuses anything not
issued by Amazon.

### 3.5 An environment variable that silently wins

Unleash builds its TLS options from `DATABASE_SSL` if set (a JSON value), and only otherwise
from `DATABASE_SSL_CA_FILE`. The base sets `DATABASE_SSL=false` for the in-cluster database;
adding the CA file next to it would have connected *without* TLS (and RDS would refuse). The
RDS component deletes the variable and sets the CA file and `DATABASE_SSL_REJECT_UNAUTHORIZED`.

### 3.6 Restarting on rotation, without reading every Secret

Reloader's chart defaults to a ClusterRole that reads every Secret in the cluster. It needs
one namespace: `watchGlobally: false` with `namespaces: [feature-flags]` gives it a Role
there only, and it is installed only with feature flags (lab, dev).

### 3.7 Kustomize's limits

A Kustomization reads only files below it, so the CA bundle exists twice (Unleash's and
Debezium's components), with `validate.sh` checking they match. And Kustomize renames a
generated ConfigMap only where it knows the field is a reference: not in a KafkaConnect's
`template.pod.volumes`, so Debezium's copy has a fixed name.

### 3.8 The slot that fills the disk

A logical replication slot keeps write-ahead log until its reader confirms it. Debezium
stopped for a week means a week of the whole database's log on disk, growing until storage
autoscaling hits its limit. Two defences: `heartbeat.interval.ms` (Debezium confirms its
position every minute even when its table doesn't change) and the `replication_slot_lag`
alarm (`OldestReplicationSlotLag` over 1 GiB).

### 3.9 A master secret any namespace could have read

The first version let External Secrets' role read the RDS master secret. That role backs
a *cluster-wide* store with no namespace conditions: an ExternalSecret in any namespace
could have copied the master password out. An automated security review caught it. The
secret now has a role of its own, trusted by one ServiceAccount in `feature-flags`, used
by a namespaced SecretStore there; the shared role is back to `microservices/*`. The same
review's other point stands as `gitops/docs/ISSUES.md` #17: Unleash signing in as the
master user at all (fix: its own role, rotated with alternating users).

### 3.10 "The VPC" includes every pod

Unleash's egress rule to RDS first allowed the VPC's whole range on 5432. With the VPC CNI
every pod has an address in that range, so the rule let Unleash reach any pod listening on
5432, not only RDS. Another review finding. The rule now names the private data subnets
only, where RDS and RDS Proxy live (tf output `database_subnet_cidrs`); RDS's IP itself
isn't usable, since a Multi-AZ failover moves the endpoint to the standby's address in
the other subnet.

### 3.11 Nothing to route reads to

The roadmap says to route order-service's reads to the replica; order-service uses MongoDB,
and Unleash can't split reads. The replica stays optional, for the lag exercise, and section
6 says what a service would need.

---

## 4. Verify — the full sequence

```bash
cd tf/modules/database && terraform init && terraform test     # 7 passed, no AWS
cd tf/infrastructure/app-cluster/01-infra && terraform validate
cd gitops && ./scripts/validate.sh     # the four tests/kustomize overlays, Reloader, CA bundles

# dev, with enable_rds = true and gitops switched (DATABASE.md "Deploying to dev")
aws rds describe-db-instances --db-instance-identifier microservices-dev-rds \
  --query 'DBInstances[0].[MultiAZ,StorageEncrypted,CACertificateIdentifier,PerformanceInsightsEnabled]'
kubectl -n feature-flags logs deploy/unleash | grep -i -m3 'migrat\|database'
kubectl -n feature-flags get externalsecret unleash-db     # SecretSynced
kubectl -n kafka get kafkaconnector flag-changes -o jsonpath='{.status.connectorStatus.connector.state}'
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| `terraform apply` waits ~10 minutes on the instance | Multi-AZ creation; a parameter group change needs a reboot (`pending-reboot`) |
| Plan wants to replace the parameter group | the engine's major version changed its family; `create_before_destroy` moves the instance first |
| `destroy` fails: deletion protection | set `rds_deletion_protection = false`, apply, then destroy |
| `destroy` fails: final snapshot exists | the identifier is taken by an earlier destroy: change `rds_final_snapshot_identifier` or delete the old snapshot |
| ExternalSecret `unleash-db`: `AccessDenied` on `rds!db-…` | role `unleash_rds_secret` exists only with `enable_rds && rds_manage_master_user_password` (apply 01-infra after enabling RDS), and `secret-reader-role-arn` in gitops' `unleash-rds` must name it |
| Grafana's CloudWatch panels: `AccessDenied` / no credentials | the ServiceAccount annotation names another role, or the IRSA webhook didn't inject (restart Grafana after annotating) |
| RDS Proxy target `UNAVAILABLE` | the proxy's role can't read the secret, or the database's group lacks the rule from the proxy's |

---

## 6. Exercise

1. **A dedicated Debezium role.** Create `debezium` with `rds_replication` and `SELECT` on
   `public.events`, create the publication as the table owner, and set
   `publication.autocreate.mode: disabled`; store its password in Secrets Manager.
2. **IAM authentication.** From a pod with an IRSA role allowed `rds-db:connect` on
   `dbuser:<resource-id>/<user>`, connect with `aws rds generate-db-auth-token` as the
   password; then explain why Unleash can't (it reads its password once).
3. **PgBouncer instead of RDS Proxy.** Run it in transaction mode in front of the instance;
   compare connection counts and failover behaviour with the proxy's.
4. **Reads on the replica.** Sketch what order-service would need if it used PostgreSQL: a
   second `DataSource`, read-only transactions routed to it, and what "read your own write"
   means with lag.
5. **Avro for CDC.** Put Apicurio's converter in the Connect image and make
   `flags.public.events` Avro with a registered schema, like `orders`.
6. **Aurora.** Price an Aurora PostgreSQL cluster (one writer, one reader) against this
   instance with a replica, and list what failover time it buys.
