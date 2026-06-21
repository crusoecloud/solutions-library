# ============================================================
# Shared
# ============================================================

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorized to log in to source server VMs."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# ============================================================
# Source (nginx file servers)
# ============================================================

variable "source_server_location" {
  description = "Crusoe location for the source nginx servers (e.g. us-east1-a)."
  type        = string
}

variable "source_server_project_id" {
  description = "Crusoe project ID for the source nginx servers."
  type        = string
}

variable "source_server_vpc_subnet_id" {
  description = "VPC subnet ID in the source location for the nginx server VMs."
  type        = string
}

variable "source_server_groups" {
  description = "List of source server groups. Each entry provisions vm_count VMs of vm_type. Multiple groups allow mixing instance types."
  type = list(object({
    vm_type  = string
    vm_count = number
  }))
}

variable "http_user" {
  description = "Username for nginx HTTP basic authentication."
  type        = string
}

variable "http_password" {
  description = "Password for nginx HTTP basic authentication."
  type        = string
  sensitive   = true
}

variable "source_disk_id" {
  description = "UUID of the existing Crusoe shared disk to serve via nginx."
  type        = string
}

variable "source_disk_mount_path" {
  description = "Filesystem path where the source disk is mounted on the source VMs."
  type        = string
  default     = "/vast"
}

variable "source_serve_path" {
  description = "Path within the source disk mount to serve over HTTP. Defaults to the mount root."
  type        = string
  default     = "/vast"
}


# ============================================================
# Destination (Kubernetes cluster + storage)
# ============================================================

variable "destination_location" {
  description = "Crusoe location for the destination Kubernetes cluster and storage disk."
  type        = string
}

variable "destination_project_id" {
  description = "Crusoe project ID for the destination resources."
  type        = string
}

variable "cluster_name" {
  description = "Name for the destination Kubernetes cluster."
  type        = string
  default     = "data-transfer-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the destination cluster (e.g. 1.35.5-cmk.7)."
  type        = string
}

variable "cluster_subnet_id" {
  description = "VPC subnet ID for the Kubernetes cluster and node pools."
  type        = string
}

variable "nodepool_version" {
  description = "Kubernetes version for the aria2c node pools (e.g. 1.35.5-cmk.10)."
  type        = string
}

variable "nodepool_groups" {
  description = "List of destination nodepool groups. Each entry creates a node pool with vm_count VMs of vm_type. Multiple groups allow mixing instance types."
  type = list(object({
    vm_type  = string
    vm_count = number
  }))
}

variable "destination_disk_id" {
  description = "UUID of the destination shared disk to write data to."
  type        = string
}

variable "destination_disk_mount_path" {
  description = "Mount path on the destination cluster for the PVC (used as the dir= value in downloads.txt)."
  type        = string
  default     = "/vast"
}

# ============================================================
# Grafana CMK (optional observability)
# ============================================================

variable "grafana_cmk_manifests_path" {
  description = "Local path to the grafana-cmk/manifests directory from the solutions-library repo."
  type        = string
  default     = "../grafana-cmk/manifests"
}

variable "grafana_monitoring_token" {
  description = "Crusoe monitoring token for Grafana datasource. Create with: crusoe monitoring tokens create"
  type        = string
  default     = ""
  sensitive   = true
}
