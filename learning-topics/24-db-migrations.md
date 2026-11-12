# Topic 24 — Database migrations without downtime

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `24-db-migrations`. Nothing in this repo changes: the databases are the
services' MongoDB (Atlas in the cloud, the lab's own in KinD). In the app: user-service's
migrations, its `Migrate` command, the lint. In gitops: the Job that runs them before each
release, its network policy, the alert. The user guide is `gitops/docs/MIGRATIONS.md`.

---

## 1. The concept

- **Migrations are code.** Versioned files, applied in order, once, by a tool that records
  what it applied (Flyway's `flyway_schema_history`). Nobody changes a database by hand;
  an applied migration is never edited, the next one corrects it.
- **Where they run decides what can go wrong.** At service startup: replicas race. Init
  container: the same, on every restart. CI: CI needs every database's credentials and
  network. A Job before the rollout: once, inside the environment, and a failure stops the
  release.
- **Two versions at once.** During a rollout, and after a rollback, version N and N+1 run
  against one schema. Every schema change must work for both.
- **Expand-contract.** Add the new beside the old, backfill, switch reads, stop writing the
  old, remove it: one release each, each safe to roll back.
- **Locks and load.** Relational: `ALTER TABLE` can block writes. MongoDB: index builds
  lock briefly at start and end and load the primary; validators can reject writes; big
  updates fill the oplog.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| app `user-service/db/migration` | `V1__tasks_by_owner_index.json` (+ `.conf`: outside a transaction), `V2__tasks_details_backfill.json` |
| app `user-service/.../migrations/Migrate.java` | Flyway 13.12.1 with `flyway-database-nc-mongodb` and the verb plugins; `migrate`, `info`, `repair`; baseline at 0; credentials out of the logged address |
| app `user-service/.../model/Task.java` | Expand stage of `description` → `details`: writes both, reads `details` first |
| app `user-service/src/test/.../migrations/` | `MigrationLint` and its tests; Jenkins' *Check migrations* stage runs them |
| app `user-service/Dockerfile` | `/app/db/migration` beside `app.jar` |
| gitops `apps/base/user-service/migrations.yaml` | ServiceAccount (wave -2), Job (Sync hook, wave -1, BeforeHookCreation, backoffLimit 0) |
| gitops `apps/base/network-policies.yaml`, `apps/local/mongodb.yaml` | The Job's egress to MongoDB; the lab's MongoDB admits it (policy and mesh) |
| gitops `observability/base/migration-alerts.yaml` | `DatabaseMigrationFailed` |

---

## 3. Real incidents

All found while building the step, against a real MongoDB 7.0 replica set (podman) before
anything was committed.

### 3.1 The tool and the database didn't match

The roadmap says Flyway or Liquibase; the services use MongoDB. Liquibase 5 moved to a
source-available licence; Mongock (in-app) runs at startup, which is the race this step
avoids. Flyway 13's MongoDB connector (open source, Maven Central) fits: JSON migrations,
transactions where MongoDB allows them.

### 3.2 An official image for the wrong CPU

`redgate/flyway:13.12.1(-mongo)` exists for amd64 only; the lab runs on arm64 (Apple
silicon). Instead, Flyway's jars from Maven Central go into the service's own image, which
is built for whatever the machine is, and a small `Migrate` main class runs them. Bonus:
the migrations and the service can't have different tags.

### 3.3 Four dependency surprises

Each one only showed up by running it:

1. *"Native Connectors for migrate is set but no verb is present"*: the connector's
   commands are separate artifacts (`flyway-verb-migrate`, `-validate`, `-info`,
   `-baseline`, `-repair`, `flyway-nc-scanners`).
2. `NoClassDefFoundError: JsonSerializeAs`: Flyway needs newer Jackson annotations than
   Spring Boot 3.4's. Raised that one artifact only (annotations, compatible upward).
3. The MongoDB driver stays at Spring Boot's 5.2.1 (Flyway asks for 5.6.1): works for
   what Flyway does; recheck when upgrading either.
4. The failure message was only the file's path: the connector can't read migrations from
   inside Spring Boot's nested jar. They're files in the image now (`/app/db/migration`).

### 3.4 A database with data and no history

`Found non-empty schema(s) microservices but no schema history table`: the lab's and dev's
databases predate the migrations. `baselineOnMigrate` with `baselineVersion 0` starts their
history below V1, so every migration still runs.

### 3.5 An index can't be built in a transaction

`Command failed with error 263 (OperationNotSupportedInTransaction): Cannot create new
indexes on existing collection ... in a multi-document transaction`. JSON migrations run in
one by default; `V1__…json.conf` with `executeInTransaction=false` runs that one outside.
The lint now requires that for every `createIndexes`.

### 3.6 A migration that failed halfway

A unique index over duplicate data, outside a transaction: Flyway records version 3 as
failed (`success: false`), the index isn't left behind, and the next run refuses
(`Detected failed migration to version 3`). Fix the data, `repair`, `migrate`: done. This is
the runbook.

### 3.7 PreSync would have locked itself out

A PreSync hook runs before anything in the sync is applied, so the first time, its own
NetworkPolicy wouldn't exist yet and the namespace's default-deny would block it. A Sync
hook in wave -1, with its policy, account and the app Secret in wave -2, has the same
"before the new pods" guarantee.

### 3.8 Merging the whole rename at once would have broken it

Expand, switch and contract written in one go and merged together deploy as one release:
the contraction removes `description` while pods of the previous version still read it.
Only the expand stage is in the code; the rest are separate releases (the exercise).

---

## 4. Verify — the full sequence

```bash
cd app/user-service && ./gradlew test     # Task's mapping, Migrate, MigrationLint
cd gitops && ./scripts/validate.sh       # the Job in every overlay, policies, the alert test

# Against any MongoDB replica set
MONGO_URI='mongodb://localhost:27017/microservices?replicaSet=rs0' \
MIGRATIONS_LOCATION=filesystem:db/migration \
  java -Dloader.main=com.example.demo.migrations.Migrate -cp build/libs/demo-0.0.1-SNAPSHOT.jar \
  org.springframework.boot.loader.launch.PropertiesLauncher info

# Lab or dev, after a sync
kubectl -n development logs job/user-service-migrations
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| Sync stuck at the Job, pod `ImagePullBackOff` in the lab | the image wasn't loaded into KinD (`scripts/build-and-push.sh`) |
| Job: `MongoTimeoutException` | NetworkPolicy (`user-service-migrations`) or, in the lab, MongoDB's mesh policy doesn't admit the Job's ServiceAccount |
| Job: `Validate failed: ... checksum mismatch` | an applied migration was edited: put it back, write a new one |
| Job: `Detected failed migration` | an earlier non-transactional failure: MIGRATIONS.md, when a migration fails |
| Job: error 263 | a `createIndexes` without its `.conf` (the lint should have caught it) |
| The Job runs on every sync | by design (hooks run per sync); an up-to-date database makes it a no-op |

---

## 6. Exercise

1. **Finish the rename.** Release 2: `getDescription()` returns `details` only. Release 3:
   `setDescription()` stops writing `legacyDescription`, and the field goes. Release 4:
   `V3__contract_tasks_description.json`, an `update` with `$unset` (the lint allows it
   only with `contract_` in the name). Deploy each, wait for it everywhere, keep the
   request loop running.
2. **Rename a queried field.** `ownerUsername` → `owner`: the index and the query must
   cover both names during the transition (`$or`, two indexes), then drop the old index in
   the contract step. Compare with the field above.
3. **Unique users.** Make `users.username` unique: first find and resolve duplicates (a
   report migration can't do that: decide what happens to them), then the index.
4. **Batch a backfill.** Rewrite V2 for a hundred million tasks: in batches, from a Job of
   its own, without filling the oplog; how do you know when it's done?
5. **PostgreSQL.** For Unleash's database (step 23), where Unleash runs its own migrations
   at startup: what would you change to move them to a Job like this one, and what does
   `ALTER TABLE ... ADD COLUMN ... DEFAULT` lock in PostgreSQL 17?
