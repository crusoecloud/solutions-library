locals {
  # Derive link-local IPs from peers[*].bgp_cidr
  gcp_bgp_ip_1  = cidrhost(var.peers[0].bgp_cidr, 1)
  peer_bgp_ip_1 = cidrhost(var.peers[0].bgp_cidr, 2)
  gcp_bgp_ip_2  = cidrhost(var.peers[1].bgp_cidr, 1)
  peer_bgp_ip_2 = cidrhost(var.peers[1].bgp_cidr, 2)
}

resource "google_compute_ha_vpn_gateway" "ha_vpn" {
  name    = "ha-vpn-gateway"
  network = var.network
  region  = var.region
}

resource "google_compute_external_vpn_gateway" "peer" {
  name = var.peer_gateway_name
  redundancy_type = "TWO_IPS_REDUNDANCY"
    interface {
      id         = 0
      ip_address = var.peers[0].node_public_ip
    }
  
    interface {
      id         = 1
      ip_address = var.peers[1].node_public_ip
    }
}

# Tunnels
resource "google_compute_vpn_tunnel" "tunnel1" {
  name                  = "ha-vpn-tunnel-1"
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.ha_vpn.id
  vpn_gateway_interface = 0
  peer_external_gateway = google_compute_external_vpn_gateway.peer.id
  peer_external_gateway_interface = 0
  shared_secret         = random_password.psk1.result

  router                = google_compute_router.router.name

  ike_version           = 2
}

resource "google_compute_vpn_tunnel" "tunnel2" {
  name                  = "ha-vpn-tunnel-2"
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.ha_vpn.id
  vpn_gateway_interface = 1
  peer_external_gateway = google_compute_external_vpn_gateway.peer.id
  peer_external_gateway_interface = 1
  shared_secret         = random_password.psk2.result

  router                = google_compute_router.router.name

  ike_version           = 2
}

# Cloud Router
resource "google_compute_router" "router" {
  name    = var.gcp_router_name
  network = var.network
  region  = var.region
  bgp {
    asn = var.gcp_router_asn
  }
}

# Router interfaces for BGP link-local addresses
resource "google_compute_router_interface" "if1" {
  name       = "if-tunnel-1"
  router     = google_compute_router.router.name
  region     = var.region
  ip_range   = "${local.gcp_bgp_ip_1}/30"
  vpn_tunnel = google_compute_vpn_tunnel.tunnel1.name
}

resource "google_compute_router_interface" "if2" {
  name       = "if-tunnel-2"
  router     = google_compute_router.router.name
  region     = var.region
  ip_range   = "${local.gcp_bgp_ip_2}/30"
  vpn_tunnel = google_compute_vpn_tunnel.tunnel2.name
}

# BGP peers on the Cloud Router
resource "google_compute_router_peer" "peer1" {
  name            = "peer1"
  router          = google_compute_router.router.name
  region          = var.region
  peer_ip_address = local.peer_bgp_ip_1
  peer_asn        = var.local_asn
  interface       = google_compute_router_interface.if1.name
  advertise_mode  = "DEFAULT"
}

resource "google_compute_router_peer" "peer2" {
  name            = "peer2"
  router          = google_compute_router.router.name
  region          = var.region
  peer_ip_address = local.peer_bgp_ip_2
  peer_asn        = var.local_asn
  interface       = google_compute_router_interface.if2.name
  advertise_mode  = "DEFAULT"
}

# Helm release wiring: use outputs for chart values
resource "helm_release" "ipsec_bridge" {
  name       = var.release_name
  chart      = var.chart_path
  namespace  = var.namespace

  # Align with chart schema: tunnels list with required fields
  set = [
    { name = "tunnels[0].publicIP",      value = google_compute_ha_vpn_gateway.ha_vpn.vpn_interfaces[0].ip_address },
    { name = "tunnels[0].internalIP",    value = var.peers[0].node_internal_ip },
    { name = "tunnels[0].localTunnelIP", value = local.peer_bgp_ip_1 },
    { name = "tunnels[0].peerTunnelIP",  value = local.gcp_bgp_ip_1 },
    { name = "tunnels[0].nodeName",      value = var.peers[0].node_name },

    { name = "tunnels[1].publicIP",      value = google_compute_ha_vpn_gateway.ha_vpn.vpn_interfaces[1].ip_address },
    { name = "tunnels[1].internalIP",    value = var.peers[1].node_internal_ip },
    { name = "tunnels[1].localTunnelIP", value = local.peer_bgp_ip_2 },
    { name = "tunnels[1].peerTunnelIP",  value = local.gcp_bgp_ip_2 },
    { name = "tunnels[1].nodeName",      value = var.peers[1].node_name },

    { name = "bgp.localASN",             value = var.local_asn },
    { name = "bgp.peerASN",              value = var.gcp_router_asn },
  ]

  set_sensitive = [
    { name = "tunnels[0].psk", value = random_password.psk1.result },
    { name = "tunnels[1].psk", value = random_password.psk2.result }
  ]
}

# Randomly generate tunnel shared secrets
resource "random_password" "psk1" {
  length  = 32
  special = false
}

resource "random_password" "psk2" {
  length  = 32
  special = false
}
