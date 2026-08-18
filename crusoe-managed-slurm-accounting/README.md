# Crusoe Managed Slurm Accounting

This solution adds slurm accounting (slurmdbd + MariaDB) on top of a Crusoe **Managed Slurm** cluster. Managed Slurm does not provision accounting by default — this repo's Helm chart (`chart/slurm-accounting/`) fills that gap.

## Prerequisites

### 1. Crusoe Managed Slurm cluster

You need a Crusoe Managed Kubernetes cluster with the following:
- Slurm CMK add-on
- Mecessary Compute Node Pools
- Access to the Kubernetes API
- SlurmCluster CR already created, with SSH key configured for root 

You can use `kubectl` to note the login LoadBalancer's external IP for later:

```bash
kubectl get svc -n slurm   # note the login LoadBalancer External IP
```

### 2. Tooling

- `helm` v3+
- `kubectl` matching (or close to) the cluster's Kubernetes version
- Cluster admin access — the chart creates a `StorageClass`, RBAC objects, and patches a cluster-scoped-adjacent `Controller` CR owned by the Crusoe operator.

## What the chart deploys

| Resource | Purpose |
|---|---|
| `StorageClass` (`ssd.csi.crusoe.ai`) | StorageClass for MariaDB using Crusoe Persistent Disk. |
| MariaDB `StatefulSet` + `Service` + `Secret` | The accounting database (`slurm_acct_db`). Credentials are auto-generated on first install and preserved across upgrades. |
| `Accounting` CR (`slinky.slurm.net/v1beta1`, aka slurmdbd) | The slurmdbd daemon, pointed at the MariaDB instance and reusing the cluster's existing auth secrets. |
| Pre-install/pre-upgrade Job + RBAC | Patches `spec.accountingRef` onto the existing `Controller` CR **before** the `Accounting` CR is created (ordering matters — see [Known issues](#known-issues) below). |

## Installation

```bash
cd chart/slurm-accounting

# Review/edit values.yaml first -- at minimum confirm:
#   clusterName, namespace, existingAuth.*, patchController.controllerName
helm lint .
helm install slurm-accounting . -n slurm --wait --timeout 5m
```

`--wait` blocks until the MariaDB StatefulSet and the patch Job report ready/succeeded. On a clean cluster this should complete in under two minutes.

The remaining steps below SSH into the login node as `root` (via the key in `rootSSHPubKeys`), since no `SlurmUser` exists yet.

### Post-install: Make slurmctld pick up accounting

Setting `accountingRef` updates the `Controller` CR, which the Crusoe
operator renders into the `slurm.conf` ConfigMap (`AccountingStorageType`,
`AccountingStorageHost`, etc.) almost immediately. However, you may need to restart `slurmctld` in order for it to get picked up.

```bash
# 1. Confirm the ConfigMap has the new setting
kubectl get configmap -n slurm <cluster-name>-config -o yaml | grep AccountingStorageType

# 2. Check whether the running slurmctld already picked it up
ssh root@<login-ip> "scontrol show config | grep AccountingStorageType"
# If this prints (null), slurmctld is still running on the old config.

# 3. Restart the controller pod to force a clean re-read of slurm.conf
kubectl delete pod -n slurm <cluster-name>-controller-0
kubectl get pod -n slurm <cluster-name>-controller-0 -w   # wait for 3/3 Running
```

### Register the cluster name with accounting

slurmdbd needs the cluster registered before it will store job records.
Do this as `root`, before any `SlurmUser` exists:

```bash
ssh root@<login-ip> "sacctmgr -i add cluster <cluster-name>"
```

## Set up accounts and users

The Crusoe `SlurmUser` CRD (`slurm.crusoe.ai/v1alpha1`) only manages the
OS-level identity (UID/GID, SSH keys, shell) — it has no concept of Slurm
accounting and cannot express an account association in YAML. Association
is always a separate `sacctmgr` step. Do the accounting setup as `root`
first, then add users last:

1. **Create the account(s) in accounting, as `root`:**

   ```bash
   ssh root@<login-ip> "sacctmgr -i add account <account-name> Description='<description>' Organization='<org>'"
   ```

   For a single-user/test cluster, the built-in `root` account is fine to
   use directly and this step can be skipped.

2. **Apply the `SlurmUser` CR** (see `user.yml` for an example) so the OS
   user exists and can SSH in:

   ```bash
   kubectl apply -f user.yml
   ```

3. **Add the user to accounting under that account** (still as `root`,
   or any user in the `slurm-admin` group):

   ```bash
   ssh root@<login-ip> "sacctmgr -i add user <username> Account=<account-name>"
   ```

   Repeat steps 2–3 for each additional user. Until step 3 runs for a
   user, their jobs still execute and still show up in `sacct` (accounting
   isn't enforced by default — `AccountingStorageEnforce=none`), just with
   an empty `Account` column and none of the account's limits applied.

Check the result:

```bash
ssh root@<login-ip> "sacctmgr show assoc format=Cluster,Account,User"
```

## Verification

```bash
ssh root@<login-ip> <<'EOF'
scontrol show config | grep AccountingStorage
sinfo
srun --nodes=1 hostname
sacct --format=JobID,JobName,Partition,State,ExitCode,Elapsed -X
EOF
```

Expected:
- `AccountingStorageType = accounting_storage/slurmdbd`
- The `srun` job appears in `sacct` output with `State=COMPLETED`

## Known issues

1. **Slinky operator panics if `Accounting` is created before
   `Controller.spec.accountingRef` is set.** The operator's
   `RefResolver.GetControllersForAccounting` hits a nil-pointer
   dereference when it processes an `Accounting` create event while any
   `Controller` in the namespace has no `accountingRef` set, crash-looping
   both operator replicas. This chart's patch Job runs as a
   **pre-install/pre-upgrade** hook — `accountingRef` must be set on the
   `Controller` *before* the regular `Accounting` template is applied. Do
   not change this to a post-install hook.

2. The chart defaults to the public upstream image `ghcr.io/slinkyproject/slurmdbd` at the matching Slurm version. If Crusoe later publishes their own slurmdbd image, override `accounting.image` in `values.yaml`.

3. **`CLUSTER ID MISMATCH` after restarting the controller pod.** This
   only happens if the controller's persistent `statesave` volume already
   has a `clustername` file from a *previous* accounting install (e.g. an
   earlier uninstall/reinstall cycle, or a restored volume snapshot) —
   it won't occur on a genuinely clean install. `kubectl logs -n slurm
   <cluster-name>-controller-0 -c slurmctld` will show:

   ```
   fatal: CLUSTER ID MISMATCH.
   slurmctld has been started with "ClusterID=X" from the state files in
   StateSaveLocation, but the DBD thinks it should be "Y".
   Remove /var/spool/slurmctld/<cluster-name>/clustername to override this
   safety check if this is intentional.
   ```

   Safe to clear if there's no accounting history worth protecting:

   ```bash
   kubectl exec -n slurm <cluster-name>-controller-0 -c slurmctld -- \
     rm -f /var/spool/slurmctld/<cluster-name>/clustername
   ```

   `supervisord` inside the pod restarts `slurmctld` automatically after
   this; watch `kubectl get pod -n slurm <cluster-name>-controller-0 -w`
   until it reaches `3/3 Running`.

## Uninstall

```bash
helm uninstall slurm-accounting -n slurm
kubectl delete pvc -n slurm data-<cluster-name>-accounting-mariadb-0
```

`accountingRef` is left set on the `Controller` CR after uninstall (the patch Job only runs on install/upgrade, not on delete). Clear it manually if you want slurmctld to fully stop expecting an accounting backend:

```bash
kubectl patch controllers.slinky.slurm.net -n slurm <controller-name> \
  --type json -p '[{"op":"remove","path":"/spec/accountingRef"}]'
kubectl delete pod -n slurm <cluster-name>-controller-0
```

## Configuration reference

See `chart/slurm-accounting/values.yaml` for the full set of options, including MariaDB image/resources/storage size, the slurmdbd image, and `patchController.enabled` (set to `false` if you'd rather patch `accountingRef` manually instead of via the chart's hook Job).
