variable "project_id" {
  description = "Crusoe Cloud project ID"
  type        = string
}

variable "vpc_network" {
  description = "VPC network name for firewall rules"
  type        = string
  default     = "default-vpc-network"
}

variable "location" {
  description = "Crusoe Cloud location (e.g., us-east1-a)"
  type        = string
}

variable "bastion_name" {
  description = "Name for the bastion host instance"
  type        = string
  default     = "bastion-host"
}

variable "instance_type" {
  description = "Instance type for the bastion host"
  type        = string
  default     = "c1a.2x"
}

variable "disk_size_gib" {
  description = "Root disk size in GiB"
  type        = number
  default     = 32
}

variable "ssh_public_key" {
  description = "SSH public key for bastion access"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to the bastion"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ha_enabled" {
  description = "Enable high availability mode (deploy multiple bastions)"
  type        = bool
  default     = false
}

variable "ha_count" {
  description = "Number of bastion hosts to deploy in HA mode"
  type        = number
  default     = 2
}

variable "ssh_port" {
  description = "SSH port for firewall rules (default 22)"
  type        = number
  default     = 22
}
