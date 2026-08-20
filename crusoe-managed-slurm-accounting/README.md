# Crusoe Managed Slurm Accounting

This solution adds slurm accounting (slurmdbd + MariaDB) on top of a Crusoe **Managed Slurm** cluster. Managed Slurm does not provision accounting by default — this repo's Helm chart (`chart/slurm-accounting/`) fills that gap.

## Prerequisites

- `helm` v3+
- `kubectl` matching (or close to) the cluster's Kubernetes version
- Crusoe CLI
- Cluster admin access — the chart creates a `StorageClass`, RBAC objects, and patches a cluster-scoped-adjacent `Controller` CR owned by the Crusoe operator.

## What the chart deploys

| Resource | Purpose |
|---|---|
| `StorageClass` (`ssd.csi.crusoe.ai`) | StorageClass for MariaDB using Crusoe Persistent Disk. |
| MariaDB `StatefulSet` + `Service` + `Secret` | The accounting database (`slurm_acct_db`). Credentials are auto-generated on first install and preserved across upgrades. |
| `Accounting` CR (`slinky.slurm.net/v1beta1`, aka slurmdbd) | The slurmdbd daemon, pointed at the MariaDB instance and reusing the cluster's existing auth secrets. Its pod carries `initContainers` that wait for MariaDB to be ready before slurmdbd starts (see [Known issues](#known-issues) #5). |
| Pre-install/pre-upgrade Job + RBAC | Patches `spec.accountingRef` onto the existing `Controller` CR **before** the `Accounting` CR is created (ordering matters — see [Known issues](#known-issues) below). |
| Post-install/post-upgrade Job + RBAC (`restartPods.enabled`, off by default) | Deletes existing controller/login (and optionally worker) pods so they re-fetch config with accounting enabled. See [Installing on an existing cluster](#installing-on-an-existing-cluster). |

## Installations

There will typically be two scenarios in which you will install this chart:

### Installing on a new Crusoe Managed Slurm cluster

Creating the `SlurmCluster` CR is what triggers node provisioning for the
controller and login nodes — before that CR exists there are no nodes to
schedule *anything* onto, including this chart's patch Job. Because of that,
controller and login pods come up together as soon as the `SlurmCluster` CR
is created, and there's no way to install this chart in between them.

`sackd` (login) and `slurmd` (worker/compute nodes, in the configless/dynamic
mode this cluster uses) each fetch `slurm.conf` from the controller **once,
at process start**, and have no live-reconfigure signal — see
[Known issues](#known-issues) #4. So a pod that's already running when
`accountingRef` gets patched onto the `Controller` CR will keep reporting
accounting as disabled until it's restarted, no matter how the chart install
itself is sequenced.

Given that, the sequencing that minimizes how much you need to restart is:

1. Create the CMK cluster, then the `SlurmCluster` CR (provisions controller + login nodes).
2. Install this chart **immediately** — before scaling up or adding any worker/compute node pools. Accept that the login pod will need a restart (unavoidable, see above); it's a cheap, single-replica Deployment. `clusterName` must match your `SlurmCluster` CR's `metadata.name` exactly
(check with `kubectl get slurmclusters -n <namespace>`). `values.yaml` ships with it set to `test` as a placeholder; override it explicitly with `--set` (or edit `values.yaml`):

```bash
cd chart/slurm-accounting

# Also review namespace and the rest of values.yaml before installing.
helm lint . --set clusterName=<your-slurmcluster-name>
helm install slurm-accounting . -n slurm \
  --set clusterName=<your-slurmcluster-name> \
  --set restartPods.enabled=true \
  --wait --timeout 30m
```

`--wait` blocks until the MariaDB StatefulSet and the patch Job report ready/succeeded. On a clean cluster this should complete in under two minutes.

Setting `restartPods.enabled=true` will restart the controller and login pods (see [Known issue #4](#known-issues) for why).

3. Scale up / add worker node pools. Each worker's first `slurmd` fetch will already see accounting configured, so **no worker restarts are needed**.

### Installing on an existing cluster

If you're installing this chart onto a cluster that **already** has controller, login, and worker pods up and running, then all of them predate `accountingRef` and are stuck on stale config — not just the controller. Doing the restarts by hand for every login and worker pod doesn't scale well once there are more than a handful, so the chart can do it for you:

```bash
helm install slurm-accounting . -n slurm \
  --set clusterName=<your-slurmcluster-name> \
  --set restartPods.enabled=true \
  --set restartPods.includeWorkers=true \
  --wait --timeout 15m
```

This adds a post-install/post-upgrade Job that runs after `accountingRef` is already set and:
- Always deletes the controller and login pod(s) (cheap: a single StatefulSet replica and a Deployment).
- Deletes worker (`slurmd`) pods too, **only if** `restartPods.includeWorkers=true`. Only set it if you're OK with that disruption (e.g. no active workload, or you're fine with those jobs failing/requeuing). If you'd rather restart workers in batches instead of all at once, leave `restartPods.includeWorkers=false` and drain/recreate them yourself in smaller groups. With `includeWorkers`, the Job also sequences the restarts: it waits for the replacement controller pod to be Ready before deleting workers (see [Known issues](#known-issues) #7), then waits for the replacement workers and runs `scontrol reconfigure` so they rejoin the topology tree (see [Known issues](#known-issues) #8).

> **Heads up:** restarting the controller on a cluster that has been running for a while can hit a statesave volume mount failure that is unrelated to this chart — see [Known issues](#known-issues) #6. Cheap insurance before installing with `restartPods.enabled=true`: run the one-line prevention command from that entry while the controller is still up.

### Confirm the cluster is registered with accounting

```bash
ssh root@<login-ip> "sacctmgr show cluster"
# Should list the cluster instead of erroring with "not running a supported
# accounting_storage plugin".
```

If it's missing, that means slurmctld hasn't successfully talked to
slurmdbd with accounting configured yet — re-check
[Known issues](#known-issues) #4 and #5 rather than adding the cluster by
hand.

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

   For a single-user/test cluster, the built-in `root` account is fine to use directly and this step can be skipped.

2. **Add Users via `SlurmUser` CR** as shown in [Crusoe Documentations](https://docs.crusoecloud.com/orchestration/slurm/kubernetes-setup#step-5-add-users-optional):

   ```bash
   kubectl apply -f user.yaml
   ```

3. **Add the user to accounting under that account** (still as `root`,
   or any user in the `slurm-admin` group):

   ```bash
   ssh root@<login-ip> "sacctmgr -i add user <username> Account=<account-name>"
   ```

   Repeat steps 2–3 for each additional user. Until step 3 runs for a user, their jobs still execute and still show up in `sacct` (accounting isn't enforced by default — `AccountingStorageEnforce=none`), just with an empty `Account` column and none of the account's limits applied.

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

4. **`sacct`/`sacctmgr` say accounting is disabled even though
   `scontrol show config` on the same node shows
   `AccountingStorageType = accounting_storage/slurmdbd`.** This happens on
   any login or worker pod that was already running before `accountingRef`
   was patched onto the `Controller` CR. `scontrol` queries `slurmctld`
   live over RPC, so it always reflects the current config — but `sacct`
   and `sacctmgr` read the login/worker pod's own locally cached
   `slurm.conf`, fetched once at process start by `sackd` (login) or
   `slurmd` (worker, dynamic/configless mode) via `--conf-server`. Neither
   daemon has a live-reconfigure signal, so that cached copy never updates
   on its own. Fix: restart the affected pod(s) — see
   [Installing on an existing cluster](#installing-on-an-existing-cluster) or set
   `restartPods.enabled=true`/`restartPods.includeWorkers=true`. Prefer
   [installing on a new cluster](#installing-on-a-new-crusoe-managed-slurm-cluster)
   before worker node pools are scaled up, so workers never hit this in the
   first place.

5. **slurmdbd gets stuck not-Ready, and slurmctld crash-loops with
   `error: Sending PersistInit msg: Operation not permitted` /
   `fatal: Problem adding tres to the database`.** This is a first-boot
   race between the `Accounting` (slurmdbd) resource and the MariaDB
   `StatefulSet`, both created by the same `helm install`. slurmdbd's
   `as_mysql` plugin only retries connecting to MariaDB a fixed number of
   times at startup; if it starts while MariaDB is still doing its
   one-time init (temp server → secure-installation → real restart — the
   DNS name can also be briefly unresolvable during this window), it can
   exhaust that retry budget and end up alive but never listening on 6819.
   slurmctld then can't complete its persistent-connection handshake to
   slurmdbd; Slurm's `auth/slurm` plugin surfaces that as
   `Operation not permitted` (easy to mistake for a NetworkPolicy or RBAC
   block — check `kubectl get networkpolicy` / `ciliumnetworkpolicy` to
   rule that out first). It won't recover on its own.

   **This chart prevents it automatically** when `mariadb.enabled: true`
   (the default): the `Accounting` CR carries two `initContainers` (added
   via its `spec.template.spec`, which the slurm-operator strategic-merges
   into the slurmdbd pod — see `accounting.yaml`) that wait for the
   MariaDB `StatefulSet` to exist and report an available replica before
   slurmdbd's main container ever starts, so its first connection attempt
   always lands on an already-usable database. Raise
   `mariadb.waitForReadyTimeoutSeconds` (default `300`) if your storage
   provisioner or MariaDB's first-boot init is slow enough to exceed it.

   If you still hit this (e.g. `mariadb.enabled: false` with an external
   database that wasn't ready), the manual fix is the same idea: once
   `kubectl get pod -n slurm test-accounting-mariadb-0` (or
   `<release>-mariadb-0`) has been `1/1 Running` for a few minutes, restart
   the accounting pod, then the controller pod:

   ```bash
   kubectl delete pod -n slurm <release>-accounting-0
   kubectl wait --for=condition=Ready pod -n slurm <release>-accounting-0 --timeout=60s
   kubectl delete pod -n slurm <cluster-name>-controller-0
   kubectl get pod -n slurm <cluster-name>-controller-0 -w   # wait for 3/3 Running
   ```

6. **Controller pod stuck `Init:0/2` after a restart —
   `MountVolume.SetUp failed ... applyFSGroup failed ... open .../hash.0:
   permission denied` on the statesave PVC.** A Managed Slurm platform
   issue that any controller restart can hit, chart or no chart — but
   `restartPods.enabled=true` restarts the controller, so it can surface
   during this chart's install. The controller pod runs with `fsGroup`,
   which makes kubelet recursively walk the NFS-backed statesave volume at
   mount time; slurmctld creates `hash.N` state directories with mode
   `0700`, and the NFS export squashes root, so kubelet can't read them and
   the mount fails forever. The first-ever mount only works because the
   volume is empty. (`fsGroupChangePolicy: OnRootMismatch` does **not**
   help: the volume root's group never matches the pod's `fsGroup` — the
   server silently ignores kubelet's chown — so the full walk always runs.)

   **Prevention** (controller still running — e.g. right before installing
   this chart with `restartPods.enabled=true`): make the state directories
   group/other-traversable from inside the controller pod itself:

   ```bash
   kubectl exec -n slurm <cluster-name>-controller-0 -c slurmctld -- \
     sh -c 'find /var/spool/slurmctld -type d ! -perm -005 -exec chmod o+rx {} +'
   ```

   **Recovery** (controller already stuck `Init:0/2`, so `exec` is not an
   option): same chmod, but via a helper pod that mounts the statesave PVC
   running as the Slurm UID (401) **without** `fsGroup` (so no ownership
   walk is triggered), then let kubelet's next mount retry (~2 min)
   succeed:

   ```yaml
   # statesave-fix.yaml -- set nodeName to the node the controller pod is
   # scheduled on (kubectl get pod -n slurm <cluster-name>-controller-0 -o wide)
   apiVersion: v1
   kind: Pod
   metadata:
     name: statesave-fix
     namespace: slurm
   spec:
     nodeName: <controller-node>
     restartPolicy: Never
     securityContext:
       runAsUser: 401
       runAsGroup: 401
       runAsNonRoot: true
     containers:
       - name: shell
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: statesave
             mountPath: /statesave
     volumes:
       - name: statesave
         persistentVolumeClaim:
           claimName: statesave-<controller-name>-0
   ```

   ```bash
   kubectl apply -f statesave-fix.yaml
   # The helper pod can sit in ContainerCreating for ~10 minutes, queued
   # behind the failing controller mount's retry backoff -- be patient.
   kubectl wait --for=condition=Ready pod/statesave-fix -n slurm --timeout=15m
   kubectl exec -n slurm statesave-fix -- \
     find /statesave -type d ! -perm -005 -exec chmod o+rx {} +
   kubectl delete pod -n slurm statesave-fix
   kubectl get pod -n slurm <cluster-name>-controller-0 -w   # wait for 3/3 Running
   ```

   This can recur: slurmctld may create new `0700` `hash.N` directories
   later, breaking the *next* controller restart until the chmod is
   repeated (or the platform fixes the fsGroup/root-squash interaction).

7. **Worker (`slurmd`) pods deleted while the controller is down are not
   recreated for a long time.** The slurm-operator's nodeset controller
   needs a live slurmctld to sync its Slurm node cache; while the
   controller is restarting it errors with `failed to wait on type V0044Node
   cache sync: ... Unable to contact slurm controller` and goes into
   exponential backoff — deleted worker pods stay gone and `sinfo` shows
   the node as `idle*` (non-responding). The chart's restart Job avoids
   this by waiting for the replacement controller pod to be Ready before
   deleting workers (`restartPods.waitForControllerReadyTimeoutSeconds`).
   If you hit it anyway (e.g. workers deleted by hand), force a reconcile
   once the controller is back:

   ```bash
   kubectl annotate nodesets.slinky.slurm.net -n slurm <nodeset-name> \
     reconcile-nudge=1 --overwrite
   ```

8. **After a controller restart, jobs fail with `srun: error: Unable to
   allocate resources: Requested topology configuration is not available`
   even though `sinfo` shows the node as `idle`.** Worker nodes are
   dynamic (configless): they register with slurmctld at `slurmd` start.
   A slurmctld that boots while workers are down parses `topology.conf`
   with node names it doesn't know yet — those entries are dropped, the
   nodes end up outside the topology tree (`scontrol show topology` shows
   the leaf switch with `Nodes=` empty), and nothing re-parses topology
   when the workers register later (if the topology ConfigMap content is
   unchanged, the reconfigure sidecar sees no change and stays quiet).
   The chart's restart Job handles this when `restartPods.includeWorkers=true`
   by waiting for the replacement workers and running `scontrol
   reconfigure`. If you hit it after restarting pods by hand:

   ```bash
   kubectl exec -n slurm <controller-pod> -c slurmctld -- scontrol reconfigure
   ```

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

See `chart/slurm-accounting/values.yaml` for the full set of options, including MariaDB image/resources/storage size, the slurmdbd image, `patchController.enabled` (set to `false` if you'd rather patch `accountingRef` manually instead of via the chart's hook Job), and `restartPods.enabled`/`restartPods.includeWorkers` (see [Installing on an existing cluster](#installing-on-an-existing-cluster)).
