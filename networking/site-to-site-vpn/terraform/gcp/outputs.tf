output "gcp_vpn_public_ips" {
  description = "Feed these into params.tfvars as tunnels[*].peer_public_ip."
  value = [
    google_compute_ha_vpn_gateway.gw.vpn_interfaces[0].ip_address,
    google_compute_ha_vpn_gateway.gw.vpn_interfaces[1].ip_address,
  ]
}
output "gcp_asn" { value = var.gcp_asn }
output "gcp_bgp_ips" { value = local.gcp_bgp_ips }
output "crusoe_bgp_ips" { value = local.crusoe_bgp_ips }
output "subnet_cidr" { value = var.subnet_cidr }
