variable "project_id" {
  description = "Crusoe Cloud project ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the CMK cluster"
  type        = string
  default     = "kserve-amd-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the cluster"
  type        = string
  default     = "1.35.5-cmk.13"
}

variable "cluster_subnet_id" {
  description = <<-EOT
    Optional VPC subnet ID to pin the cluster/control-plane into. Leave "" to let
    CMK auto-select the default subnet for the location. Must be a subnet in the
    cluster's location (e.g. default-subnet-us-east2-a).
  EOT
  type        = string
  default     = ""
}

variable "cluster_add_ons" {
  description = <<-EOT
    CMK add-ons to enable on the cluster. Default enables the CMK-managed AMD
    GPU + network operators (no manual GPU-operator install / Docker Hub creds
    needed). Requires an AMD "Bundle 1" cluster version (e.g. 1.33.4-cmk.93).
    For the legacy path, set to ["crusoe_csi"] and run `make install-amd-gpu-operator`.
  EOT
  type        = list(string)
  default     = ["amd_network_operator", "amd_gpu_operator", "crusoe_csi"]
}

variable "location" {
  description = "Crusoe Cloud location (e.g. us-east1-a)"
  type        = string
  default     = "us-east1-a"
}

# --- SSH Key ---

variable "ssh_public_key" {
  description = "SSH public key for node pool access"
  type        = string
  default     = ""
  # Crusoe provisions this key onto every node at creation time — it cannot be
  # added later without destroying and recreating the node pool. Set this to
  # your public key (e.g. contents of ~/.ssh/id_ed25519.pub) so you can SSH
  # directly into AMD GPU nodes for debugging (e.g. rocm-smi, driver issues).
}

# --- Credentials (read by make setup-amd, not used by Terraform directly) ---

variable "hf_token" {
  description = "HuggingFace API token — used by make setup-amd to create the k8s secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "docker_username" {
  description = "Docker Hub username — used by make setup-amd to push the AMD GPU driver image"
  type        = string
  default     = ""
}

variable "docker_email" {
  description = "Docker Hub email — used by make setup-amd"
  type        = string
  default     = ""
}

variable "docker_password" {
  description = "Docker Hub password — used by make setup-amd"
  type        = string
  sensitive   = true
  default     = ""
}

# --- AMD GPU Node Pool ---

variable "amd_pool_name" {
  description = "Name of the AMD GPU node pool"
  type        = string
  default     = "amd-pool"
}

variable "amd_node_count" {
  description = "Number of AMD GPU nodes"
  type        = number
  default     = 1
}

variable "amd_node_type" {
  description = "AMD GPU node instance type (e.g. mi300x-192gb-ib.8x)"
  type        = string
}

variable "node_pool_version" {
  description = <<-EOT
    Kubernetes version applied to BOTH node pools (AMD GPU + CPU), kept in sync.
    For MI355X (gfx950) this differs from the cluster version and must be a
    gfx950-compatible node image (Bundle 1). Leave "" to inherit the cluster version.
  EOT
  type        = string
  default     = "1.33.4-cmk.18"
}

variable "amd_ephemeral_storage_for_containerd" {
  description = <<-EOT
    Use node ephemeral storage for containerd's image/layer store. Recommended for
    MI355X — the gfx950 ROCm serving image is ~30 GB and overflows the small default
    containerd partition otherwise.
  EOT
  type        = bool
  default     = true
}

variable "amd_ib_partition_id" {
  description = "InfiniBand partition ID for the AMD GPU node pool"
  type        = string
  default     = ""
}

# --- CPU Node Pool ---

variable "cpu_pool_name" {
  description = "Name of the CPU node pool"
  type        = string
  default     = "cpu-pool"
}

variable "cpu_node_count" {
  description = "Number of CPU nodes"
  type        = number
  default     = 2
}

variable "cpu_node_type" {
  description = "CPU node instance type"
  type        = string
  default     = "c1a.4x"
}
