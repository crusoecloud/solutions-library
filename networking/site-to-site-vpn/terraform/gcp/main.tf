locals {
  # GCP gets host 1 of each /30, Crusoe host 2
  gcp_bgp_ips    = [for c in var.bgp_inside_cidrs : cidrhost(c, 1)]
  crusoe_bgp_ips = [for c in var.bgp_inside_cidrs : cidrhost(c, 2)]
  redundancy     = length(var.crusoe_public_ips) == 1 ? "SINGLE_IP_INTERNALLY_REDUNDANT" : "TWO_IPS_REDUNDANCY"
}

resource "google_compute_network" "vpn" {
  count                   = var.create_network ? 1 : 0
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
}

data "google_compute_network" "existing" {
  count   = var.create_network ? 0 : 1
  name    = var.network_name
  project = var.project_id
}

locals {
  network_id = var.create_network ? google_compute_network.vpn[0].id : data.google_compute_network.existing[0].id
}

resource "google_compute_subnetwork" "vpn" {
  count         = var.create_network ? 1 : 0
  name          = "${var.deployment_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = local.network_id
  ip_cidr_range = var.subnet_cidr
}

resource "google_compute_ha_vpn_gateway" "gw" {
  name    = "${var.deployment_name}-ha-gw"
  project = var.project_id
  region  = var.region
  network = local.network_id
}

resource "google_compute_external_vpn_gateway" "crusoe" {
  name            = "${var.deployment_name}-crusoe-gw"
  project         = var.project_id
  redundancy_type = local.redundancy
  dynamic "interface" {
    for_each = var.crusoe_public_ips
    content {
      id         = interface.key
      ip_address = interface.value
    }
  }
}

resource "google_compute_router" "router" {
  name    = "${var.deployment_name}-router"
  project = var.project_id
  region  = var.region
  network = local.network_id
  bgp {
    asn = var.gcp_asn
  }
}

resource "google_compute_vpn_tunnel" "tunnel" {
  count                           = 2
  name                            = "${var.deployment_name}-tunnel-${count.index}"
  project                         = var.project_id
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.gw.id
  vpn_gateway_interface           = count.index
  peer_external_gateway           = google_compute_external_vpn_gateway.crusoe.id
  peer_external_gateway_interface = length(var.crusoe_public_ips) == 1 ? 0 : count.index
  shared_secret                   = var.tunnel_psks[count.index]
  router                          = google_compute_router.router.id
  ike_version                     = 2
}

resource "google_compute_router_interface" "iface" {
  count      = 2
  name       = "${var.deployment_name}-iface-${count.index}"
  project    = var.project_id
  region     = var.region
  router     = google_compute_router.router.name
  ip_range   = "${local.gcp_bgp_ips[count.index]}/30"
  vpn_tunnel = google_compute_vpn_tunnel.tunnel[count.index].name
}

resource "google_compute_router_peer" "peer" {
  count                     = 2
  name                      = "${var.deployment_name}-peer-${count.index}"
  project                   = var.project_id
  region                    = var.region
  router                    = google_compute_router.router.name
  peer_ip_address           = local.crusoe_bgp_ips[count.index]
  peer_asn                  = var.crusoe_asn
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.iface[count.index].name
}

resource "google_compute_firewall" "allow_crusoe" {
  name      = "${var.deployment_name}-allow-crusoe"
  project   = var.project_id
  network   = local.network_id
  direction = "INGRESS"
  allow { protocol = "icmp" }
  allow {
    protocol = "tcp"
    ports    = ["22", "5201"]
  }
  allow {
    protocol = "udp"
    ports    = ["5201"]
  }
  source_ranges = var.crusoe_source_ranges
}
