# Topic 06 — Persistent Storage: EBS CSI, StorageClasses, StatefulSets, S3

See `01-vpc-peering.md` for how this folder works. Same structure here: Concept → this
repo's implementation → real incidents → verify → troubleshooting → exercise.

This is roadmap step `05-storage-statefulsets` (`LEARNING-ROADMAP.md` §05), across `tf`
(the EBS CSI driver, S3 buckets, IRSA) and `gitops` (StorageClasses, the lab's MongoDB
StatefulSet, the monitoring stack's volumes).

---

## 1. The concept

- **PVC → StorageClass → PV.** A pod asks for storage with a *PersistentVolumeClaim*; the
  claim names a *StorageClass*; the class's *provisioner* creates the actual disk (a
  *PersistentVolume*). No provisioner, no disk: the PVC sits `Pending` forever.
- **On EKS the provisioner is the EBS CSI driver.** Since Kubernetes 1.23 every EBS request
  goes through it, and EKS doesn't install it for you. It needs AWS permissions to create and
  attach volumes, so it runs with an IRSA role.
- **An EBS volume lives in one availability zone** and attaches to one node at a time
  (`ReadWriteOnce`). `volumeBindingMode: WaitForFirstConsumer` delays creating the volume
  until the pod is scheduled, so the volume is made in the pod's zone instead of a random one.
- **`reclaimPolicy`** decides what happens to the disk when its PVC is deleted: `Delete`
  removes it, `Retain` keeps it (and keeps billing for it) until someone removes it by hand.
  A `Delete` default on data with no other copy is how real companies have lost production
  databases.
- **StatefulSet vs Deployment**: stable pod names (`mongodb-0`), ordered start-up, and one PVC
  per pod from `volumeClaimTemplates` that follows the pod across restarts and reschedules.
- **Block storage vs object storage**: logs and traces at scale go to S3 (cheap, durable,
  unlimited); the pod's disk only holds the write-ahead log of what isn't uploaded yet.

---

## 2. This repo's actual implementation

**EBS CSI driver** — `tf/infrastructure/app-cluster/01-infra/main.tf`:
```hcl
irsa_roles = {
  ebs_csi_driver = {
    namespace       = "kube-system"
    service_account = "ebs-csi-controller-sa"
    policy_arns     = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  }
}

resource "aws_eks_addon" "ebs_csi_driver" {
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = coalesce(var.ebs_csi_driver_version, data.aws_eks_addon_version.ebs_csi_driver.version)
  service_account_role_arn = module.eks.irsa_role_arns["ebs_csi_driver"]
  depends_on               = [module.eks]   # its controller needs nodes to run on
}
```
The version defaults to AWS's default for the cluster version; `ebs_csi_driver_version` pins one.

**StorageClasses** — `gitops/platform/storage/storageclasses.yaml`, synced to every EKS cluster:

| Class | reclaimPolicy | Used by |
|---|---|---|
| `gp3` (default) | `Delete` | Alertmanager, Grafana, Loki and Tempo WAL disks, dev/staging Prometheus |
| `gp3-retain` | `Retain` | prod Prometheus (`addons/values/prod/kube-prometheus-stack.yaml`) — metrics have no other copy |

Both: `type: gp3`, `encrypted: "true"`, `WaitForFirstConsumer`, `allowVolumeExpansion: true`.
The kind lab defines its own `gp3` class on local disks (`local-setup/gp3-storageclass.yaml`),
so the same values work in both places.

**S3 for logs and traces** — one `for_each` over `{loki, tempo}` in `01-infra/main.tf`: private,
AES256-encrypted buckets named `<project>-<env>-<component>-storage-<account id>`, each readable
only by its own IRSA role (`loki`, `tempo`; ServiceAccounts in `02-services/main.tf`). The
lifecycle rule is a *safety net longer than the apps' retention* (45 and 30 days) — Loki's and
Tempo's compactors do the real deleting. `gitops/addons/values/<env>/{loki,tempo}.yaml` hold the
bucket names.

**A StatefulSet you can break safely** — `gitops/apps/local/mongodb.yaml` (kind lab): headless
Service + one-replica StatefulSet, `volumeClaimTemplates` of 2Gi, TCP probes.

---

## 3. Real incidents

### 3.1 Every cloud PVC would have stayed Pending

The cloud values asked for `storageClassName: gp3` (Prometheus, Alertmanager, Grafana, Loki,
Tempo), but no cloud cluster had a `gp3` class *or* the EBS CSI driver to back one. Nothing
failed loudly in Git — the monitoring stack would simply never have started. Found by reading
the values against `tf`. **Fixed:** tf `604c359` (driver), gitops `de214ec` (classes).

### 3.2 `terraform validate` failed on the branch

The Loki bucket used `merge(local.common_tags, …)`, but `01-infra` never declared `common_tags`
(only `modules/eks` has its own). **Fixed:** tf `4dce4d4`. Lesson: run `terraform validate` before
pushing, every time — `fmt` alone doesn't catch it.

### 3.3 S3 would have deleted logs Loki still needed

The bucket's lifecycle rule expired objects after 14 days; Loki keeps application logs for 30.
S3 would have removed chunks that Loki's index still pointed at. **Fixed:** tf `120c4fb` —
retention belongs to Loki's compactor; the lifecycle rule is now a longer safety net. The same
commit added Tempo's bucket, which the Tempo values expected but which didn't exist.

### 3.4 MongoDB restart loop, then a StatefulSet that wouldn't roll

The first lab MongoDB used `exec: mongosh --eval ping` probes. `mongosh` is a Node.js program and
takes longer than the probe's 1s timeout to start, so liveness kept failing and Kubernetes kept
killing a healthy database. Switching to `tcpSocket` probes fixed the manifest — but the pod
didn't pick it up: a StatefulSet's rolling update waits for the current pod to be Ready, and
this one never was. `kubectl delete pod mongodb-0` let the controller recreate it from the new
template, with the same PVC and data.

---

## 4. Verify — the full sequence

```bash
# Driver installed and healthy
aws eks describe-addon --cluster-name microservices-dev-eks-cluster \
  --addon-name aws-ebs-csi-driver --query 'addon.[addonVersion,status]'
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# Classes present, gp3 is the only default
kubectl get storageclass

# Every PVC Bound, volumes in the same zone as their pods
kubectl get pvc -A
kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,ZONE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]

# Data survives the pod (lab)
kubectl exec -n development mongodb-0 -- mongosh --quiet microservices --eval 'db.users.countDocuments()'
kubectl delete pod -n development mongodb-0
kubectl exec -n development mongodb-0 -- mongosh --quiet microservices --eval 'db.users.countDocuments()'  # same number

# Loki and Tempo are writing to S3
aws s3 ls s3://microservices-dev-loki-storage-602367507570/ --recursive | tail -3
```

---

## 5. Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| PVC `Pending`, event "no persistent volumes available" / no provisioner | EBS CSI addon missing or degraded; StorageClass name typo |
| PVC `Pending` after the pod moved zones | the volume is in another AZ; the pod needs a node in that zone |
| `AccessDenied` in `ebs-csi-controller` logs | IRSA role not on `ebs-csi-controller-sa`, or a customer-managed KMS key without KMS permissions |
| Loki/Tempo `AccessDenied` on S3 | ServiceAccount missing the `eks.amazonaws.com/role-arn` annotation, or bucket name in gitops ≠ tf |
| Volumes left in EC2 after `terraform destroy` | PVCs weren't deleted before the cluster: delete them (or the namespaces) first so the driver can clean up |

---

## 6. Exercise — close the loop on what's still open

1. Install the EFS CSI driver and an EFS filesystem (mount target per AZ), and mount one
   `ReadWriteMany` volume into two pods on different nodes. Explain when you'd want that.
2. Install the CSI snapshot controller, take a `VolumeSnapshot` of `mongodb-0`'s PVC, delete the
   StatefulSet *and* PVC, and restore from the snapshot.
3. Delete a PVC that uses `gp3-retain`, find the `Released` PV, and bind a new PVC to it.
