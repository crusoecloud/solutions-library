variable "deployment_name" {
  description = "Prefix for all resources; DNS-safe."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.deployment_name))
    error_message = "deployment_name must be DNS-safe: lowercase alphanumeric and hyphens, 2-31 chars."
  }
}

variable "cloud" {
  description = "Peer cloud: selects default crypto profile."
  type        = string
  validation {
    condition     = contains(["gcp", "aws"], var.cloud)
    error_message = "cloud must be \"gcp\" or \"aws\"."
  }
}

variable "ha_mode" {
  description = "single = one VM terminates all tunnels; dual = two VMs across fault domains."
  type        = string
  default     = "single"
  validation {
    condition     = contains(["single", "dual"], var.ha_mode)
    error_message = "ha_mode must be \"single\" or \"dual\"."
  }
}

variable "crusoe_project_id" {
  description = "Crusoe project ID."
  type        = string
}

variable "crusoe_location" {
  description = "Crusoe location, e.g. us-east1-a."
  type        = string
}

variable "crusoe_vpc_subnet_id" {
  description = "Existing Crusoe VPC subnet ID the VPN VM(s) attach to."
  type        = string
}

variable "crusoe_vpc_cidrs" {
  description = "CIDRs advertised to the customer via BGP."
  type        = list(string)
  validation {
    condition     = alltrue([for c in var.crusoe_vpc_cidrs : can(cidrhost(c, 0))])
    error_message = "Every crusoe_vpc_cidrs entry must be a valid CIDR."
  }
}

variable "customer_cidrs" {
  description = "Customer CIDRs expected via BGP (used for prefix filters and overlap checks)."
  type        = list(string)
  validation {
    condition     = alltrue([for c in var.customer_cidrs : can(cidrhost(c, 0))])
    error_message = "Every customer_cidrs entry must be a valid CIDR."
  }
}

variable "instance_type" {
  description = "Crusoe instance type for the VPN VM(s)."
  type        = string
  default     = "c1a.4x"
}

variable "image" {
  description = "Crusoe image."
  type        = string
  default     = "ubuntu24.04:latest"
}

variable "local_asn" {
  description = "Crusoe-side private BGP ASN."
  type        = number
  validation {
    condition     = (var.local_asn >= 64512 && var.local_asn <= 65534) || (var.local_asn >= 4200000000 && var.local_asn <= 4294967294)
    error_message = "local_asn must be a private ASN (64512-65534 or 4200000000-4294967294)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "Management SSH allow-list. Never 0.0.0.0/0."
  type        = list(string)
  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs must be non-empty and must not contain 0.0.0.0/0."
  }
}

variable "ssh_public_keys" {
  description = "SSH public keys injected at create time."
  type        = list(string)
  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "At least one SSH public key is required."
  }
}

variable "mss_clamp" {
  description = "TCP MSS clamp for forwarded traffic across the tunnel."
  type        = number
  default     = 1360
  validation {
    condition     = var.mss_clamp <= var.tunnel_mtu - 40
    error_message = "mss_clamp must be <= tunnel_mtu - 40."
  }
}

variable "tunnel_mtu" {
  description = "XFRM interface MTU."
  type        = number
  default     = 1400
}

variable "tunnels" {
  description = "Ordered list of IPsec tunnels; both GCP and AWS map onto this."
  type = list(object({
    name            = string
    peer_public_ip  = string
    psk_var_name    = string
    xfrm_if_id      = number
    bgp_local_ip    = string
    bgp_remote_ip   = string
    bgp_inside_cidr = string
    remote_asn      = number
    vm_index        = number
  }))
  validation {
    condition     = length(var.tunnels) >= 1
    error_message = "At least one tunnel is required; two are recommended."
  }
  validation {
    condition     = length(distinct([for t in var.tunnels : t.xfrm_if_id])) == length(var.tunnels)
    error_message = "xfrm_if_id must be unique per tunnel."
  }
  validation {
    condition     = length(distinct([for t in var.tunnels : t.name])) == length(var.tunnels)
    error_message = "tunnel names must be unique."
  }
  validation {
    condition     = alltrue([for t in var.tunnels : t.vm_index >= 0 && t.vm_index <= 1])
    error_message = "vm_index must be 0 or 1."
  }
  validation {
    condition     = alltrue([for t in var.tunnels : can(regex("^[a-z][a-z0-9-]{0,30}$", t.name))])
    error_message = "tunnel names must be lowercase alphanumeric/hyphen, start with a letter, max 31 chars."
  }
  validation {
    condition     = alltrue([for t in var.tunnels : can(cidrhost(t.bgp_inside_cidr, 0))])
    error_message = "bgp_inside_cidr must be a valid CIDR."
  }
  validation {
    condition     = length(distinct([for t in var.tunnels : t.bgp_inside_cidr])) == length(var.tunnels)
    error_message = "bgp_inside_cidr must be unique per tunnel."
  }
}

variable "tunnel_psks" {
  description = "Map from psk_var_name to PSK value. Supply via TF_VAR_tunnel_psks env or a secret store; NEVER commit. WARNING: PSKs are embedded in the instance startup script — they are visible in Terraform state and in Crusoe instance metadata to anyone with instance-describe access. Encrypt state at rest, restrict state access, and rotate PSKs if exposure is suspected."
  type        = map(string)
  sensitive   = true
  validation {
    condition     = alltrue([for k, v in var.tunnel_psks : length(v) >= 16 && can(regex("^[A-Za-z0-9+/=_.-]+$", v))])
    error_message = "PSKs must be >=16 chars and contain only [A-Za-z0-9+/=_.-] (no quotes, backslashes, spaces, or newlines)."
  }
}

variable "crypto_profile" {
  description = "IKE and ESP proposals. Null selects a per-cloud default (see docs/crypto-profiles.md)."
  type = object({
    ike_proposals = list(string)
    esp_proposals = list(string)
    ike_lifetime  = string
    esp_lifetime  = string
    dpd_delay     = string
    dpd_timeout   = string
    rekey_margin  = string
  })
  default = null
}

variable "cluster_egress" {
  description = <<-EOT
    Enable a vxlan overlay so other Crusoe hosts (CMK cluster nodes/pods, or
    plain VMs) can egress through this gateway to the remote peer. Crusoe's VPC
    fabric drops packets whose destination isn't the receiving VM, so a plain
    next-hop route can't transit — the overlay makes every host->gateway packet
    a real VM-to-VM (vxlan) frame. See docs/crusoe-cluster-egress.md and the
    node-side DaemonSet in k8s/cluster-egress/.
    Default disabled: the gateway then only carries its own traffic.
  EOT
  type = object({
    enabled      = bool
    vxlan_id     = number # VNI shared by gateway + nodes
    vxlan_port   = number # UDP dstport for vxlan transport
    overlay_cidr = string # /16 overlay; gateway = <base>.0.1, node = <base>.<3rd>.<4th octet of node IP>
  })
  default = {
    enabled      = false
    vxlan_id     = 100
    vxlan_port   = 4789
    overlay_cidr = "169.254.0.0/16"
  }
  validation {
    condition     = !var.cluster_egress.enabled || (can(cidrhost(var.cluster_egress.overlay_cidr, 1)) && split("/", var.cluster_egress.overlay_cidr)[1] == "16")
    error_message = "cluster_egress.overlay_cidr must be a valid /16 CIDR when enabled (nodes derive unique host IPs from the last two octets of their node IP)."
  }
}
