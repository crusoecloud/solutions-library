#\!/usr/bin/env bash
# Installs the Kubeflow Training Operator v1.8.1 and disables its bundled
# MPIJob controller to avoid a known conflict with the dedicated MPI Operator
# v0.6.0 (which we install via install-mpi-operator.sh).
#
# Why disable MPIJob? Training Operator v1.8.1 starts an mpijob-controller
# that watches `mpijobs.kubeflow.org` at apiVersion v1. The dedicated MPI
# Operator (which 01-nccl-test uses) owns the same CRD at v2beta1 only. With
# both installed, Training Operator's mpijob informer can't sync, the manager
# fails to start, and the operator crash-loops. Since we ONLY need PyTorchJob
# from Training Operator (for 02-torchtitan-llama3-8b), restricting it via
# --enable-scheme=pytorchjob skips the conflicting controller entirely.
#
# Usage:  bash install-training-operator.sh [--kubeconfig PATH]

set -euo pipefail

TRAINING_OP_REF="v1.8.1"
TRAINING_OP_URL="github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=${TRAINING_OP_REF}"

KUBECTL_ARGS=()
if [[ "${1:-}" == "--kubeconfig" && -n "${2:-}" ]]; then
  KUBECTL_ARGS+=(--kubeconfig "$2")
fi

echo "==> Applying Training Operator ${TRAINING_OP_REF}"
kubectl "${KUBECTL_ARGS[@]}" apply -k "${TRAINING_OP_URL}" 2>&1 | tail -5 || true

echo
echo "==> Patching training-operator deployment to enable PyTorchJob only"
echo "    (skips the bundled mpijob-controller, which conflicts with the"
echo "     dedicated MPI Operator v0.6.0 if both are installed)"
kubectl "${KUBECTL_ARGS[@]}" -n kubeflow patch deploy training-operator --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--enable-scheme=pytorchjob"]}]'

echo
echo "==> Rolling out + waiting for deployment to become Available"
kubectl "${KUBECTL_ARGS[@]}" -n kubeflow rollout restart deploy training-operator
kubectl "${KUBECTL_ARGS[@]}" -n kubeflow rollout status deploy training-operator --timeout=120s
kubectl "${KUBECTL_ARGS[@]}" -n kubeflow wait --for=condition=Available deploy/training-operator --timeout=120s

echo
echo "==> Verifying CRDs"
kubectl "${KUBECTL_ARGS[@]}" get crd pytorchjobs.kubeflow.org -o jsonpath='{.metadata.name}{" — served versions: "}{.spec.versions[*].name}{"\n"}'

echo
echo "==> Training Operator installed and Available with PyTorchJob enabled."
echo "==> Next: cd ../02-torchtitan-llama3-8b && kubectl apply -f pytorchjob-streaming-<sku>.yaml"
