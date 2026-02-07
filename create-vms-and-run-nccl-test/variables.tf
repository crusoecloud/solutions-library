variable "ssh_public_key_path" {
  description = "The ssh public key authorized to login to the cluster."
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
}

variable "node_name_prefix" {
  description = "Name prefix for nodes"
  type = string
  default = "node"
}

# This is only required when using an infiniband enabled instance type for the compute nodes.
variable "ib_partition_id" {
  description = "The ib partition id for compute nodes."
  type        = string
  default     = null
}

variable "node_reservation_id" {
  description = "The partition1 compute node reservation id"
  type        = string
  default     = null
}

variable "image_name" {
  description = "name:tag of image"
  type        = string
  default     = null
}

variable "imex_support" {
  description = "If true, create IMEX nodes file"
  type        = bool
  default     = false
}