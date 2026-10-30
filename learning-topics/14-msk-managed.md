# Topic 14 — Amazon MSK: the managed alternative

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `14-msk-managed`. In this repo `modules/msk` and `01-infra/msk.tf` (off by
default); in gitops the chart's MSK mode, `apps/components/kafka-msk` and `msk/`; in the app
repo the login module. The comparison and the switch-over steps are
`gitops/docs/msk-vs-strimzi.md`.

---

## 1. The concept

- **Managed versus self-hosted** is a trade of money for work. A managed service bills for
  the capacity and the operations it takes off you (patching, upgrades, failure handling,
  capacity planning); self-hosting bills less and costs engineering time. Compare both with
  numbers, including people's time, not by preference.
- **MSK comes in three shapes.** Provisioned (you pick broker sizes and count; AWS runs
  them), Express brokers (provisioned, faster scaling and recovery), and **Serverless** (no
  brokers at all: per-cluster, per-partition and per-GB pricing, automatic scaling within
  quotas, fewer settings). Serverless is the cheapest way to try MSK for a few hours.
- **IAM authentication.** Instead of Kafka users, a client signs a sign-in request with AWS
  credentials (SigV4) over the `AWS_MSK_IAM` SASL mechanism, and IAM policies with
  `kafka-cluster:*` actions on cluster, topic and group ARNs replace Kafka ACLs. In
  Kubernetes the credentials come from IRSA.
- **Portability as a design goal.** If the services read their Kafka connection from
  configuration, switching providers is a deployment change. Here that holds except for one
  library (the login module), added once.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `modules/msk` | `aws_msk_serverless_cluster` with IAM authentication, endpoints in the private app subnets, a security group allowing only 9098/tcp from the pod subnets and no egress; outputs bootstrap servers and the topic and group ARN prefixes |
| `modules/msk/tests/msk.tftest.hcl` | `terraform test` with a mocked AWS provider: IAM on, ARN prefixes, the single ingress rule, at least two subnets |
| `01-infra/msk.tf`, `enable_msk` (off), `msk_client_namespace` | The module, and IRSA roles `msk_order_service`, `msk_user_service`, `msk_notification_service` (each its own topics and group, as its `KafkaUser` on Strimzi) and `msk_admin` (topics only, namespace `msk-admin`) |
| outputs `msk_bootstrap_brokers`, `msk_cluster_arn` | What gitops needs to switch over |
| gitops `charts/microservice` 0.3.0 | `kafka.msk.bootstrapServers` sets SASL_SSL with `AWS_MSK_IAM` instead of the Strimzi certificate; `serviceAccount.annotations`; refuses MSK mode without an IRSA role; 4 new unit tests |
| gitops `apps/components/kafka-msk`, `tests/kustomize/apps-msk` | The same for user-service, from a ConfigMap the environment adds; a validation-only overlay renders it |
| gitops `msk/topics-job.yaml` | Creates the topics with Kafka's CLI and the login module, as `msk-admin` |
| app `build.gradle` ×3, `MskIamSettingsTest` ×3 | `aws-msk-iam-auth` 2.3.9 (runtime only); each test binds the chart's environment variables and builds a client with them |
| app `kafka-connect/Dockerfile` | The module's all-in-one jar on Kafka's classpath (pinned by checksum), so the image's CLI works against MSK |

---

## 3. Real incidents

### 3.1 A disabled feature still broke the plan

The IRSA roles are filtered out with `{ for k, v in {...} : k => v if var.enable_msk }`, but
Terraform builds the whole inner map before filtering, so the policies are evaluated even
when MSK is off. Referring to `module.msk[0].topic_arn_prefix` there fails with "Invalid
index" when the module has count 0, and `"${null}/orders"` fails too. The ARNs come from
`try(module.msk[0]..., "")`: empty strings in policies that are then thrown away. The
events archive in step 13 dodged the same trap by building its ARN from the bucket's name.

### 3.2 A JSON schema only one parser accepted

The script that edited the chart's values schema wrote a pattern as `"[^\s,:]"`, an escape
JSON doesn't have. Ruby's JSON parser accepted it; Helm's refused it ("invalid character 's' in
string escape code") and every chart test failed at once. The pattern now has no
backslashes (`[^ ,:]`), and the file is checked with a strict parser. Lesson: check
generated files with the tool that will consume them.

### 3.3 The test that needed DNS

The services' MSK test first built a Kafka producer pointing at a made-up MSK host name, and
failed with "No resolvable bootstrap urls": a Kafka client resolves its bootstrap hosts when
it is created. The test checks the bound settings with the MSK name, then builds the client
against `localhost:9098`. The client is never started, but building it still parses the JAAS
line and loads the callback handler class, which is what the test is for.

### 3.4 A component can't read what its overlay generates

The first idea for user-service was a `configMapGenerator` in the environment holding the
bootstrap servers and role ARN, read by the `kafka-msk` component's replacement. Kustomize
runs components before the overlay's own generators, so the ConfigMap wouldn't exist yet.
The environment adds it as a plain resource (`kafka-msk.yaml`) instead, which is loaded
before components; `tests/kustomize/apps-msk` proves the result renders.

---

## 4. Verify — the full sequence

```bash
# Without AWS
cd tf/modules/msk && terraform init -backend=false && terraform test      # 3 passed
cd tf/infrastructure/app-cluster/01-infra && terraform validate
cd gitops && ./scripts/validate.sh            # apps-msk overlay, msk/topics-job.yaml, chart tests
cd app/order-service && ./gradlew test --tests '*MskIamSettingsTest'

# With MSK on (docs/msk-vs-strimzi.md, "Try it")
terraform output msk_bootstrap_brokers
kubectl logs -n msk-admin job/msk-topics       # the four topics, replication 3
kubectl logs -n development deploy/order-service | grep -i 'sasl\|msk'   # no authentication errors
aws cloudwatch list-metrics --namespace AWS/Kafka --dimensions Name=Cluster\ Name,Value=microservices-dev-events
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| `SaslAuthenticationException: Access denied` | the pod has no IRSA role (annotation missing, or the chart refused to render it) or the role's trust names another ServiceAccount/namespace (`msk_client_namespace`) |
| `TopicAuthorizationException` | the role lacks the action on that topic ARN (`msk.tf`), or the topic name differs |
| `ClassNotFoundException: software.amazon.msk.auth.iam.IAMClientCallbackHandler` | an image built before the login module was added |
| connection timeouts to `*.kafka-serverless.*:9098` | the security group: the pod's address isn't in `client_cidr_blocks` |
| the topics Job fails with `InvalidConfigurationException` | a setting MSK Serverless doesn't allow (only six topic settings are configurable) |
| no consumer lag in CloudWatch | the group is rebalancing or has never committed an offset; lag appears for stable groups |

---

## 6. Exercise

1. Run the switch-over for an afternoon and measure: orders created, events published,
   notifications sent, and the bill in Cost Explorer the next day against
   `msk-vs-strimzi.md`'s estimate.
2. Write a CloudWatch alarm on `EstimatedMaxTimeLag` for notification-service's group, the
   MSK counterpart of `KafkaConsumerLagHigh`.
3. Replace the topics Job with the `Mongey/kafka` Terraform provider (it supports IAM). Where
   must Terraform run for that to work, and what does that mean for Jenkins?
4. Move the schema registry's storage off Strimzi so the cluster could be removed entirely:
   what would Apicurio need to reach MSK, and how does AWS Glue Schema Registry compare?
