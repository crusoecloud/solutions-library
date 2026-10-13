#!/usr/bin/env bash
# ============================================================================
# build-kaniko-amdperftest.sh
# ----------------------------------------------------------------------------
# Build the roce-workload:${TAG} image via Kaniko in-cluster and push to CCR.
# The Dockerfile derives from the a-77 base and adds AMD's fork of perftest
# (github.com/ROCm/rdma-perftest branch master-dmabuf-rocm-20250114, commit
# 2db71141d6a3) configured with --enable-rocm --enable-rocm-dmabuf so that
# ib_write_bw's --use_rocm=N --use_rocm_dmabuf flags actually work.
#
# CCR docker Basic-auth username must be the operator's email (not the user
# UUID or the token_id). The docker-registry secret `ccr-cred` must exist in
# the target namespace with that email as --docker-username. See runbook.md
# step 3 for the create command.
#
# Inputs (env):
#   NS            k8s namespace (default: default)
#   CCR_URL       CCR endpoint hostname (default: registry.us-east2-a.ccr.crusoecloudcompute.com)
#   CCR_REPO      <registry-name>.<project-short>, e.g. amd-355x.4da9452b
#   REGISTRY_NAME short registry name for CLI verify step, e.g. amd-355x
#                 (auto-derived from CCR_REPO if not set)
#   PROJECT_ID    Crusoe project UUID for the CLI verify step
#   TAG           image tag (default: a-77-crusoe-amdperftest)
#   IMAGE_NAME    image repo name in CCR (default: roce-workload)
# ============================================================================

set -euo pipefail

NS="${NS:-default}"
CCR_URL="${CCR_URL:-registry.us-east2-a.ccr.crusoecloudcompute.com}"
: "${CCR_REPO:?CCR_REPO=<registry-name>.<project-short> is required, e.g. amd-355x.4da9452b}"
REGISTRY_NAME="${REGISTRY_NAME:-${CCR_REPO%%.*}}"
: "${PROJECT_ID:?PROJECT_ID (Crusoe project UUID) is required for the verify step}"
IMAGE_NAME="${IMAGE_NAME:-roce-workload}"
TAG="${TAG:-a-77-crusoe-amdperftest}"
# The a-77 base tag to derive from. Must already exist in your CCR (see
# ../../mirror-image/src/mirror-a77-to-ccr.yaml to copy it from mcala-lab
# or ask your Crusoe SA for the equivalent tag they've published for you).
BASE_TAG="${BASE_TAG:-ubuntu24_rocm-7.2_rccl-7.2.0_anp-v1.3.0_ainic-1.117.5-a-77-crusoe}"
BASE_IMAGE="${BASE_IMAGE:-$CCR_URL/$CCR_REPO/$IMAGE_NAME:$BASE_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile.a77-perftest-rocm"
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/build-kaniko-amdperftest-$(date -u +%Y%m%dT%H%M%SZ).log"
TARGET="$CCR_URL/$CCR_REPO/$IMAGE_NAME:$TAG"

echo "==> base   : $BASE_IMAGE"
echo "==> target : $TARGET"
echo "==> log    : $LOG"

# Pre-flight
[[ -r "$DOCKERFILE" ]] || { echo "ERR: $DOCKERFILE not readable"; exit 1; }
kubectl -n "$NS" get secret ccr-cred >/dev/null 2>&1 \
  || { echo "ERR: docker-registry secret 'ccr-cred' missing in namespace $NS (see runbook.md step 3)"; exit 1; }

# Load Dockerfile into a ConfigMap
kubectl -n "$NS" create configmap bundle2-dockerfile-amdperftest \
  --from-file=Dockerfile="$DOCKERFILE" \
  --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null

# Clean any prior Job
kubectl -n "$NS" delete job build-amdperftest --wait=true 2>/dev/null || true

# Apply the Job
cat <<EOF | kubectl -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: build-amdperftest
  labels: { app: mi355x-poc, role: image-build }
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: mi355x-poc, role: image-build }
    spec:
      restartPolicy: Never
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:latest
          args:
            - --dockerfile=/workspace/Dockerfile
            - --context=/workspace
            - --destination=$TARGET
            - --build-arg=BASE_IMAGE=$BASE_IMAGE
            - --verbosity=info
            - --push-retry=5
            - --cache=true
            - --cache-copy-layers=true
          volumeMounts:
            - { name: dockerfile,    mountPath: /workspace }
            - { name: kaniko-secret, mountPath: /kaniko/.docker }
            - { name: tmp,           mountPath: /var/tmp }
          env:
            - { name: TMPDIR, value: /var/tmp }
          resources:
            requests: { cpu: "4", memory: 16Gi }
      volumes:
        - name: dockerfile
          configMap:
            name: bundle2-dockerfile-amdperftest
            items: [{ key: Dockerfile, path: Dockerfile }]
        - name: kaniko-secret
          secret:
            secretName: ccr-cred
            items: [{ key: .dockerconfigjson, path: config.json }]
        - name: tmp
          emptyDir: { sizeLimit: 80Gi }
EOF

# Wait for pod
echo "==> wait for kaniko pod"
POD=""
for i in $(seq 1 40); do
  POD=$(kubectl -n "$NS" get pod -l job-name=build-amdperftest -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$POD" ]]; then
    PHASE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]] && break
  fi
  sleep 5
done
echo "  pod=$POD phase=$PHASE"

echo "==> streaming kaniko logs -> $LOG"
kubectl -n "$NS" logs -f "$POD" > "$LOG" 2>&1 || true

FINAL=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
echo "==> final phase=$FINAL"
tail -30 "$LOG"

echo
echo "==> verify tag in CCR:"
crusoe registry manifests list "$REGISTRY_NAME" --repo-name "$IMAGE_NAME" --project-id "$PROJECT_ID" 2>&1 | head -8

if [[ "$FINAL" == "Succeeded" ]]; then
  echo "===================================================================="
  echo " PUSHED: $TARGET"
  echo "===================================================================="
else
  echo "ERR: kaniko Job did not succeed. Job kept for inspection:"
  echo "  kubectl -n $NS logs $POD"
  exit 1
fi
