locals {
  bastion_count = var.ha_enabled ? var.ha_count : 1
  
  user_data = templatefile("${path.module}/user-data.sh", {
    admin_username           = var.admin_username
    ssh_public_key          = var.ssh_public_key
    enable_session_logging  = var.enable_session_logging
    auto_update_enabled     = var.auto_update_enabled
    fail2ban_enabled        = var.fail2ban_enabled
    ssh_port                = var.ssh_port
    session_timeout_seconds = var.session_timeout_seconds
  })
}

resource "crusoe_compute_instance" "bastion" {
  count = local.bastion_count

  name     = var.ha_enabled ? "${var.bastion_name}-${count.index + 1}" : var.bastion_name
  type     = var.instance_type
  location = var.location

  image = "ubuntu22.04:latest"

  disks = [
    {
      id              = crusoe_storage_disk.bastion_disk[count.index].id
      mode            = "read-write"
      attachment_type = "data"
    }
  ]

  ssh_key = crusoe_ssh_key.bastion_key.id

  startup_script = local.user_data

  network_interfaces = [
    {
      network = "default"
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

resource "crusoe_ssh_key" "bastion_key" {
  name       = "${var.bastion_name}-key"
  public_key = var.ssh_public_key
}

resource "crusoe_firewall_rule" "bastion_ssh" {
  name     = "${var.bastion_name}-ssh-inbound"
  action   = "allow"
  direction = "ingress"
  protocols = "tcp"
  
  source {
    ips = var.allowed_ssh_cidrs
  }

  destination {
    instances = [for instance in crusoe_compute_instance.bastion : instance.id]
    ports     = [var.ssh_port]
  }
}

resource "crusoe_firewall_rule" "bastion_egress" {
  name      = "${var.bastion_name}-egress"
  action    = "allow"
  direction = "egress"
  protocols = "all"
  
  source {
    instances = [for instance in crusoe_compute_instance.bastion : instance.id]
  }

  destination {
    ips = ["0.0.0.0/0"]
  }
}

resource "random_id" "deployment" {
  byte_length = 4
}
