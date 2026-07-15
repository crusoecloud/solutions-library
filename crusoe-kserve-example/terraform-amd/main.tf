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
# CMK Cluster
# Default add-ons enable the CMK-managed AMD GPU + network operators, so CMK
# installs/maintains the GPU driver & operator — no manual `make install-amd-gpu-operator`
# and no Docker Hub credentials. Requires an AMD "Bundle 1" cluster version
# (var.cluster_version, e.g. 1.33.4-cmk.93). See var.cluster_add_ons for the legacy path.
# -----------------------------------------------------------------------------
resource "crusoe_kubernetes_cluster" "kserve_amd" {
  name       = var.cluster_name
  version    = var.cluster_version
  location   = var.location
  project_id = var.project_id
  add_ons    = var.cluster_add_ons
  # Optional: pin the control-plane subnet (leave var empty to let CMK auto-select).
  subnet_id = var.cluster_subnet_id != "" ? var.cluster_subnet_id : null
}

# -----------------------------------------------------------------------------
# Node Pools
# -----------------------------------------------------------------------------
resource "crusoe_kubernetes_node_pool" "amd" {
  count          = var.amd_node_count > 0 ? 1 : 0
  name           = var.amd_pool_name
  cluster_id     = crusoe_kubernetes_cluster.kserve_amd.id
  instance_count = var.amd_node_count
  type           = var.amd_node_type
  # MI355X node pools run a gfx950-compatible node image that differs from the cluster version.
  version = var.node_pool_version != "" ? var.node_pool_version : null
  # The ~30 GB gfx950 ROCm image needs containerd on node ephemeral storage.
  ephemeral_storage_for_containerd = var.amd_ephemeral_storage_for_containerd
  ssh_key                          = var.ssh_public_key != "" ? var.ssh_public_key : null
  ib_partition_id                  = var.amd_ib_partition_id
  project_id                       = var.project_id
}

resource "crusoe_kubernetes_node_pool" "cpu" {
  count          = var.cpu_node_count > 0 ? 1 : 0
  name           = var.cpu_pool_name
  cluster_id     = crusoe_kubernetes_cluster.kserve_amd.id
  instance_count = var.cpu_node_count
  type           = var.cpu_node_type
  # Keep the CPU pool on the same node-pool version as the AMD pool.
  version    = var.node_pool_version != "" ? var.node_pool_version : null
  ssh_key    = var.ssh_public_key != "" ? var.ssh_public_key : null
  project_id = var.project_id
}

# -----------------------------------------------------------------------------
# Kubeconfig — fetch credentials after cluster + node pools are ready
# -----------------------------------------------------------------------------
resource "null_resource" "kubeconfig" {
  depends_on = [
    crusoe_kubernetes_cluster.kserve_amd,
    crusoe_kubernetes_node_pool.amd,
    crusoe_kubernetes_node_pool.cpu,
  ]

  provisioner "local-exec" {
    command = "crusoe kubernetes clusters get-credentials ${crusoe_kubernetes_cluster.kserve_amd.name} --project-id ${var.project_id} -y"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "cluster_name" {
  value = crusoe_kubernetes_cluster.kserve_amd.name
}

output "next_steps" {
  value = "Cluster + node pools ready with CMK-managed AMD add-ons. Next: verify 'amd.com/gpu' on nodes, then run 'make install-kserve' and 'make deploy-amd-mi355x'."
}
