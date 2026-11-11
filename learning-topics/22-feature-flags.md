# Topic 22 — Feature flags with Unleash

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `22-feature-flags`. In this repo: the empty secret `microservices/<env>/unleash`
(01-infra main.tf, `out_of_band`) and `scripts/set-secret.sh <env> unleash`, which generates
its values. In gitops: Unleash and PostgreSQL (`feature-flags/`), the routes, policies and the
services' tokens. In the app: the frontend's flag and order-service's kill switch. The user
guide is `gitops/docs/FEATURE-FLAGS.md`.

---

## 1. The concept

- **Deploy is not release.** A deploy changes what runs; a flag decides what users get. Code
  ships dark, and a feature reaches some users, a share of them or everyone, and goes away
  again, without a deploy.
- **Kinds of flag.** Release (short-lived), experiment (until decided), operational / kill
  switch (permanent), permission (long-lived). The kind decides the default and the lifetime.
- **Fallbacks are a design decision.** Every check says what to do when the flag service
  can't answer: the safe side of *that* flag, which differs per flag.
- **Server-side and client-side.** A backend SDK fetches all rules and decides locally (its
  token is secret). A frontend asks which flags are on for one user (its token is public: every
  browser has it).
- **Flag debt.** Each flag is a code path; remove release flags soon after they reach 100%.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `01-infra/main.tf` `out_of_band["unleash"]`, `scripts/set-secret.sh <env> unleash` | An empty Secrets Manager secret; the script fills it with four random values (database and admin passwords, backend and frontend token secrets), never shown, never in state |
| gitops `feature-flags/base` | Unleash 8.3.1 (`BASE_URI_PATH=/flags`, tokens and admin from `INIT_*` and `UNLEASH_DEFAULT_ADMIN_*`, no telemetry), PostgreSQL 17.11 (StatefulSet, 2 GiB), the frontend-API route, default-deny policies, ServiceMonitor |
| gitops `feature-flags/dev`, `apps/dev/unleash-tokens.yaml` | ExternalSecrets composing `default:development.<secret>` tokens from that one secret, in two namespaces |
| gitops `scripts/start-lab.sh` | The same in the lab, from a git-ignored `apps/local/unleash.env` |
| app `frontend` | `@unleash/proxy-client-react` 6.0.1; `/config/runtime-config.json` from the cluster; `dashboard-task-summary` |
| app `order-service` | `unleash-client-java` 12.3.2; `order-events-publishing` gates the outbox relay; gauge `order_events_publishing` |

---

## 3. Real incidents

All found while building the step; none on a cluster yet.

### 3.1 One secret, two namespaces

Unleash must know the services' tokens (it creates them on first start) and the services
must hold them: the same value in namespaces `feature-flags` and `development`. External
Secrets' password generator makes a new value for each ExternalSecret, so it can't share one.
The repo's existing pattern fits: Terraform creates the secret empty, `set-secret.sh`
generates the values once, and an ExternalSecret in each namespace reads them, composing the
`<project>:<environment>.<secret>` form Unleash expects with a template.

### 3.2 The official chart lags the server

Unleash's Helm chart (5.6.9) still ships Unleash 7.5 and a Bitnami PostgreSQL subchart, while
the server is at 8.3.1 with security fixes (an IDOR, an XSS, an SSRF-guard bypass in 8.3.0),
and needs PostgreSQL 15 or later. Two plain manifests (a Deployment, a StatefulSet) with the
pinned images were simpler than overriding the chart into shape.

### 3.3 A kill switch that killed on its own

The natural code is `isEnabled("order-events-publishing")`, which is *false* when Unleash
hasn't answered yet, doesn't know the flag, or isn't there at all: a new pod, or an
environment without Unleash, would have stopped publishing. The check is
`isEnabled(flag, true)`: the kill switch kills only when someone switches it off. The
unreleased feature's fallback is the opposite: off.

### 3.4 Per-environment config in a static image

The frontend's flag client needs the environment's URL and token. Baked in at build time,
the image would differ per environment (and no longer be the one tested). The cluster serves
it instead, from a Secret mounted into nginx's web root at `config/`; optional, so an
environment without Unleash simply has no file and every flag is off.

### 3.5 A required token that would have stopped the service

order-service first read its token with an ordinary `secretKeyRef`: in a lab where
`start-lab.sh` hadn't run since this step, the pod would never have started. The reference is
optional; without a token the flag client is refused, logs it, and the fallbacks apply.

---

## 4. Verify — the full sequence

```bash
cd gitops && ./scripts/validate.sh            # feature-flags/<env>, the policies, the alert test
cd app/order-service && ./gradlew test         # kill switch, fallbacks
cd app/frontend && npm test && npm run build   # runtime config loading

# Lab or dev
kubectl get pods -n feature-flags
kubectl -n feature-flags port-forward svc/unleash 4242:4242     # http://localhost:4242/flags
curl -s -H "Authorization: <frontend token>" localhost/flags/api/frontend   # through Kong: the flags on for no one in particular
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| Unleash crash-loops on start | PostgreSQL not ready, or its password differs from Secret `unleash` (the secret was regenerated after PostgreSQL's first start) |
| order-service logs 401 from Unleash | the backend token Unleash created on its first start differs from `unleash-backend-token` (same cause) |
| the frontend never shows the summary | no `/config/runtime-config.json` (Secret `frontend-runtime-config` missing), the flag not enabled in *development*, or the browser's user outside the rollout |
| flipping the kill switch does nothing | order-service has no `UNLEASH_URL` (an environment without Unleash), or the flag is in another environment than its token's |
| `OutboxBacklogGrowing` fires | the kill switch is off: expected, turn it back on |

---

## 6. Exercise

1. Put the frontend behind OpenFeature's web SDK with Unleash's provider, so changing flag
   vendors means changing one provider.
2. Remove the release flag: when the summary has been at 100% for two weeks, delete the
   check and archive `dashboard-task-summary`; note what else had to change.
3. Back up Unleash's database nightly with Argo Workflows (step 21): `pg_dump` to the
   workflow artifact bucket, and a restore test into a scratch database.
4. Try flagd: the same two flags as a ConfigMap, the same SDKs through OpenFeature; compare a
   flag change by commit with a flag change by click.
