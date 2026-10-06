variable "project_id" { type = string }
variable "region" { type = string }
variable "network_name" {
  description = "Existing VPC network name (or set create_network=true)."
  type        = string
  default     = "vpn-test"
}
variable "create_network" {
  type    = bool
  default = true
}
variable "subnet_cidr" {
  description = "GCP-side test subnet CIDR (the 'customer CIDR')."
  type        = string
  default     = "10.200.0.0/16"
}
variable "gcp_asn" {
  type    = number
  default = 64514
}
variable "crusoe_asn" { type = number }
variable "crusoe_public_ips" {
  description = "Crusoe VPN VM public IP(s). One IP => single-interface external gateway; two => two-interface."
  type        = list(string)
  validation {
    condition     = contains([1, 2], length(var.crusoe_public_ips))
    error_message = "One (single) or two (dual) Crusoe public IPs."
  }
}
variable "tunnel_psks" {
  description = "PSK per tunnel index (0,1). Same values fed to the Crusoe side."
  type        = list(string)
  sensitive   = true
  validation {
    condition     = length(var.tunnel_psks) == 2
    error_message = "Exactly two PSKs required (one per HA VPN tunnel)."
  }
}
variable "bgp_inside_cidrs" {
  description = "Link-local /30 per tunnel, e.g. [\"169.254.21.0/30\", \"169.254.22.0/30\"]. GCP takes .1, Crusoe .2."
  type        = list(string)
  validation {
    condition     = length(var.bgp_inside_cidrs) == 2
    error_message = "Exactly two inside /30 CIDRs required."
  }
}
variable "crusoe_source_ranges" {
  description = "Source ranges allowed through the test firewall; tighten to your crusoe_vpc_cidrs."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}
variable "deployment_name" {
  type    = string
  default = "crusoe-vpn"
}
