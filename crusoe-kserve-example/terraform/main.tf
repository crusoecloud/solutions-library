terraform {
  required_providers {
    crusoe = {
      source = "crusoecloud/crusoe"
    }
  }
}

provider "crusoe" {
  # Uses CRUSOE_API_KEY / CRUSOE_API_SECRET from environment,
  # or ~/.crusoe/config if present.
}

# -----------------------------------------------------------------------------
# Variables for KServe + namespace setup
# -----------------------------------------------------------------------------
variable "kserve_version" {
  description = "KServe release version"
  type        = string
  default     = "v0.19.0"
}

variable "namespace" {
  description = "Kubernetes namespace for LLM workloads"
  type        = string
  default     = "kserve-test"
}

variable "hf_token" {
  description = "HuggingFace API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for node pool access"
  type        = string
  # Crusoe provisions this key onto every node at creation time — it cannot be
  # added later without destroying and recreating the node pool. Set this to
  # your public key (e.g. contents of ~/.ssh/id_ed25519.pub) so you can SSH
  # directly into GPU nodes for debugging (e.g. nvidia-smi, driver issues).
}

# -----------------------------------------------------------------------------
# CMK Cluster
# -----------------------------------------------------------------------------
resource "crusoe_kubernetes_cluster" "kserve" {
  name       = var.cluster_name
  version    = var.cluster_version
  location   = var.location
  project_id = var.project_id
  add_ons    = ["nvidia_gpu_operator", "nvidia_network_operator", "crusoe_csi"]
}

# -----------------------------------------------------------------------------
# Node Pools
# -----------------------------------------------------------------------------
resource "crusoe_kubernetes_node_pool" "a100" {
  count           = var.a100_node_count > 0 ? 1 : 0
  name            = var.a100_pool_name
  cluster_id      = crusoe_kubernetes_cluster.kserve.id
  instance_count  = var.a100_node_count
  type            = var.a100_node_type
  ssh_key         = var.ssh_public_key
  ib_partition_id = var.a100_ib_partition_id
  project_id      = var.project_id

  # ssh_key and ib_partition_id are write-only in the Crusoe API (not returned
  # on read), so they always read as a change after `terraform import` and would
  # force pool replacement. Ignoring them lets an existing pool be adopted
  # without recreating its nodes. Harmless for create-from-scratch.
  lifecycle {
    ignore_changes = [ssh_key, ib_partition_id]
  }
}

resource "crusoe_kubernetes_node_pool" "h100" {
  count           = var.h100_node_count > 0 ? 1 : 0
  name            = var.h100_pool_name
  cluster_id      = crusoe_kubernetes_cluster.kserve.id
  instance_count  = var.h100_node_count
  type            = var.h100_node_type
  ssh_key         = var.ssh_public_key
  ib_partition_id = var.h100_ib_partition_id
  project_id      = var.project_id

  lifecycle {
    ignore_changes = [ssh_key, ib_partition_id]
  }
}

resource "crusoe_kubernetes_node_pool" "cpu" {
  count          = var.cpu_node_count > 0 ? 1 : 0
  name           = var.cpu_pool_name
  cluster_id     = crusoe_kubernetes_cluster.kserve.id
  instance_count = var.cpu_node_count
  type           = var.cpu_node_type
  ssh_key        = var.ssh_public_key
  project_id     = var.project_id

  lifecycle {
    ignore_changes = [ssh_key]
  }
}

# -----------------------------------------------------------------------------
# Kubeconfig — fetch credentials after cluster + node pools are ready
# -----------------------------------------------------------------------------
resource "null_resource" "kubeconfig" {
  depends_on = [
    crusoe_kubernetes_cluster.kserve,
    crusoe_kubernetes_node_pool.a100,
    crusoe_kubernetes_node_pool.h100,
    crusoe_kubernetes_node_pool.cpu,
  ]

  provisioner "local-exec" {
    command = "crusoe kubernetes clusters get-credentials ${crusoe_kubernetes_cluster.kserve.name} --project-id ${var.project_id} -y"
  }
}

# -----------------------------------------------------------------------------
# Install KServe
# -----------------------------------------------------------------------------
resource "null_resource" "kserve_install" {
  depends_on = [null_resource.kubeconfig]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      BASE_URL="https://github.com/kserve/kserve/releases/download/${var.kserve_version}"

      echo "=== Installing KServe ${var.kserve_version} ==="

      echo "[1/5] Installing standard mode dependencies..."
      curl -fsSL "$${BASE_URL}/kserve-standard-mode-dependency-install.sh" | bash

      echo "[2/5] Installing LLMInferenceService dependencies..."
      curl -fsSL "$${BASE_URL}/llmisvc-dependency-install.sh" | bash

      echo "[3/5] Installing KServe CRDs..."
      kubectl apply --server-side -f "$${BASE_URL}/kserve-crds.yaml"

      echo "Waiting for CRDs to be established..."
      kubectl wait --for=condition=Established crds --all --timeout=60s

      echo "[4/5] Installing KServe controller..."
      kubectl apply --server-side --force-conflicts -f "$${BASE_URL}/kserve.yaml"

      echo "Waiting for KServe controllers to be ready..."
      kubectl rollout status deployment/kserve-controller-manager -n kserve
      kubectl rollout status deployment/llmisvc-controller-manager -n kserve

      echo "[5/5] Installing KServe cluster resources..."
      kubectl apply --server-side -f "$${BASE_URL}/kserve-cluster-resources.yaml"

      echo "Configuring storage-initializer for large model downloads..."
      kubectl patch configmap inferenceservice-config -n kserve --type merge -p \
        '{"data":{"storageInitializer":"{\"image\":\"kserve/storage-initializer:${var.kserve_version}\",\"memoryRequest\":\"2Gi\",\"memoryLimit\":\"64Gi\",\"cpuRequest\":\"1\",\"cpuLimit\":\"8\",\"caBundleConfigMapName\":\"\",\"caBundleVolumeMountPath\":\"/etc/ssl/custom-certs\",\"enableModelcar\":true,\"cpuModelcar\":\"10m\",\"memoryModelcar\":\"15Mi\",\"uidModelcar\":1010}"}}'

      echo "=== KServe installation complete ==="
    EOT
  }
}

# -----------------------------------------------------------------------------
# Create namespace + HuggingFace secret
# -----------------------------------------------------------------------------
resource "null_resource" "namespace_setup" {
  depends_on = [null_resource.kserve_install]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      kubectl create namespace ${var.namespace} --dry-run=client -o yaml | kubectl apply -f -

      kubectl create secret generic hf-secret \
        --from-literal=HF_TOKEN=${var.hf_token} \
        -n ${var.namespace} \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "Namespace '${var.namespace}' ready with HuggingFace secret."
    EOT
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "cluster_name" {
  value = crusoe_kubernetes_cluster.kserve.name
}

output "next_steps" {
  value = <<-EOT
    Cluster and KServe are ready. Deploy a model:

      # From the repo root:
      make deploy-basic       # Single-GPU (Qwen2.5-0.5B)
      make deploy-multi-node  # Multi-node (Qwen2.5-72B, 16 GPUs)
      make deploy-disaggregated  # Prefill-decode (H100 + A100)

      make test               # Port-forward and send a test request
  EOT
}
