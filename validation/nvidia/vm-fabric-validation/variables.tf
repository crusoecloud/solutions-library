variable "ssh_public_key_path" {
  description = "The ssh public key authorized to log in to the cluster."
  type        = string
}

variable "ssh_private_key_path" {
  description = "The ssh private key authorized to log in to the cluster."
  type        = string
}

variable "location" {
  description = "The location in which to create the cluster."
  type        = string
}

variable "project_id" {
  description = "The project in which to create the cluster."
  type        = string
}

variable "vpc_subnet_id" {
  description = "The vpc subnet id."
  type        = string
  default     = null
}


variable "node_type" {
  description = "The  compute node instance type."
  type        = string
}

variable "node_count" {
  description = "The number of compute nodes."
  type        = number

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "node_name_prefix" {
  description = "Name prefix for nodes"
  type        = string
  default     = "node"
}

# Required for InfiniBand (-ib) instance types. Replaces the deprecated ib_partition_id.
# List partitions with: crusoe networking transport-partitions list
variable "transport_partition_id" {
  description = "The transport partition id for compute nodes."
  type        = string
  default     = null
}

variable "image_name" {
  description = "Crusoe NVIDIA image for node_type, for example ubuntu24.04-nvidia-b.b300.1.1 (see terraform.tfvars.example)."
  type        = string

  # Without it the provider picks its default image, and the tests fail later with unclear errors
  validation {
    condition     = try(trimspace(var.image_name), "") != ""
    error_message = "image_name is required: uncomment the image_name for your SKU in terraform.tfvars."
  }
}

variable "raid0_enabled" {
  description = "Combine local NVMe disks into a RAID0 array mounted at /raid0. Once built, a later apply with false fails (the array is not removed)."
  type        = bool
  default     = false
}