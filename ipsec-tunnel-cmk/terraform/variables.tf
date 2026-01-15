variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for HA VPN"
  type        = string
  default     = "us-central1"
}

variable "network" {
  description = "VPC network name to attach HA VPN"
  type        = string
}

variable "gcp_router_name" {
  description = "Cloud Router name"
  type        = string
  default     = "ipsec-tunnel-router"
}

variable "gcp_router_asn" {
  description = "BGP ASN for GCP Cloud Router"
  type        = number
  default     = 64514
}

variable "local_asn" {
  type    = number
  default = 65010
}

variable "peer_gateway_name" {
  description = "External peer VPN gateway name"
  type        = string
  default     = "peer-external-gw"
}

variable "peers" {
  description = "List of peer tunnel definitions"
  type = list(object({
    node_name        = string
    node_public_ip   = string
    node_internal_ip = string
    bgp_cidr         = string
  }))
  default = []

  validation {
    condition     = length(var.peers) == 2
    error_message = "peers must contain exactly 2 entries (for HA VPN)."
  }
}

variable "namespace" {
  description = "Namespace to install ipsec-tunnel"
  type        = string
  default     = "kube-system"
}

variable "release_name" {
  description = "Helm release name for ipsec-tunnel-chart"
  type        = string
  default     = "ipsec-tunnel"
}

variable "chart_path" {
  description = "Local path to ipsec-tunnel-chart"
  type        = string
  default     = "../ipsec-tunnel-chart"
}
