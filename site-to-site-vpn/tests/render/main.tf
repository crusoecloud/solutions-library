# Renders the real templates with fixture data so CI can grep required stanzas.
locals {
  crypto = {
    ike_proposals = ["aes256gcm16-prfsha384-ecp384"]
    esp_proposals = ["aes256gcm16-ecp384"]
    ike_lifetime  = "8h"
    esp_lifetime  = "1h"
    dpd_delay     = "30s"
    dpd_timeout   = "120s"
    rekey_margin  = "3m"
  }
  tunnels = [
    { name = "tunnel-a", peer_public_ip = "203.0.113.10", psk_var_name = "PSK_A", xfrm_if_id = 101, bgp_local_ip = "169.254.21.2", bgp_remote_ip = "169.254.21.1", bgp_inside_cidr = "169.254.21.0/30", remote_asn = 64514, vm_index = 0 },
    { name = "tunnel-b", peer_public_ip = "203.0.113.11", psk_var_name = "PSK_B", xfrm_if_id = 102, bgp_local_ip = "169.254.22.2", bgp_remote_ip = "169.254.22.1", bgp_inside_cidr = "169.254.22.0/30", remote_asn = 64514, vm_index = 0 },
  ]
  tpl = "${path.module}/../../terraform/crusoe/templates"
}

resource "local_file" "swanctl" {
  filename = "${path.module}/out/swanctl.conf"
  content  = templatefile("${local.tpl}/swanctl.conf.tftpl", { tunnels = local.tunnels, crypto = local.crypto })
}

resource "local_file" "bgpd" {
  filename = "${path.module}/out/frr.conf"
  content = templatefile("${local.tpl}/frr-bgpd.conf.tftpl", {
    tunnels         = local.tunnels, local_asn = 65000,
    advertise_cidrs = ["10.100.0.0/16"], customer_cidrs = ["10.200.0.0/16"]
  })
}

resource "local_file" "bgpd_node_snat" {
  filename = "${path.module}/out/frr-node.conf"
  content = templatefile("${local.tpl}/frr-bgpd.conf.tftpl", {
    tunnels         = local.tunnels, local_asn = 65000,
    advertise_cidrs = ["10.100.0.0/16", "169.254.0.0/16"], customer_cidrs = ["10.200.0.0/16"]
  })
}

resource "local_file" "nft" {
  filename = "${path.module}/out/nftables.conf"
  content = templatefile("${local.tpl}/nftables.conf.tftpl", {
    tunnels          = local.tunnels, ssh_allowed_cidrs = ["198.51.100.0/24"], mss_clamp = 1360
    cluster_egress   = { enabled = false, vxlan_id = 100, vxlan_port = 4789, overlay_cidr = "169.254.0.0/16" }
    crusoe_vpc_cidrs = ["10.100.0.0/16"]
  })
}

resource "local_file" "nft_ceg" {
  filename = "${path.module}/out/nftables-ceg.conf"
  content = templatefile("${local.tpl}/nftables.conf.tftpl", {
    tunnels          = local.tunnels, ssh_allowed_cidrs = ["198.51.100.0/24"], mss_clamp = 1360
    cluster_egress   = { enabled = true, vxlan_id = 100, vxlan_port = 4789, overlay_cidr = "169.254.0.0/16" }
    crusoe_vpc_cidrs = ["10.100.0.0/16"]
  })
}

resource "local_file" "secrets" {
  filename = "${path.module}/out/tunnels.secrets.conf"
  content = templatefile("${local.tpl}/swanctl-secrets.conf.tftpl", {
    tunnels = local.tunnels
    psks    = { tunnel-a = "fixture-psk-aaaaaaaa", tunnel-b = "fixture-psk-bbbbbbbb" }
  })
}

resource "local_file" "xfrm" {
  filename = "${path.module}/out/vpn-xfrm-up.sh"
  content = templatefile("${local.tpl}/xfrm-interfaces.sh.tftpl", {
    tunnels = local.tunnels, tunnel_mtu = 1400
  })
}

resource "local_file" "handoff" {
  filename = "${path.module}/out/handoff.txt"
  content = templatefile("${local.tpl}/handoff.txt.tftpl", {
    deployment_name = "fixture"
    cloud           = "gcp"
    vm_public_ips   = ["192.0.2.10"]
    tunnels         = local.tunnels
    local_asn       = 65000
    crusoe_cidrs    = ["10.100.0.0/16"]
  })
}

# Full bootstrap render — mirrors the argument set in terraform/crusoe/main.tf
# so a template syntax error fails here instead of at first live apply.
resource "local_file" "startup" {
  filename = "${path.module}/out/startup-script.sh"
  content = templatefile("${local.tpl}/startup-script.sh.tftpl", {
    swanctl_conf    = local_file.swanctl.content
    swanctl_secrets = local_file.secrets.content
    frr_daemons     = file("${local.tpl}/frr-daemons.tftpl")
    frr_bgpd_conf   = local_file.bgpd.content
    nftables_conf   = local_file.nft.content
    xfrm_script     = local_file.xfrm.content
    cluster_egress  = { enabled = true, snat_mode = "gateway", overlay_transport = "vxlan", vxlan_id = 100, vxlan_port = 4789, overlay_cidr = "169.254.0.0/16" }
    tunnel_ifids    = [for t in local.tunnels : t.xfrm_if_id]
    gw_overlay_ip   = "169.254.0.1"
    overlay_prefix  = "16"
  })
}

# snat_mode=node bootstrap render — exercises the no-SNAT branch.
resource "local_file" "startup_node" {
  filename = "${path.module}/out/startup-script-node.sh"
  content = templatefile("${local.tpl}/startup-script.sh.tftpl", {
    swanctl_conf    = local_file.swanctl.content
    swanctl_secrets = local_file.secrets.content
    frr_daemons     = file("${local.tpl}/frr-daemons.tftpl")
    frr_bgpd_conf   = local_file.bgpd_node_snat.content
    nftables_conf   = local_file.nft.content
    xfrm_script     = local_file.xfrm.content
    cluster_egress  = { enabled = true, snat_mode = "node", overlay_transport = "vxlan", vxlan_id = 100, vxlan_port = 4789, overlay_cidr = "169.254.0.0/16" }
    tunnel_ifids    = [for t in local.tunnels : t.xfrm_if_id]
    gw_overlay_ip   = "169.254.0.1"
    overlay_prefix  = "16"
  })
}

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}
