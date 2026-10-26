# Topic 12 — Kafka on Kubernetes with Strimzi

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `12-kafka-strimzi`. Mostly gitops (`streaming/`, `addons/streaming/`,
`apps/components/kafka-clients`) and the app repo (notification-service, the producers); in
this repo an ECR repository and two Secrets Manager secrets. The user guide is
`gitops/docs/KAFKA.md`.

---

## 1. The concept

- **A log, not a queue.** A topic is an append-only, replicated log kept for a retention
  period. Consumers track their own position (offset), so any number of independent consumer
  groups read the same events, and any of them can rewind and replay. A queue (SQS, RabbitMQ)
  deletes a message once one worker took it: simpler, right for task distribution, no replay.
- **Partitions** are the unit of both parallelism and ordering. A group reads each partition
  with one consumer at a time; order holds only inside a partition. The partition count caps a
  group's useful size, and it can only grow (moving keys) — choose it with headroom.
- **Replication.** Each partition has a leader and followers; the in-sync replicas (ISR) are
  those caught up. With `replication.factor=3`, `min.insync.replicas=2` and producers using
  `acks=all`, a write is acknowledged only once two replicas have it: one broker can die
  without data loss or refused writes.
- **Delivery semantics.** At-most-once (commit before processing), at-least-once (commit
  after; duplicates possible, so consumers must be idempotent), exactly-once (idempotent
  producers + transactions, inside Kafka only). Idempotent producers stop duplicates from
  producer retries; they don't make a consumer's side effects idempotent.
- **KRaft** replaced ZooKeeper: Kafka keeps its metadata in its own quorum of controllers
  (Raft). A quorum of 3 survives losing 1.
- **On Kubernetes**, brokers are stateful (their own volume each, stable identity), spread over
  zones with rack awareness so replicas don't share a zone, and drained carefully. An operator
  (Strimzi) encodes all that: you declare `Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser`
  in Git and it does the rolling restarts, certificates, ACLs and scaling.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| gitops `addons/streaming/` | Strimzi 1.3.0 (Kafka 4.3.1, `v1` API, Kubernetes 1.32+), the Strimzi Access Operator 0.3.0, the `streaming-config` app; only lab and dev include it |
| gitops `streaming/base/kafka.yaml` | Cluster `events`: 3 controllers + 3 brokers, zone spread and rack awareness, TLS listener with client-certificate auth, ACLs, `auto.create.topics.enable: false`, JMX metrics, Kafka Exporter |
| gitops `streaming/base/topics.yaml`, `users.yaml` | `orders` (6 partitions), `users` (3), `orders-dlq`, `users-dlq`; one KafkaUser per service with least-privilege ACLs; `kafka-admin` super user for people |
| gitops `streaming/local` | One combined node, replication 1, no racks (KinD) |
| gitops `apps/components/kafka-clients` | KafkaAccess per service → Secret with address, client cert/key, cluster CA in the app namespace |
| gitops `charts/microservice` 0.2.0 | `kafka.enabled` wires the Secret into a Spring SSL bundle; `mongodbUriSecret: null` for a service without a database |
| gitops `streaming/base/kafka-alerts.yaml`, `tests/prometheus/kafka_test.yaml` | 8 alerts, unit-tested; Strimzi's dashboards via the operator chart |
| app `notification-service` | Consumer group `notification-service`; retries 1s/2s/4s then `<topic>-dlq`; skips redelivered events by `eventId`; 9 tests incl. an in-process broker |
| app order-service, user-service | `POST /api/orders` publishes `OrderCreated` (key: order ID); sign-up publishes `UserRegistered`; both `acks=all`, idempotent |
| tf `shared-services` | ECR repository `notification-service` |
| tf `01-infra` `aws_secretsmanager_secret.out_of_band`, `scripts/set-secret.sh` | Empty `mongodb` and `jwt-signing-key` secrets; values set outside Terraform (§3.5) |

---

## 3. Real incidents

### 3.1 The duplicate guard that ate retries

notification-service remembers the event IDs it handled, so a redelivered record isn't sent
twice. The first version remembered the ID **before** sending. The integration test that makes
the send fail found it: the first attempt failed, the retry saw a "known" event, skipped it as
a duplicate, and the error handler considered the record done. The event vanished — not even
in the dead-letter topic. An event now counts as handled only after a successful send.
Lesson: idempotency markers go after the side effect, and a test with a failing dependency is
what proves it.

### 3.2 The order endpoint exposed a forgeable identity

Adding `POST /api/orders` (user ID in the body, no authentication) triggered a security review.
Following it showed a bigger problem: user-service signed its tokens with an HMAC secret
**hard-coded in the source**, and `application.properties` forced the profile that used it, in
every environment. Anyone with the repo could mint a token for any user. The fix: user-service
signs with an RSA key from a Secret (no default; it won't start without one) and publishes the
public key as a JWK Set; order-service verifies tokens against it (`RS256` only, issuer
checked) and takes the user from the token. Only user-service can mint tokens; order-service
can only check them. The old secret remains in git history, but nothing accepts HMAC tokens
any more.

### 3.3 `PRIVATE_KEY` vs `PRIVATEKEY`

Spring maps environment variables to properties by turning `_` into `.` and dropping dashes.
`spring.ssl.bundle.pem.kafka.keystore.private-key` is therefore
`SPRING_SSL_BUNDLE_PEM_KAFKA_KEYSTORE_PRIVATEKEY`; `..._PRIVATE_KEY` would bind to a
non-existent `private.key` and silently do nothing. Verified with a test that binds the real
environment variables before the chart relied on it. Same for
`APP_NOTIFICATIONS_SIMULATEDFAILURERATE`.

### 3.4 Three of everything doesn't mean zone-proof

Three controllers and three brokers, but the VPCs span **two** zones, so pods spread 2+1.
Losing the zone with two controllers loses the KRaft quorum: Kafka stops (no data lost) until
the zone returns. Replication factor 3 over two zones also leaves one zone holding two of each
partition's replicas. Surviving a zone outage needs three zones — a tf change
(`private_app_subnet_cidrs`), recorded as an exercise.

### 3.5 Terraform kept deleting the database password

`module "secrets"` manages `microservices/<env>/app-config` and writes only `REDIS_HOST` and
`REDIS_PORT`. The ExternalSecret for the services also reads `MONGO_URI` from it — which
therefore had to be added by hand, and every `terraform apply` overwrote the secret and
dropped it; staging and prod's ExternalSecrets didn't ask for it at all. Credentials now live in
secrets Terraform creates empty (`out_of_band`), with values set by `scripts/set-secret.sh`, so
they never enter Terraform's state either. The token-signing key follows the same pattern.

### 3.6 Credentials in the wrong namespace

Strimzi issues a KafkaUser's certificate as a Secret in the Kafka namespace, and the cluster
CA lives there too; a pod can only mount Secrets from its own namespace. Copying them by hand
breaks at the first automatic renewal. The Access Operator's `KafkaAccess` resource keeps a
complete connection Secret in the service's namespace and updates it when Strimzi renews.

### 3.7 The lab installed the services before their Secrets existed

The lab sync installed our charts (with `--wait`) before applying `apps/local`, where the
KafkaAccess resources are; the services waited for Secrets that couldn't appear yet. The sync
now runs add-on charts, then the Git directories, then our charts, and installs the Strimzi
operator right after Prometheus, as the Access Operator needs its CRDs.

---

## 4. Verify — the full sequence

```bash
# Repo checks: renders, schemas (also from the Strimzi CRDs), 8 Kafka alert tests
cd gitops && ./scripts/validate.sh

# Lab or dev
kubectl get kafka,kafkanodepool,kafkatopic,kafkauser -n kafka      # all Ready
kubectl get kafkaaccess,secret -n development | grep kafka         # 3 KafkaAccess, 3 Secrets
kubectl logs -n development deploy/notification-service | grep partitions   # assigned

# Produce: sign in and create an order (gitops docs/KAFKA.md "Try it"), then
kubectl logs -n development deploy/notification-service | grep notification_sent

# Consumer group and lag, from the admin pod
kubectl apply -f gitops/streaming/tools/kafka-admin.yaml
kubectl exec -it -n kafka kafka-admin -- bash -c 'bin/kafka-consumer-groups.sh $ADMIN --describe --group notification-service'
kubectl delete -f gitops/streaming/tools/kafka-admin.yaml

# dev: lose a broker while producing; no failed publishes, alert comes and goes
kubectl delete pod -n kafka events-broker-0
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| `Kafka` not Ready, pods Pending | no node in a zone that has room (`DoNotSchedule` zone spread), or a PVC that can't bind |
| Service pod `CreateContainerConfigError` | its KafkaAccess Secret doesn't exist yet (Kafka still starting, or the KafkaUser isn't Ready) |
| `TopicAuthorizationException` in a service | the KafkaUser's ACLs don't allow that topic/operation (`users.yaml`) |
| `SSLHandshakeException` / `PKIX path` | an old CA in the service's Secret after a CA renewal: the Access Operator updates it; restart the pod |
| order created but no notification | publishing is off (`kafka.enabled`), the publish failed (`order_events_total{outcome="failed"}`), or the record is in `orders-dlq` |
| notification-service won't scale past 6 | by design: 6 partitions in `orders` |
| user-service won't start: `Could not resolve placeholder 'JWT_SIGNING_KEY'` | the `jwt-signing-key` secret has no value yet (`scripts/set-secret.sh <env> jwt-signing-key`) |
| order-service answers 401 to everything | old user-service image (HMAC tokens): deploy both together |

---

## 6. Exercise

1. On dev, kill a broker during a burst of orders and prove no event was lost (count orders
   vs `notification_sent` lines). Then scale notification-service to 8 and find the two idle
   consumers.
2. Add a third availability zone to dev's VPC (`private_app_subnet_cidrs`, one more subnet),
   watch Strimzi spread the pods 1+1+1, then stop a whole zone's nodes and see Kafka keep
   running.
3. Write a replay tool: read `orders-dlq` from the admin pod and produce each record back to
   `orders` with its original key. Why must the consumer be idempotent before you run it?
4. Change `orders` to 12 partitions. Which existing order IDs now land in a different
   partition, and why does that matter for ordering?
