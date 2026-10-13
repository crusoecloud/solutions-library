deployment_name      = "acme-gcp"
cloud                = "gcp"
ha_mode              = "single"
crusoe_project_id    = "REPLACE-crusoe-project-uuid"
crusoe_location      = "us-east1-a"
crusoe_vpc_subnet_id = "REPLACE-subnet-uuid"
crusoe_vpc_cidrs     = ["10.100.0.0/16"]
customer_cidrs       = ["10.200.0.0/16"]
local_asn            = 65000
ssh_allowed_cidrs    = ["198.51.100.0/24"] # your office/VPN egress, never 0.0.0.0/0
ssh_public_keys      = ["ssh-ed25519 AAAA... you@example.com"]

tunnels = [
  {
    name            = "tunnel-a"
    peer_public_ip  = "203.0.113.10" # GCP HA VPN interface 0 IP
    psk_var_name    = "PSK_TUNNEL_A"
    xfrm_if_id      = 101
    bgp_local_ip    = "169.254.21.2"
    bgp_remote_ip   = "169.254.21.1"
    bgp_inside_cidr = "169.254.21.0/30"
    remote_asn      = 64514
    vm_index        = 0
  },
  {
    name            = "tunnel-b"
    peer_public_ip  = "203.0.113.11" # GCP HA VPN interface 1 IP
    psk_var_name    = "PSK_TUNNEL_B"
    xfrm_if_id      = 102
    bgp_local_ip    = "169.254.22.2"
    bgp_remote_ip   = "169.254.22.1"
    bgp_inside_cidr = "169.254.22.0/30"
    remote_asn      = 64514
    vm_index        = 0
  },
]

# PSKs: NEVER put real values in any tfvars file. Supply at apply time:
#   export TF_VAR_tunnel_psks='{"PSK_TUNNEL_A":"...","PSK_TUNNEL_B":"..."}'
