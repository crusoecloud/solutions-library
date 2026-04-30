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
  default     = "1.33.4-cmk.43"
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
