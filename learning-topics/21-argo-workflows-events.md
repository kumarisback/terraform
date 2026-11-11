# Topic 21 — Argo Workflows and Argo Events

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `21-argo-workflows-events`. In this repo: `01-infra/workflows.tf` (the artifact
bucket, the workflows' IRSA roles, the SQS queue announcing archive files). In gitops: the two
add-ons (`addons/automation`) and what they run (`automation/`). The user guide is
`gitops/docs/WORKFLOWS.md`.

---

## 1. The concept

- **A workflow is a graph of containers.** Each step is a pod; steps pass parameters and
  artifacts (files in an object store) or share a volume. Templates, retries, timeouts, exit
  handlers and parallelism are fields, not plugins.
- **Events start workflows.** Argo Events: an *EventSource* turns something outside (a Kafka
  record, an SQS message, a webhook, a schedule) into events on an *EventBus*; a *Sensor*
  waits for the events it depends on, filters them, and *triggers* something, usually a
  workflow, with fields of the event as its parameters.
- **Identity per workflow.** Steps run as a ServiceAccount; with IRSA, each kind of workflow
  gets exactly the AWS rights it needs, and no keys exist.
- **Not a CI product.** Argo Workflows runs pipelines well but knows nothing of pull requests,
  checks or repository caches. It shines at cluster-side work: reacting to the cluster's own
  events, checking data, batch jobs.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `01-infra/workflows.tf` (`enable_argo_workflows`, on in dev) | Bucket `<project>-<env>-workflow-artifacts-<account>` (TLS only, 30 days); IRSA roles `argo_workflow` (artifacts; reads the events archive), `ci_builder` (artifacts; push to `ci_push_repositories`), `archive_uploads_reader` (the queue); with `enable_events_archive`, SQS queue `<project>-<env>-archive-uploads` (4 days), its policy (only S3, only from the archive bucket) and the archive bucket's notification (`.jsonl.gz`) |
| gitops `addons/automation` | Argo Workflows 4.1.6 (chart 2.0.14), Argo Events 1.9.11 (2.4.27); lab and dev |
| gitops `automation/base` | `ci-build`, `dead-letter-triage` (+ Kafka EventSource and Sensor), CronWorkflow `slo-report`, JetStream EventBus, accounts, two NetworkPolicies, KafkaAccess |
| gitops `automation/dev` | `verify-archive-object` (+ SQS EventSource and Sensor); the IRSA annotations |
| gitops `streaming/base` | KafkaUser `argo-events` (read the dead-letter topics); `argo` among the listener's peers |
| gitops `observability/base/automation-alerts.yaml` | `ArgoWorkflowsControllerUnavailable`, tested |

---

## 3. Real incidents

All found while building the step; none on a cluster yet.

### 3.1 A Kafka client that spoke Kafka 1.0

Argo Events' Kafka event source leaves the protocol version to its client (sarama) unless
told, and sets it to Kafka 1.0 (`pkg/eventsources/sources/kafka/start.go`). Kafka 4, which
Strimzi runs here, removed every protocol version older than 2.1: the source would have
failed to connect. It now says `version: "3.6.0"`.

### 3.2 IRSA for SQS, documented nowhere

Argo Events' SQS page only shows access keys in a Secret. Its source code
(`pkg/eventsources/common/aws/aws.go`) shows that with no keys and no role ARN it makes a
session from the SDK's default credential chain, which includes IRSA's web identity token.
So the queue reader has a role and no keys exist. Checked in the code, not assumed.

### 3.3 Pasted parameters are code

The obvious way to use a parameter in a step is `{{inputs.parameters.x}}` inside the script.
Whoever controls the value controls the script: a dead-letter record's exception message, an
S3 key, a revision passed to the CI. Every value now arrives as an environment variable and is
treated as data; the revision must be 40 hex characters before anything runs.

### 3.4 A broader role than it said

The UI's account first got the chart's `argo-workflows-edit` role, which also rewrites
templates: anyone with its token could have changed what the CI pipeline runs. It now has a
role of its own (see, start, stop, retry, delete workflows; read templates). It still can't
be narrower than "may run pods as any account in the namespace", which creating a workflow
is; the guide says so.

### 3.5 The object store the roadmap suggested

The roadmap's lab plan uses MinIO; its community edition stopped shipping ready-made images
in 2025. Rather than run something unmaintained, the lab has no object store: its workflows
report through their results (the triage and the report are their workflow's output) and
logs; dev uses S3 with IRSA.

### 3.6 Checking a backup means reading it

The archive check could have counted objects. It reads each file: gzip that opens, a JSON
object per line with the connector's fields, values that decode, offsets that only rise and
start where the name says. Offset gaps aren't errors: transaction markers take offsets too.
Tested locally on a good file, a broken line and a misnamed file.

---

## 4. Verify — the full sequence

```bash
cd tf/infrastructure/app-cluster/01-infra && terraform init -backend=false && terraform validate
cd gitops && ./scripts/validate.sh             # charts, automation/<env> against the CRDs, the alert test

# Lab or dev
kubectl get pods,eventbus,eventsources,sensors -n argo
argo submit -n argo --from cronwf/slo-report --watch && argo get -n argo @latest
argo list -n argo --prefix dead-letter-triage          # after a poison record (docs/KAFKA.md, 3)

# dev
terraform output archive_uploads_queue
argo list -n argo --prefix verify-archive-object        # one per archive file
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| EventSource `dead-letters` crash-loops | the KafkaAccess Secret not there yet, `argo` missing from the listener's peers, or the protocol version unset |
| no triage workflow after a dead letter | the Sensor's account lacks `create` on workflows; `kubectl logs -n argo -l sensor-name=dead-letters` |
| `verify-archive-object` fails at its input artifact | the `argo_workflow` role lacks `s3:GetObject` on the archive (enable_events_archive off when the role was made) |
| the archive EventSource gets nothing | the bucket notification or the queue policy (`aws:SourceArn` must be the archive bucket) |
| `ci-build` fails at build | Pod Security forbids unconfined seccomp/AppArmor in `argo`, or the node's kernel lacks unprivileged user namespaces |
| `ci-build` fails at scan | a fixable HIGH or CRITICAL vulnerability: rebuild on a newer base image, or `-p failOnVulnerabilities=false` to see the report |
| the UI says 401 | a token from `kubectl create token workflow-operator -n argo`, prefixed with `Bearer ` |

---

## 6. Exercise

1. Add an exit handler to `ci-build` that records the image digest, or the failing step, as a
   Kubernetes event on the workflow.
2. Turn the event bus into Kafka: an EventBus with `kafka:`, its topic and each sensor's two
   topics as KafkaTopics, a KafkaUser for them; compare what it takes with JetStream's three
   pods.
3. Replace the Jenkins job for order-service: a GitHub webhook EventSource (behind the ALB,
   with its secret) starting `ci-build` on every push to `main`.
4. A nightly backup verification for the lab's MongoDB: a CronWorkflow running `mongodump`
   and restoring it into a scratch database, then counting documents.
