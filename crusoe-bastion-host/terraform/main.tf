data "crusoe_vpc_networks" "all" {}

locals {
  bastion_count  = var.ha_enabled ? var.ha_count : 1
  vpc_network    = [for n in data.crusoe_vpc_networks.all.vpc_networks : n if n.name == var.vpc_network][0]
  vpc_network_id = local.vpc_network.id
  vpc_cidr       = local.vpc_network.cidr
}

resource "crusoe_compute_instance" "bastion" {
  count = local.bastion_count

  name     = var.ha_enabled ? "${var.bastion_name}-${count.index + 1}" : var.bastion_name
  type     = var.instance_type
  location = var.location
  image    = "ubuntu22.04:latest"
  ssh_key  = var.ssh_public_key

  startup_script = file("${path.module}/user-data.sh")

  disks = [
    {
      id              = crusoe_storage_disk.bastion_disk[count.index].id
      mode            = "read-write"
      attachment_type = "data"
    }
  ]

  network_interfaces = [
    {
      public_ipv4 = {
        type = "dynamic"
      }
    }
  ]
}

resource "crusoe_storage_disk" "bastion_disk" {
  count = local.bastion_count

  name     = var.ha_enabled ? "${var.bastion_name}-disk-${count.index + 1}" : "${var.bastion_name}-disk"
  location = var.location
  size     = "${var.disk_size_gib}GiB"
  type     = "persistent-ssd"
}


resource "crusoe_vpc_firewall_rule" "bastion_ssh" {
  name              = "${var.bastion_name}-ssh-inbound"
  network           = local.vpc_network_id
  action            = "allow"
  direction         = "ingress"
  protocols         = "tcp"
  source            = join(",", var.allowed_ssh_cidrs)
  source_ports      = "1-65535"
  destination       = local.vpc_cidr
  destination_ports = tostring(var.ssh_port)
}

resource "crusoe_vpc_firewall_rule" "bastion_egress_tcp_udp" {
  name              = "${var.bastion_name}-egress-tcp-udp"
  network           = local.vpc_network_id
  action            = "allow"
  direction         = "egress"
  protocols         = "tcp,udp"
  source            = local.vpc_cidr
  source_ports      = "1-65535"
  destination       = "0.0.0.0/0"
  destination_ports = "1-65535"
}

resource "crusoe_vpc_firewall_rule" "bastion_egress_icmp" {
  name              = "${var.bastion_name}-egress-icmp"
  network           = local.vpc_network_id
  action            = "allow"
  direction         = "egress"
  protocols         = "icmp"
  source            = local.vpc_cidr
  source_ports      = ""
  destination       = "0.0.0.0/0"
  destination_ports = ""
}

resource "random_id" "deployment" {
  byte_length = 4
}
