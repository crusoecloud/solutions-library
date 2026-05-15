#!/usr/bin/env bash
# Installs the Kubeflow MPI Operator v0.6.0 (v2beta1 MPIJob API).
#
# This is required for 01-nccl-test/. The PyTorchJob in 02-torchtitan-llama3-8b/
# uses a separate operator (kubeflow training-operator) — see the suite README.
#
# Conflict handling: if you have the Kubeflow training-operator already installed
# (which also defines mpijobs.kubeflow.org with v1 storage), this script deletes
# the existing CRD before reapplying so the mpi-operator's v2beta1-only CRD can
# install cleanly. This is only safe when no MPIJob objects exist on the cluster.
#
# Usage:  bash install-mpi-operator.sh [--kubeconfig PATH]

set -euo pipefail

MPI_OPERATOR_VERSION="v0.6.0"
MPI_OPERATOR_URL="https://raw.githubusercontent.com/kubeflow/mpi-operator/${MPI_OPERATOR_VERSION}/deploy/v2beta1/mpi-operator.yaml"

KUBECTL_ARGS=()
if [[ "${1:-}" == "--kubeconfig" && -n "${2:-}" ]]; then
  KUBECTL_ARGS+=(--kubeconfig "$2")
fi

echo "==> Checking for existing MPIJob CRD"
if kubectl "${KUBECTL_ARGS[@]}" get crd mpijobs.kubeflow.org >/dev/null 2>&1; then
  existing_versions=$(kubectl "${KUBECTL_ARGS[@]}" get crd mpijobs.kubeflow.org -o jsonpath='{.spec.versions[*].name}')
  if [[ "$existing_versions" != "v2beta1" ]]; then
    echo "    Existing CRD has versions: $existing_versions"
    existing_jobs=$(kubectl "${KUBECTL_ARGS[@]}" get mpijobs.kubeflow.org -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$existing_jobs" -gt 0 ]]; then
      echo "ERROR: existing MPIJob objects found ($existing_jobs). Refusing to delete the CRD."
      echo "       Remove them manually, or migrate them to v2beta1 before continuing."
      exit 1
    fi
    echo "    Deleting existing CRD (no MPIJob objects present)"
    kubectl "${KUBECTL_ARGS[@]}" delete crd mpijobs.kubeflow.org
  else
    echo "    Existing CRD is already v2beta1-only — fine"
  fi
else
  echo "    No existing CRD"
fi

echo "==> Applying MPI Operator ${MPI_OPERATOR_VERSION}"
kubectl "${KUBECTL_ARGS[@]}" apply --server-side --force-conflicts -f "${MPI_OPERATOR_URL}"

echo "==> Waiting for mpi-operator deployment to become Available"
# Restart the operator pod once, in case it crashed during a prior CRD-missing window
kubectl "${KUBECTL_ARGS[@]}" -n mpi-operator delete pod -l app=mpi-operator --ignore-not-found
kubectl "${KUBECTL_ARGS[@]}" -n mpi-operator wait --for=condition=Available deploy/mpi-operator --timeout=120s

echo
echo "==> mpi-operator installed and Available."
echo "==> Verifying CRD"
kubectl "${KUBECTL_ARGS[@]}" get crd mpijobs.kubeflow.org -o jsonpath='{.metadata.name}{" — versions: "}{.spec.versions[*].name}{"\n"}'
echo
echo "Next: cd ../01-nccl-test && kubectl apply -f nccl-test-<sku>.yaml"
