variable "project_id" {
  description = "Crusoe Cloud project ID"
  type        = string
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

variable "enable_session_logging" {
  description = "Enable SSH session logging and recording"
  type        = bool
  default     = true
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

variable "admin_username" {
  description = "Admin username for the bastion host"
  type        = string
  default     = "bastionadmin"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Purpose = "bastion-host"
    Managed = "terraform"
  }
}

variable "auto_update_enabled" {
  description = "Enable automatic security updates"
  type        = bool
  default     = true
}

variable "fail2ban_enabled" {
  description = "Enable fail2ban intrusion prevention"
  type        = bool
  default     = true
}

variable "ssh_port" {
  description = "SSH port (default 22, can be changed for additional security)"
  type        = number
  default     = 22
}

variable "session_timeout_seconds" {
  description = "SSH session timeout in seconds"
  type        = number
  default     = 900
}
