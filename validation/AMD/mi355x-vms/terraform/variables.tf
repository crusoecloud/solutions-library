variable "project_id" {
  description = "Crusoe project ID."
  type        = string
}

variable "location" {
  description = "Location to create the VMs in."
  type        = string
  default     = "us-east2-a"
}

variable "node_count" {
  description = "Number of MI355X VMs to create."
  type        = number
  default     = 1
}

variable "name_prefix" {
  description = "Prefix for VM and partition names. Must be unique within the project."
  type        = string
  default     = "mi355x-val"
}

variable "node_type" {
  description = "VM instance type."
  type        = string
  default     = "mi355x-288gb-roce.8x"
}

variable "image" {
  description = "VM image name:tag."
  type        = string
  default     = "ubuntu24.04-amd-mi355-vm-bundle2.2:2026-10-05"

  validation {
    condition     = can(regex("^[^:]+:[^:]+$", var.image))
    error_message = "image must be an explicit name:tag (e.g. ubuntu24.04-amd-mi355-vm-bundle2.2:2026-10-05), not 'latest' or an untagged name."
  }
}

variable "vpc_subnet_id" {
  description = "VPC subnet ID in var.location."
  type        = string
}

variable "transport_network_id" {
  description = "RoCE transport network ID for MI355X in var.location."
  type        = string
}

variable "create_partition" {
  description = "Create a dedicated transport partition for this cluster. If false, existing_partition_id is used."
  type        = bool
  default     = false
}

variable "existing_partition_id" {
  description = "Existing transport partition ID (only used when create_partition = false)."
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key; the only key authorized on the VMs (e.g. ~/.ssh/id_ed25519.pub). Changing the key contents recreates all VMs."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the private key matching ssh_public_key_path, written into the Ansible inventory. Defaults to ssh_public_key_path without the .pub suffix."
  type        = string
  default     = null
}

variable "public_ip_type" {
  description = "Public IPv4 allocation type (dynamic or static)."
  type        = string
  default     = "dynamic"
}
