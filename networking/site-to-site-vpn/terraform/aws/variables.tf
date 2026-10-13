variable "region" { type = string }
variable "deployment_name" {
  type    = string
  default = "crusoe-vpn"
}
variable "vpc_id" {
  description = "Existing customer VPC to attach the TGW to."
  type        = string
}
variable "subnet_ids" {
  description = "Subnets for the TGW VPC attachment."
  type        = list(string)
}
variable "aws_asn" {
  type    = number
  default = 64512
}
variable "crusoe_asn" { type = number }
variable "crusoe_public_ip" {
  description = "Crusoe VPN VM public IP (one CGW per Crusoe VM; add a second module instance for ha_mode=dual)."
  type        = string
}
variable "bgp_inside_cidrs" {
  description = "Optional: pin the two tunnel inside CIDRs (169.254.x.x/30, AWS-reserved ranges excluded). Empty = AWS auto-assigns."
  type        = list(string)
  default     = []
  validation {
    condition     = contains([0, 2], length(var.bgp_inside_cidrs))
    error_message = "Supply zero (auto-assign) or exactly two inside CIDRs."
  }
}

variable "route_table_ids" {
  description = "Customer VPC route table IDs that should route Crusoe CIDRs at the TGW. Empty = you manage routes yourself."
  type        = list(string)
  default     = []
}

variable "crusoe_cidrs" {
  description = "Crusoe CIDRs to route toward the TGW from the customer VPC."
  type        = list(string)
  default     = []
}
