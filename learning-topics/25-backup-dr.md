# Topic 25 — Backups you've actually restored

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

Roadmap step `25-backup-dr`. In this repo: `modules/backup` (AWS Backup), `modules/state-bucket`
(the Terraform state buckets, from shared-services), 01-infra `backup.tf` (AWS Backup on/off,
Velero's bucket and role), the `velero-repository` secret and `set-secret.sh`. In gitops:
Velero, the lab's store, the hooks, the monthly drill, the alerts. Guide:
`gitops/docs/BACKUP-DR.md`; runbook: `gitops/docs/runbooks/disaster-recovery.md`.

---

## 1. The concept

- **RPO and RTO.** How much data a loss may cost (recovery point objective), how long until
  it works again (recovery time objective). Chosen per component; they decide the tool, the
  schedule and the cost.
- **The restore is the deliverable.** A backup job that succeeds proves only that it ran.
  Restore drills, timed, are what tell you the RPO and RTO you actually have.
- **3-2-1, and separation.** Several copies, more than one kind of storage, one somewhere
  else. A backup that lives with what it protects (same cluster, account, region) dies with
  it.
- **Immutability.** Ransomware and mistakes delete backups too: versioning, vault lock,
  object lock, a separate account.
- **Consistency.** A volume copied while a database writes is a crash at best: quiesce, dump,
  or snapshot point-in-time.

---

## 2. This repo's actual implementation

| Where | What |
|---|---|
| `modules/backup` | Vault (optional lock: governance or compliance after a grace period), IAM role with AWS's backup and restore policies, plan (daily 35 days, monthly a year, optional copy to another vault), selection of RDS/EBS/EFS by tag `Backup=daily`, SNS notifications; 5 tests |
| `modules/state-bucket`, shared-services `module.state_bucket` | Versioning, noncurrent versions 90 days (newest 20 always), SSE, public access block, owner-enforced; for every bucket in `terraform_state_bucket_names`; 3 tests |
| 01-infra `backup.tf` | `enable_aws_backup` (off), `enable_velero` (on in dev): Velero's bucket (versioned, 14-day noncurrent, SSE, private) and IRSA role `velero` for ServiceAccount `velero/velero-server` |
| 01-infra `main.tf` | Tags `Backup=daily` on the RDS instance (`rds_extra_tags`) and the shared EFS; secret `microservices/<env>/velero-repository` |
| `scripts/set-secret.sh <env> velero-repository` | Generates Velero's repository password; refuses to replace one |

---

## 3. Real incidents

All found by running the drill on a KinD test cluster (podman) before committing.

### 3.1 A read-only file system the backup tool needed

The hardened Velero (`readOnlyRootFilesystem`) failed every volume backup: *mkdir
/home/cnb/udmrepo: read-only file system*. Kopia keeps its repository settings and cache in
the user's home. Fix: an `emptyDir` mounted at `/home/cnb`, the rest stays read-only.
Hardening is right; testing it is what makes it right.

### 3.2 "Completed", with none of the data

The next backup was *Completed* with two warnings: *Volume data in pod
development/mongodb-0 is a hostPath volume which is not supported for pod volume backup,
skipping*. KinD's local-path provisioner makes `hostPath` volumes by default. The lab's
storage classes now carry `defaultVolumeType: local` (an annotation, changeable in place;
a `volumeType` *parameter* does nothing there, tried first), and the next backup copied
MongoDB's 315 MB and PostgreSQL's 48 MB. Existing lab volumes stay hostPath until recreated.

### 3.3 Encryption with a password everyone has

Velero encrypts its Kopia repositories with the password in Secret
`velero-repo-credentials`, and creates that Secret, with a fixed default, when it's missing.
Now generated: Secrets Manager in the cloud (`set-secret.sh`, which refuses to overwrite it,
since every backup needs the password it was made with), `start-lab.sh` in the lab.

### 3.4 An immutable StorageClass

Tagging `gp3-retain`'s volumes for AWS Backup changes its `parameters`, which Kubernetes
refuses to update. The class now carries ArgoCD's `Force=true,Replace=true`: deleted and
recreated, which leaves existing volumes alone.

### 3.5 Locking a database to copy it

`db.fsyncLock()` makes MongoDB's files consistent, but if the unlock hook never runs, the
database refuses writes until someone notices. Dumps instead (`mongodump`, `pg_dump` into the
volume, before it's copied): consistent, and harmless if anything fails.

### 3.6 A drill that would have run the services twice

Restoring the backup into scratch namespaces to test it would start copies of every
service: Kafka consumers in the same groups (stealing messages), KEDA scaling them up, Kong
serving their routes. The drill restores with a resource modifier (replicas 0 for
Deployments, StatefulSets, Rollouts) and leaves out pods, jobs, routes, scalers, Kong
consumers and Kafka access requests. Tested: 15 objects, 0 pods, 2 seconds.

### 3.7 Measured

Both namespaces deleted (16 s), restored from the backup, databases primary and data
verified (500 tasks, 200 rows): **21 seconds** from starting the restore. Lab-sized data
(~360 MB); the cloud's will be slower (snapshot data download), and must be measured there.

---

## 4. Verify — the full sequence

```bash
cd tf/modules/backup && terraform init && terraform test        # 5 passed
cd tf/modules/state-bucket && terraform init && terraform test  # 3 passed
cd gitops && ./scripts/validate.sh                              # Velero renders, the store's policies, the alert tests

# lab or dev
velero backup-location get                       # Available
velero backup create t --from-schedule velero-daily-apps --wait
velero backup describe t --details               # every database volume under pod volume backups
# the full drill: gitops docs/runbooks/disaster-recovery.md
aws s3api get-bucket-versioning --bucket dev-602367507570-us-east-1-an   # Enabled, after applying shared-services
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| BackupStorageLocation `Unavailable` | the bucket's name or region; the IRSA role not on `velero-server`; in the lab the store's keys or its NetworkPolicy |
| Backup `PartiallyFailed`: *read-only file system* | Velero without its `/home/cnb` volume |
| Backup `Completed` with *hostPath volume ... skipping* | a volume made before the lab's classes changed: recreate it |
| Restore: *error to connect to repository ... password* | `velero-repo-credentials` differs from the one the backup was made with |
| `set-secret.sh ... velero-repository` refuses | it has a value: replacing it orphans every backup (FORCE=1 only after deleting them) |
| AWS Backup job `FAILED`: not authorized | the vault's KMS key policy, or the resource's own key, doesn't let the backup role use it |
| ArgoCD can't update `gp3-retain` | its parameters changed: the class needs `Force=true,Replace=true` |

---

## 6. Exercise

1. **The cluster is gone.** On dev: destroy and recreate the cluster (keep the bucket and
   the password), restore `feature-flags`, time it, fill in the runbook.
2. **RDS point in time.** Restore Unleash's database to five minutes ago into a new
   instance (runbook); time request → available.
3. **Off-cluster in the lab.** Run SeaweedFS as a podman container outside KinD, point the
   lab's backup location at it, delete the KinD cluster, restore into a new one.
4. **Cross-region.** A second vault in another region, `backup_copy_to_vault_arn`; restore a
   copied recovery point there.
5. **Object Lock and Velero.** Turn on S3 Object Lock (governance, 7 days) on Velero's
   bucket with backups kept 7 days. What happens when Velero expires a backup early, and
   how would you set it up so they agree?
6. **Your RPO.** Is a day right for Unleash's flags? For orders? What would an hourly
   schedule cost, and what would continuous (RDS PITR, Atlas continuous) give instead?
