variable "project_id" {
  description = "Crusoe Cloud project ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the CMK cluster"
  type        = string
  default     = "kserve-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the cluster"
  type        = string
  default     = "1.33.4-cmk.43"
}

variable "location" {
  description = "Crusoe Cloud location"
  type        = string
  default     = "us-east1-a"
}

# --- A100 Node Pool (decode) ---

variable "a100_pool_name" {
  description = "Name of the A100 node pool"
  type        = string
  default     = "a100-pool"
}

variable "a100_node_count" {
  description = "Number of A100 nodes"
  type        = number
  default     = 2
}

variable "a100_node_type" {
  description = "A100 node instance type"
  type        = string
  default     = "a100-80gb-sxm-ib.8x"
}

variable "a100_ib_partition_id" {
  description = "InfiniBand partition ID for A100 node pool"
  type        = string
  default     = ""
}

# --- H100 Node Pool (prefill) ---

variable "h100_pool_name" {
  description = "Name of the H100 node pool"
  type        = string
  default     = "h100-pool"
}

variable "h100_node_count" {
  description = "Number of H100 nodes"
  type        = number
  default     = 1
}

variable "h100_node_type" {
  description = "H100 node instance type"
  type        = string
  default     = "h100-80gb-sxm-ib.8x"
}

variable "h100_ib_partition_id" {
  description = "InfiniBand partition ID for H100 node pool"
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
