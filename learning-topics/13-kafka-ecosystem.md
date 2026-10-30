# Topic 13 — The Kafka ecosystem: schemas, the outbox, Kafka Connect

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `13-kafka-ecosystem`. Mostly gitops (`streaming/`) and the app repo (the
outbox, Avro events, the Connect image); in this repo the events archive (`01-infra
streaming.tf`) and an ECR repository. The user guide is `gitops/docs/KAFKA.md`, sections
"Design choices" and "Changing an event".

---

## 1. The concept

- **A schema registry** stores every version of every event schema and gives each an ID.
  A producer sends the ID with each record (5 bytes: a magic byte and the ID) instead of the
  schema, and a consumer fetches the schema by ID once and caches it. The registry checks
  each new version against a **compatibility rule**: `BACKWARD` (a reader on the new schema
  reads old data: add fields with defaults, may remove fields), `FORWARD` (old readers read
  new data), `FULL` (both), and the `_TRANSITIVE` variants against all versions, not just the
  last. A breaking change is refused at the producer, before any consumer sees it.
- **Avro** is a compact binary format whose data is unreadable without the schema that wrote
  it; a reader resolves the writer's schema against its own (fields it doesn't know are
  skipped, fields it expects but that are missing take their defaults). Protobuf and JSON
  Schema are the alternatives; the registry handles all three.
- **The dual-write problem.** Saving to a database and publishing to Kafka are two systems;
  no transaction spans both, so a crash between them loses the event or (the other way
  round) publishes an event for something that wasn't saved. **The transactional outbox**
  writes the event into the same database, in the same transaction, and a relay publishes it
  afterwards. Delivery becomes at-least-once (a relay crash after sending, before marking,
  sends again), which consumers absorb by deduplicating on an event ID. **Change data
  capture** (Debezium reading the database's log) is the other way to relay: no polling,
  and works for changes made outside the application; it needs a database with a log to
  read (Postgres, step 23).
- **Kafka Connect** runs connectors, plugins that copy data between Kafka and other systems
  (sources into Kafka, sinks out of it), as a cluster of workers that share the work and
  store their state in Kafka topics. A sink is a consumer group, so it gets the group's
  guarantees: at-least-once, offsets committed after the write.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `streaming/base/schema-registry.yaml` | Apicurio Registry 3.3.3, storing in Kafka (`kafkasql`) as KafkaUser `schema-registry`; Confluent-compatible API at `/apis/ccompat/v7`; a PostSync Job sets the global rules `COMPATIBILITY=BACKWARD`, `VALIDITY=FULL`; deletion disabled |
| app order-service `outbox/` | Order and `OrderCreated` in one MongoDB transaction; `OutboxRelay` in every replica: oldest first, `findAndModify` lease of 30s, backoff 2s doubling to 5 min, `SENT` events expire after 7 days (TTL index); gauges `outbox_pending`, `outbox_oldest_pending_age_seconds` |
| app `src/main/avro/*.avsc` | `OrderCreated`, `UserRegistered`; Java classes generated at build; `avro.remove.java.properties` keeps Java-only hints out of the registered schema; a test checks every new version reads every published one |
| app notification-service `EventParser` | Reads records as bytes, decodes them in the writer's schema (`GenericRecord`, no generated classes); not Avro / unknown type → dead letter at once; registry unreachable or 5xx → retried |
| gitops `apps/local/mongodb.yaml` | The lab's MongoDB as a one-member replica set (`--replSet rs0`, an init Job), since transactions need one |
| gitops `streaming/components/events-archive`, `streaming/dev` | KafkaConnect `events-connect` (custom image), KafkaConnector `events-archive` (Aiven S3 sink 3.4.3): `orders`, `users` → gzipped JSON lines, bytes base64; KafkaUser with no `Create`; compacted internal topics |
| app `kafka-connect/` | `FROM quay.io/strimzi/kafka:1.3.0-kafka-4.3.1` plus the plugin, pinned by the SHA-256 GitHub publishes for the release |
| tf `01-infra/streaming.tf` | `enable_events_archive` (on in `dev.tfvars`): bucket (no public access, SSE, HTTPS only, 365-day expiry, no storage-class transitions), IRSA role `kafka_connect` for SA `kafka/events-connect-connect` allowed only `s3:PutObject`, `s3:AbortMultipartUpload` |
| tf `shared-services` | ECR repository `kafka-connect` |
| gitops `addons/streaming/kafka-ui.yaml`, `streaming/tools/avro-console.yaml` | Read-only Kafka UI (kafbat) with Avro decoding; a pod with the Avro console tools to read and replay events |
| gitops `streaming/base/network-policies.yaml`; tf `01-infra` `aws_eks_addon.vpc_cni` | Kafka UI reachable only by port-forward; the registry's API only from the services and its tools; NetworkPolicy enforcement on EKS (`enable_network_policy`, on in dev) |
| gitops `kafka-alerts.yaml` | `OutboxPublishingStalled`, `OutboxBacklogGrowing`, `KafkaConnectConnectorFailed`, `KafkaConnectTaskFailed`, all unit-tested |

Why these choices: **Apicurio** rather than Confluent Schema Registry because it is Apache
2.0 licensed (Confluent's is under the Confluent Community License), while still speaking the
Confluent API, so the standard serializers work. **Aiven's** S3 sink for the same reason
(Confluent's S3 sink needs a licence). The archive stores **bytes**, not decoded JSON: a
record can be replayed exactly, and the archive doesn't depend on the registry being right.

---

## 3. Real incidents

### 3.1 Health checks on the wrong port

Apicurio 3 (Quarkus) serves its health checks and metrics on a separate management port,
9000, not on the API's 8080. Probes on `8080/health/ready` would get 404s and the pod would
never become Ready. Caught while writing the Deployment, from Apicurio's documentation: the
probes and the PodMonitor use the `management` port, and the rules Job waits on
`/apis/registry/v3/system/info` on the API port instead.

### 3.2 A corrupt record was retried as if the registry were down

notification-service retries a record when the registry can't be reached, and dead-letters
one that can't be decoded. The first version counted any `IOException` in the cause chain as
"registry unreachable", but a truncated Avro body throws `EOFException`, an `IOException` too:
a corrupt record was retried four times before being parked. Now only connection failures,
timeouts, unknown hosts and 5xx answers from the registry are retried, with a test for each
side. Lesson: classify errors by what retrying can change, not by their type hierarchy.

### 3.3 The lab's MongoDB couldn't do transactions

A standalone `mongod` refuses transactions ("Transaction numbers are only allowed on a
replica set member or mongos"), and the lab ran one: with the outbox, every order would have
failed. Caught before the lab ran it. The lab's MongoDB now starts with `--replSet rs0` and a
Job runs `rs.initiate()` once; the connection string names the replica set. Atlas clusters
are always replica sets, so dev needed nothing. Unit tests use mocks, so only an integration
test against a standalone `mongod` would have shown it; that is worth adding.

### 3.4 The backoff never reached its cap

The relay's backoff was `2^min(attempts, 8)` seconds, capped at 5 minutes; 2⁸ is 256 seconds,
so the cap was never reached and the comment, the runbook and the guide all described a
5-minute ceiling that didn't exist. Found while writing the runbook from the code; the bound is
now 2⁹, which the cap trims to 300.

### 3.5 A runbook that would have corrupted what it replayed

Step 12's dead-letter replay piped `kafka-console-consumer` into `kafka-console-producer`.
Those treat values as lines of text; Avro values are binary and contain newline and
non-UTF-8 bytes, so a replay would have produced garbage records. The runbook now uses the
Avro console tools (`streaming/tools/avro-console.yaml`): records out as JSON through the
registry, back in as Avro under their schema ID.

### 3.6 The validator rejected a valid KafkaConnect

The repo's own CRD-to-JSON-schema conversion forbids unknown properties on every object, as
kubeconform's converter does. Strimzi's `trustedCertificates` items say "`certificate` or
`pattern`" with a `oneOf` whose branches list only those fields; with `additionalProperties:
false` added inside the branches, `secretName` (declared next to the `oneOf`) was refused. In
Kubernetes, `oneOf`/`anyOf`/`allOf`/`not` only constrain fields declared beside them, so the
converter no longer adds the restriction inside them, and a typo in the item itself is still
caught.

### 3.7 "Reachable only through port-forward" wasn't true

The first Kafka UI had no login, on the grounds that it was reachable only through
`kubectl port-forward`. A security review of the pushed commit pointed out that its Service
answered every pod in the cluster, so any compromised pod could browse every topic; the
schema registry's API, admin endpoints included, was open the same way. Two NetworkPolicies
(`gitops streaming/base/network-policies.yaml`) fix it: nothing may connect to Kafka UI
(port-forward enters the pod's network namespace directly and isn't affected), and only the
services' namespace and three tools may reach the registry's API.

A policy only counts where the network plugin enforces it. KinD has done so since 0.24, so
the lab was fine. EKS's VPC CNI, as EKS installs it, ignores policies, so dev now runs it
as a managed add-on with `enableNetworkPolicy` (`enable_network_policy`, 01-infra main.tf),
pulled forward from step 19, with `preserve = true` so removing the resource can never
uninstall pod networking. Left open: a service may still call the registry's admin API.
Network policies can't tell callers apart by what they call; the mesh's authorization (step
18) can.

### 3.8 Connect without the right to create topics

Connect creates its three internal topics at start if they're missing. Here topics only come
from `KafkaTopic` resources, so the Connect user has no `Create`. Kafka's
`TopicAdmin.createOrFindTopics` treats an authorization refusal as "assume they exist" and
carries on (checked in the 4.3.1 source before relying on it), so the KafkaTopics are created
first and Connect uses them.

---

## 4. Verify — the full sequence

```bash
# Repo checks: renders, CRD schemas (KafkaConnect, KafkaConnector), alert tests
cd gitops && ./scripts/validate.sh
cd tf/infrastructure/app-cluster/01-infra && terraform validate

# Lab or dev: the registry and its rules
kubectl get pods -n kafka -l app.kubernetes.io/name=schema-registry      # Ready
kubectl port-forward svc/schema-registry 8081:8080 -n kafka &
curl -s localhost:8081/apis/ccompat/v7/subjects                           # after the first order: orders-value, users-value
curl -s localhost:8081/apis/registry/v3/admin/rules                       # COMPATIBILITY, VALIDITY

# The outbox: create an order (KAFKA.md "Try it"), then
kubectl exec -n development mongodb-0 -- mongosh --quiet --eval \
  'db.getSiblingDB("microservices").outbox.find({}, {status: 1, attempts: 1}).sort({occurredAt: -1}).limit(3)'

# dev: the archive
kubectl get kafkaconnect,kafkaconnector -n kafka                          # Ready
aws s3 ls s3://microservices-dev-events-archive-602367507570/ --recursive | head
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| order-service: `Transaction numbers are only allowed on a replica set member` | MongoDB isn't a replica set (lab: the init Job didn't run; the URI lacks `replicaSet=rs0`) |
| `order_event_publish_failed` with a 409 | the registry refused a new schema version: not backward compatible |
| notification-service dead-letters everything with "registered schema" | the producer isn't on Avro yet (old image), or writes to a different registry |
| a service's requests to the registry time out (`SchemaRegistryUnavailableException`, outbox stalls) | it runs in a namespace other than `development`: add it to `network-policies.yaml` |
| Kafka UI unreachable through its Service from another pod | by design; use `kubectl port-forward` |
| `KafkaConnector` not Ready, `ClassNotFoundException` | the KafkaConnect runs Strimzi's stock image, not ours (`spec.image` missing in the overlay) |
| connector failed with `AccessDenied` | the IRSA role's trust names another ServiceAccount, or `enable_events_archive` is off |
| connector failed with `NoSuchBucket` | the overlay's bucket name differs from tf's `events_archive_bucket_name` |
| Connect worker crash-loops: `TopicAuthorizationException` on describe | the KafkaUser `events-connect` lacks `Describe` on its internal topics |

---

## 6. Exercise

1. Give user-service an outbox too (it still sends `UserRegistered` right after saving the
   user). What can you share with order-service's, and what can't you?
2. Change the global rule to `BACKWARD_TRANSITIVE` and find a sequence of three schema
   versions that `BACKWARD` accepts and `BACKWARD_TRANSITIVE` refuses.
3. Write a tool that reads one archived file from S3 and produces its records back to a new
   topic `orders-restored`, keys, values and headers intact. Check notification-service would
   treat them as duplicates.
4. Switch the archive to Parquet (`format.output.type`), and query it with Athena. What do you
   lose by archiving bytes instead of decoded fields, and what do you gain?
