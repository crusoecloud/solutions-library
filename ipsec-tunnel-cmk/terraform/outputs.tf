output "ha_vpn_gateway_name" {
  description = "Name of the GCP HA VPN Gateway"
  value       = google_compute_ha_vpn_gateway.ha_vpn.name
}

output "peer_gateway_name" {
  description = "Name of the external peer VPN gateway"
  value       = google_compute_external_vpn_gateway.peer.name
}

output "tunnel1_name" {
  description = "Name of tunnel 1"
  value       = google_compute_vpn_tunnel.tunnel1.name
}

output "tunnel2_name" {
  description = "Name of tunnel 2"
  value       = google_compute_vpn_tunnel.tunnel2.name
}

output "cloud_router_name" {
  description = "Name of the Cloud Router"
  value       = google_compute_router.router.name
}

output "bgp_link_local_ips" {
  description = "Derived link-local IP pairs per tunnel: [gcp_ip, peer_ip]"
  value       = [
    {
      gcp  = local.gcp_bgp_ip_1
      k8s = local.peer_bgp_ip_1
    },
    {
      gcp  = local.gcp_bgp_ip_2
      k8s = local.peer_bgp_ip_2
    }
  ]
}
