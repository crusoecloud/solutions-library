# Disable Hyperthreading on Crusoe Managed Kubernetes Nodes

This directory contains a Kubernetes DaemonSet (`disable-ht.yaml`) that disables Simultaneous Multi-Threading (SMT / hyperthreading) on nodes in a Crusoe Managed Kubernetes (CMK) cluster. It also includes a `Dockerfile` for building the container image used by the manifest. It is designed only for worker nodes in CMK Nodepools running standard (Ubuntu-based) CMK images.

## Important: Only use this solution if required by your organization

Some specialized workloads require that hyperthreading should be disabled on compute hosts. The majority of workloads that are run on CMK clusters are best run on standard configurations (that is, with hyperthreading enabled, which is the case on all Crusoe VM and Kubernetes images) in order to make most efficient use of the compute resources available.

> **Important:** Disabling hyperthreading halves the number of logical CPUs available to Kubernetes on every node where the DaemonSet runs. For example, a Kubernetes worker node on a c1a.2x instance will appear to have only 1 CPU after the pod is run on it. Size your node SKUs and resource requests accordingly before deploying.

## How it works

The DaemonSet deploys one pod per node. Each pod:

1. **Checks the SMT control file** at `/sys/devices/system/cpu/smt/control` (mounted from the host). If the file is absent or SMT is already `off`, it skips straight to step 3.
2. **Disables hyperthreading** by writing `off` to the SMT control file.
4. **Restarts kubelet** on the host using `nsenter -t 1 -m -- systemctl restart kubelet`, entering the host mount namespace via the host PID (PID 1).
5. **Sleeps indefinitely** but re-runs in the event of a node restart (because the pod does not change the node's grub configuration and therefore the change in step 1 does not survive a reboot)

### Privileged access

The pod's container runs as root with `privileged: true`, mounts the host `/sys` filesystem, and uses `hostPID: true`. These are required to write to the kernel's SMT control file and to `nsenter` into the host to restart kubelet.

## Deploying

**Important:** Because the daemonset restarts kubelet on each node that it runs on, we recommend that the daemonset is deployed before the nodes are put into production. In most cases, kubelet restarts in about 1 second with no pod restarts and no disruption to existing workloads, but if any underlying host issue prevents kubelet from restarting quickly, pods might be disrupted. Therefore, it is best to ensure that the daemonset is created before deploying production workloads.

```bash
kubectl apply -f disable-ht.yaml
```

Once the pods have run, logical CPU counts will reflect physical cores only. To see that the change has taken effect, SSH into one of the nodes and run `lscpu|grep Thread` to see that the number of threads per core is now 1.

To revert the change (if you want to re-enable hyperthreading), delete the daemonset as shown below and reboot the nodes (or if you don't want to reboot the nodes, ssh into each node and `echo on > /sys/devices/system/cpu/smt/control && systemctl restart kubelet`):

```bash
kubectl delete -f disable-ht.yaml
```

## Benchmarking the effect with stress-ng

Run the following command **before** and **after** applying the DaemonSet to measure the difference in compute throughput (Bogus Operations per Second) caused by disabling hyperthreading. The pod uses the same image as the DaemonSet, which includes `stress-ng`.

```bash
kubectl run stress-ng-test \
    --image=ghcr.io/datadoc24/disable-ht:latest \
    --rm -it \
    -- /bin/sh -c 'stress-ng --matrix $(nproc) -t 10 --metrics-brief'
```

This spawns one `stress-ng` matrix stressor per logical CPU (`$(nproc)`) and runs for 10 seconds. After disabling hyperthreading, `nproc` will return half the previous value and the per-stressor Bogo ops/s should increase, reflecting less contention between sibling threads. The total aggregate throughput may differ depending on the workload and SKU.

## Building the image

The `Dockerfile` is based on Alpine and installs `bash`, `util-linux` (for `nsenter`), `stress-ng`, and a pinned `kubectl` binary. To build and push your own image:

```bash
docker build --platform linux/amd64 --build-arg KUBECTL_VERSION=v1.35.0 -t <your-registry>/disable-ht:latest .
docker push <your-registry>/disable-ht:latest
```

Then update the `image:` field in `disable-ht.yaml` to reference your registry.
