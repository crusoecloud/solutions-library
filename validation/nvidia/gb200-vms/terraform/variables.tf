variable "project_id" {
  description = "Crusoe project ID to create the VMs in."
  type        = string
}

variable "location" {
  description = "Location to create the VMs in. GB200 is offered in eu-iceland1-a."
  type        = string
  default     = "eu-iceland1-a"
}

variable "name_prefix" {
  description = "Prefix for VM and partition names. Must be unique within the project."
  type        = string
  default     = "gb200-val"
}

# ---------------------------------------------------------------- GB200 nodes
variable "gpu_node_count" {
  description = "Number of GB200 VMs (4 GPUs each). All are placed in one NVLink domain; a full NVL72 rack is 18."
  type        = number
  default     = 14

  validation {
    condition     = var.gpu_node_count >= 1 && var.gpu_node_count <= 18
    error_message = "gpu_node_count must be 1-18 (one NVLink domain holds at most 18 GB200 VMs)."
  }
}

variable "gpu_node_type" {
  description = "GB200 VM type. -ib types also attach the InfiniBand rails (a transport partition is created or reused)."
  type        = string
  default     = "gb200-186gb-nvl-ib.4x"
}

variable "gpu_image" {
  description = "GB200 VM image name:tag (arm64)."
  type        = string
  default     = "ubuntu24.04-nvidia-b.gb200.1.0:latest"

  validation {
    condition     = can(regex("^[^:]+:[^:]+$", var.gpu_image))
    error_message = "gpu_image must be name:tag."
  }
}

variable "nvlink_domain_id" {
  description = "NVLink domain (rack) for all GB200 VMs. Required when gpu_node_count > 1 (a single canary may omit it). List domains and available_nodes with: crusoe networking nvl-domains list --project-id <project-id>."
  type        = string
  default     = null
}

variable "transport_partition_id" {
  description = "Existing transport (IB) partition for -ib GB200 types. If null, one named <name_prefix>-ib is created on the location's GB200 transport network."
  type        = string
  default     = null
}

variable "transport_network_id" {
  description = "Transport network to create the partition on. If null, picked from the project's networks in this location that list gpu_node_type capacity."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- CPU nodes
variable "cpu_node_count" {
  description = "Number of general-purpose CPU VMs (optional; the tests only need the GB200 VMs)."
  type        = number
  default     = 0
}

variable "cpu_node_type" {
  description = "CPU VM type."
  type        = string
  default     = "c1a.32x"
}

variable "cpu_image" {
  description = "CPU VM image name:tag."
  type        = string
  default     = "ubuntu24.04:latest"
}

# ---------------------------------------------------------------- networking / access
variable "vpc_subnet_id" {
  description = "VPC subnet for all VMs. If null, the project's first subnet in this location is used."
  type        = string
  default     = null
}

variable "public_ip_type" {
  description = "Public IPv4 allocation type (dynamic or static)."
  type        = string
  default     = "dynamic"
}

variable "static_public_ip_nodes" {
  description = "GB200 VM names whose public IPv4 is static (overrides public_ip_type). List VMs switched to a static IP outside Terraform here; the API rejects changing them back."
  type        = list(string)
  default     = []
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key; the only key authorized on the VMs (e.g. ~/.ssh/id_ed25519.pub). Changing the key contents recreates all VMs."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key matching ssh_public_key_path, written into the Ansible inventory. Defaults to ssh_public_key_path without .pub."
  type        = string
  default     = null
}
