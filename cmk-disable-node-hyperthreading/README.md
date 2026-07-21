# Disable Hyperthreading on Crusoe Managed Kubernetes Nodes

This directory contains a Kubernetes DaemonSet (`disable-ht.yaml`) that disables Simultaneous Multi-Threading (SMT / hyperthreading) on every node in a Crusoe Managed Kubernetes cluster, and a companion Job (`enable-ht.yaml`) that reverses the change. It also includes a `Dockerfile` for building the container image used by both manifests.

## Important: Only use this solution if required by your organization

Some specialized workloads or organizational requirements mandate that Hyperthreading should be disabled on compute hosts. The majority of workloads that are run on Crusoe Managed Kubernetes clusters are best run on standard configurations (that is, with hyperthreading enabled, which is the case on all Crusoe VM and Kubernetes images) in order to make most efficient use of the compute resources available.

> **Important:** Disabling hyperthreading halves the number of logical CPUs available to Kubernetes on every node where the DaemonSet runs. For example, a Kubernetes worker node on a c1a.2x instance will appear to have only 1 CPU after the pod is run on it. Size your node SKUs and resource requests accordingly before deploying.

## How it works

The DaemonSet deploys one pod per node. Each pod:

1. **Checks the SMT control file** at `/sys/devices/system/cpu/smt/control` (mounted from the host). If the file is absent or SMT is already `off`, it skips straight to step 3.
2. **Disables hyperthreading** by writing `off` to the SMT control file.
3. **Labels the node** with `hyperthreading=disabled` via the Kubernetes API.
4. **Restarts kubelet** on the host using `nsenter -t 1 -m -- systemctl restart kubelet`, entering the host mount namespace via the host PID (PID 1).
5. **Sleeps indefinitely** until the DaemonSet controller removes the pod.

The DaemonSet uses a `nodeAffinity` rule (`hyperthreading DoesNotExist`) so that pods are only scheduled on nodes that have not yet been processed. Once a node is labelled `hyperthreading=disabled`, no new pod is scheduled there, preventing a restart loop.

### RBAC

The DaemonSet runs under a dedicated `ServiceAccount` with a `ClusterRole` that grants only `get` and `patch` on `nodes` — the minimum permissions needed to read node state and apply the label.

### Privileged access

The container runs as root with `privileged: true`, mounts the host `/sys` filesystem, and uses `hostPID: true`. These are required to write to the kernel's SMT control file and to `nsenter` into the host to restart kubelet.

## Deploying

**Important:** Because the daemonset restarts kubelet on each node that it runs on, we recommend that the daemonset is deployed before the nodes are put into production. In most cases, the kubelet restart is extremely fast and causes no disruption to existing workloads, but if there is any risk that workloads would be disrupted by a short period during which pods cannot be started, it is best to ensure that the daemonset is created and all expected nodes have the 'hyperthreading=disabled' label before deploying production workloads.

```bash
kubectl apply -f disable-ht.yaml
```

Monitor progress:

```bash
kubectl -n kube-system get pods -l app=disable-ht -w
```

Once all pods have run, every node will carry the `hyperthreading=disabled` label and logical CPU counts will reflect physical cores only.

To remove the DaemonSet after it has finished:

```bash
kubectl delete -f disable-ht.yaml
```

> Note: removing the DaemonSet does not re-enable hyperthreading. Use `enable-ht.yaml` (see below) to restore SMT on all affected nodes, or reboot the nodes.

## Re-enabling hyperthreading

`enable-ht.yaml` is a Kubernetes Job that reverses the changes made by `disable-ht.yaml`. It targets every node that carries the `hyperthreading=disabled` label and, on each one: writes `on` to `/sys/devices/system/cpu/smt/control`, restarts kubelet, and removes the `hyperthreading=disabled` label.

### How it works

Because a Job does not fan out to multiple nodes the way a DaemonSet does, `enable-ht.yaml` uses an orchestrator pattern:

1. An **orchestrator Job** pod lists all nodes labeled `hyperthreading=disabled`.
2. For each node it creates a **per-node Job** pod targeted to that node via `nodeName`.
3. Each per-node pod re-enables SMT, restarts kubelet via `nsenter`, and removes the label.
4. The orchestrator waits for all per-node jobs to complete before exiting.

Per-node Jobs are automatically deleted 600 seconds after they finish via `ttlSecondsAfterFinished`.

### Steps to re-enable hyperthreading

1. Delete the `disable-ht` DaemonSet first so it does not immediately re-disable SMT on nodes as they come back up:

   ```bash
   kubectl delete -f disable-ht.yaml
   ```

2. Apply the Job:

   ```bash
   kubectl apply -f enable-ht.yaml
   ```

3. Monitor the orchestrator:

   ```bash
   kubectl -n kube-system logs -f job/enable-ht
   ```

4. Once complete, verify that nodes no longer carry the label and that logical CPU counts have doubled:

   ```bash
   kubectl get nodes -L hyperthreading
   ```

5. Clean up:

   ```bash
   kubectl delete -f enable-ht.yaml
   ```

## Restricting to nodes with a specific label

By default the DaemonSet targets every node that lacks the `hyperthreading` label. To restrict it to nodes that carry a particular label — for example `crusoe.ai/cpu-only=true` — add a `matchExpressions` clause to the existing `nodeSelectorTerms` block in `disable-ht.yaml`:

```yaml
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: hyperthreading
                operator: DoesNotExist
              - key: crusoe.ai/cpu-only   # <-- add this
                operator: In
                values:
                - "true"
```

Both expressions must be satisfied simultaneously (they are AND-ed within the same `matchExpressions` list), so the pod will only run on nodes that both lack the `hyperthreading` label and carry the target label.

## Building the image

The `Dockerfile` is based on Alpine and installs `bash`, `util-linux` (for `nsenter`), `stress-ng`, and a pinned `kubectl` binary. To build and push your own image:

```bash
docker build --platform linux/amd64 --build-arg KUBECTL_VERSION=v1.35.0 -t <your-registry>/disable-ht:latest .
docker push <your-registry>/disable-ht:latest
```

Then update the `image:` field in `disable-ht.yaml` to reference your registry.

## Benchmarking the effect with stress-ng

Run the following command **before** and **after** applying the DaemonSet to measure the difference in compute throughput (Bogus Operations per Second) caused by disabling hyperthreading. The pod uses the same image as the DaemonSet, which includes `stress-ng`.

```bash
kubectl run stress-ng-test \
    --image=ghcr.io/datadoc24/disable-ht:latest \
    --rm -it \
    -- /bin/sh -c 'stress-ng --matrix $(nproc) -t 10 --metrics-brief'
```

This spawns one `stress-ng` matrix stressor per logical CPU (`$(nproc)`) and runs for 10 seconds. After disabling hyperthreading, `nproc` will return half the previous value and the per-stressor Bogo ops/s should increase, reflecting less contention between sibling threads. The total aggregate throughput may differ depending on the workload and SKU.
