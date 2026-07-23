locals {
  vm_count = var.ha_mode == "dual" ? 2 : 1

  # tunnels grouped by terminating VM
  tunnels_by_vm = {
    for idx in range(local.vm_count) :
    idx => [for t in var.tunnels : t if t.vm_index == idx]
  }

  ssh_keys_joined = join("\n", var.ssh_public_keys)

  # cloud-keyed crypto defaults; see docs/crypto-profiles.md before production use
  crypto_defaults = {
    gcp = {
      ike_proposals = ["aes256gcm16-prfsha384-ecp384", "aes256-sha384-modp2048"]
      esp_proposals = ["aes256gcm16-ecp384"]
      ike_lifetime  = "8h"
      esp_lifetime  = "1h"
      dpd_delay     = "30s"
      dpd_timeout   = "120s"
      rekey_margin  = "3m"
    }
    aws = {
      ike_proposals = ["aes256gcm16-prfsha384-ecp384", "aes256-sha384-modp2048"]
      esp_proposals = ["aes256gcm16-ecp384"]
      ike_lifetime  = "8h"
      esp_lifetime  = "1h"
      dpd_delay     = "30s"
      dpd_timeout   = "120s"
      rekey_margin  = "3m"
    }
  }
  crypto = var.crypto_profile != null ? var.crypto_profile : local.crypto_defaults[var.cloud]

  # every (a,b) CIDR pair that must not overlap
  overlap_pairs = concat(
    [for pair in setproduct(var.crusoe_vpc_cidrs, var.customer_cidrs) : pair],
    [for pair in setproduct(var.crusoe_vpc_cidrs, [for t in var.tunnels : t.bgp_inside_cidr]) : pair],
    [for pair in setproduct(var.customer_cidrs, [for t in var.tunnels : t.bgp_inside_cidr]) : pair],
  )
}

# CIDR overlap guard: cidrhost-based containment check both directions.
resource "terraform_data" "cidr_overlap_guard" {
  lifecycle {
    precondition {
      condition = alltrue([
        for pair in local.overlap_pairs :
        !(
          can(cidrhost(pair[0], 0)) && can(cidrhost(pair[1], 0)) &&
          (
            cidrhost(pair[0], 0) == cidrhost(cidrsubnet(pair[1], 0, 0), 0) ||
            # a contains b's network addr or b contains a's network addr
            (tonumber(split("/", pair[0])[1]) <= tonumber(split("/", pair[1])[1]) &&
            cidrhost(pair[0], 0) == cidrhost("${split("/", pair[1])[0]}/${split("/", pair[0])[1]}", 0)) ||
            (tonumber(split("/", pair[1])[1]) <= tonumber(split("/", pair[0])[1]) &&
            cidrhost(pair[1], 0) == cidrhost("${split("/", pair[0])[0]}/${split("/", pair[1])[1]}", 0))
          )
        )
      ])
      error_message = "CIDR overlap detected between crusoe_vpc_cidrs, customer_cidrs, and/or bgp_inside_cidrs. See docs/ip-planning.md."
    }
    precondition {
      condition     = alltrue([for t in var.tunnels : t.vm_index < local.vm_count])
      error_message = "tunnels[].vm_index must be < number of VMs (ha_mode=single -> only 0)."
    }
    precondition {
      condition     = alltrue([for i in range(local.vm_count) : length(local.tunnels_by_vm[i]) > 0])
      error_message = "every VM must terminate at least one tunnel; check tunnels[].vm_index assignments."
    }
  }
}

# NOTE: startup_script embeds rendered secrets; see tunnel_psks variable warning.
resource "crusoe_compute_instance" "vpn" {
  count      = local.vm_count
  name       = "${var.deployment_name}-vpn-${count.index}"
  type       = var.instance_type
  location   = var.crusoe_location
  project_id = var.crusoe_project_id
  image      = var.image
  ssh_key    = local.ssh_keys_joined

  network_interfaces = [{
    subnet = var.crusoe_vpc_subnet_id
    public_ipv4 = {
      type = "static"
    }
  }]

  startup_script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
    swanctl_conf    = templatefile("${path.module}/templates/swanctl.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], crypto = local.crypto })
    swanctl_secrets = templatefile("${path.module}/templates/swanctl-secrets.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], psks = { for t in local.tunnels_by_vm[count.index] : t.name => var.tunnel_psks[t.psk_var_name] } })
    frr_daemons     = file("${path.module}/templates/frr-daemons.tftpl")
    frr_bgpd_conf   = templatefile("${path.module}/templates/frr-bgpd.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], local_asn = var.local_asn, crusoe_cidrs = var.crusoe_vpc_cidrs, customer_cidrs = var.customer_cidrs })
    nftables_conf   = templatefile("${path.module}/templates/nftables.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], ssh_allowed_cidrs = var.ssh_allowed_cidrs, mss_clamp = var.mss_clamp })
    xfrm_script     = templatefile("${path.module}/templates/xfrm-interfaces.sh.tftpl", { tunnels = local.tunnels_by_vm[count.index], tunnel_mtu = var.tunnel_mtu })
  })

  lifecycle {
    ignore_changes = [ssh_key]
  }

  depends_on = [terraform_data.cidr_overlap_guard]
}

# Crusoe firewall accepts ONE source CIDR per rule -> product expansion.
locals {
  ike_rules = {
    for pair in setproduct(range(local.vm_count), distinct([for t in var.tunnels : t.peer_public_ip])) :
    "vm${pair[0]}-peer-${replace(pair[1], ".", "-")}" => { vm = pair[0], peer = pair[1] }
    if length([for t in var.tunnels : t if t.vm_index == pair[0] && t.peer_public_ip == pair[1]]) > 0
  }
  ssh_rules = {
    for pair in setproduct(range(local.vm_count), var.ssh_allowed_cidrs) :
    "vm${pair[0]}-ssh-${replace(replace(pair[1], ".", "-"), "/", "-")}" => { vm = pair[0], cidr = pair[1] }
  }
}

resource "crusoe_vpc_firewall_rule" "ike" {
  for_each          = local.ike_rules
  action            = "allow"
  direction         = "ingress"
  protocols         = "udp"
  source            = "${each.value.peer}/32"
  source_ports      = "1-65535"
  destination       = "${crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].private_ipv4.address}/32"
  destination_ports = "500,4500"
  name              = "${var.deployment_name}-ike-${each.key}"
  network           = crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].network
  project_id        = var.crusoe_project_id
}

resource "crusoe_vpc_firewall_rule" "ssh" {
  for_each          = local.ssh_rules
  action            = "allow"
  direction         = "ingress"
  protocols         = "tcp"
  source            = each.value.cidr
  source_ports      = "1-65535"
  destination       = "${crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].private_ipv4.address}/32"
  destination_ports = "22"
  name              = "${var.deployment_name}-ssh-${each.key}"
  network           = crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].network
  project_id        = var.crusoe_project_id
}

# Customer handoff bundle (no secrets)
resource "local_file" "handoff" {
  filename        = "${path.root}/handoff.txt"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/handoff.txt.tftpl", {
    deployment_name = var.deployment_name
    cloud           = var.cloud
    vm_public_ips   = [for vm in crusoe_compute_instance.vpn : vm.network_interfaces[0].public_ipv4.address]
    tunnels         = var.tunnels
    local_asn       = var.local_asn
    crusoe_cidrs    = var.crusoe_vpc_cidrs
  })
}
