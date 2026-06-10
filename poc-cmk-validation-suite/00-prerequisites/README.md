# 00 — Prerequisites

Installs the two Kubeflow operators the suite needs and (importantly) configures
them to coexist. Both must be Available before running the tests in
`01-nccl-test/` and `02-torchtitan-llama3-8b/`.

## What gets installed

| Operator | Version | Required for | Provides CRD |
|---|---|---|---|
| **Kubeflow MPI Operator** | `v0.6.0` | `01-nccl-test` (mpirun-based all_reduce_perf) | `mpijobs.kubeflow.org` (v2beta1) |
| **Kubeflow Training Operator** | `v1.8.1` | `02-torchtitan-llama3-8b` (PyTorchJob) | `pytorchjobs.kubeflow.org` (v1) |

## How to install

Run both scripts, in this order:

```bash
bash install-mpi-operator.sh --kubeconfig <PATH>
bash install-training-operator.sh --kubeconfig <PATH>
```

Each script is **idempotent** — safe to re-run. They wait for the operator
deployments to reach `Available` before exiting.

## The MPIJob CRD conflict (and why install order matters)

Both operators provide the same CRD name (`mpijobs.kubeflow.org`) but at
**different API versions**:

- **MPI Operator v0.6.0** uses `v2beta1` (and only ships v2beta1)
- **Training Operator v1.8.1** bundles an `mpijob-controller` that watches `v1`

If both operators are installed naively and Training Operator goes first, its
mpijob-controller's informer can't reach v2beta1 (because the dedicated MPI
Operator later overwrites the CRD to v2beta1-only). Training Operator's
manager fails to start with:

```
ERROR setup problem running manager
{"error": "failed to wait for mpijob-controller caches to sync: timed out
 waiting for cache to be synced for Kind *v1.MPIJob"}
```

Training Operator then enters `CrashLoopBackOff`, its admission webhook
becomes unreachable, and **subsequent `kubectl apply -f pytorchjob-….yaml`
fails** with:

```
Error from server: failed calling webhook "validator.pytorchjob.training-operator.kubeflow.org":
  no endpoints available for service "training-operator"
```

### How `install-training-operator.sh` fixes this

The script applies the standard Training Operator manifest, then **patches its
deployment** to set:

```yaml
args:
  - --enable-scheme=pytorchjob
```

This tells the operator to *only* run the PyTorchJob controller, skipping the
bundled MPIJob (which it isn't supposed to own anyway — the dedicated MPI
Operator handles that). The patched operator starts cleanly and serves the
PyTorchJob admission webhook.

The downside: if you ever want to use Training Operator for `TFJob`,
`MXJob`, `XGBoostJob`, or `PaddleJob`, you'll need to add them to the
`--enable-scheme` list. The suite only needs PyTorchJob.

## Verifying

After both scripts have run:

```bash
# Both operator deployments Available
kubectl -n mpi-operator get deploy mpi-operator
kubectl -n kubeflow get deploy training-operator

# Both CRDs present
kubectl get crd mpijobs.kubeflow.org pytorchjobs.kubeflow.org \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  -> "}{.spec.versions[*].name}{"\n"}{end}'
```

Expected output:
```
mpijobs.kubeflow.org      -> v2beta1
pytorchjobs.kubeflow.org  -> v1
```

If either deployment is `CrashLoopBackOff` or the CRD versions don't match
the above, re-run the corresponding install script.

## Uninstall (if needed)

```bash
kubectl delete -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.8.1"
kubectl delete -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
kubectl delete crd mpijobs.kubeflow.org pytorchjobs.kubeflow.org
```

Note: if any MPIJob or PyTorchJob objects still exist, delete them first
(or the CRD delete will hang).
