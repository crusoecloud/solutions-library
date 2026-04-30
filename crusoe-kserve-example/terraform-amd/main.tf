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
# AMD clusters use crusoe_csi only — no nvidia add-ons needed.
# The AMD GPU operator is installed separately by make setup-amd.
# -----------------------------------------------------------------------------
resource "crusoe_kubernetes_cluster" "kserve_amd" {
  name       = var.cluster_name
  version    = var.cluster_version
  location   = var.location
  project_id = var.project_id
  add_ons    = ["crusoe_csi"]
}

# -----------------------------------------------------------------------------
# Node Pools
# -----------------------------------------------------------------------------
resource "crusoe_kubernetes_node_pool" "amd" {
  count           = var.amd_node_count > 0 ? 1 : 0
  name            = var.amd_pool_name
  cluster_id      = crusoe_kubernetes_cluster.kserve_amd.id
  instance_count  = var.amd_node_count
  type            = var.amd_node_type
  ssh_key         = var.ssh_public_key != "" ? var.ssh_public_key : null
  ib_partition_id = var.amd_ib_partition_id
  project_id      = var.project_id
}

resource "crusoe_kubernetes_node_pool" "cpu" {
  count          = var.cpu_node_count > 0 ? 1 : 0
  name           = var.cpu_pool_name
  cluster_id     = crusoe_kubernetes_cluster.kserve_amd.id
  instance_count = var.cpu_node_count
  type           = var.cpu_node_type
  ssh_key        = var.ssh_public_key != "" ? var.ssh_public_key : null
  project_id     = var.project_id
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
  value = "Cluster and node pools are ready. make setup-amd will now install the AMD GPU operator and KServe."
}
