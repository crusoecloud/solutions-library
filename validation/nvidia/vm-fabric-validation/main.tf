// Crusoe Provider
terraform {
  required_providers {
    crusoe = {
      source  = "registry.terraform.io/crusoecloud/crusoe"
      version = "~> 1.3" # transport_partition_id needs >= 1.3.0
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

// Generate SSH keypair for inter-node communication
resource "tls_private_key" "cluster_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

// Save the private key locally for reference
resource "local_sensitive_file" "cluster_private_key" {
  content         = tls_private_key.cluster_ssh.private_key_pem
  filename        = "${path.module}/cluster_ssh_key"
  file_permission = "0600"
}

// Save the public key locally for reference
resource "local_file" "cluster_public_key" {
  content         = tls_private_key.cluster_ssh.public_key_openssh
  filename        = "${path.module}/cluster_ssh_key.pub"
  file_permission = "0644"
}

// local files
locals {
  ssh_public_key = file(var.ssh_public_key_path)

  # Derived from node_type. Example: "b300-288gb-sxm-ib.8x" -> gpu_gen "b300", gpus 8.
  # NCCL settings and use_imex are derived in ansible/inventory/group_vars/all.yml.
  sku     = split(".", var.node_type)[0]
  gpu_gen = split("-", local.sku)[0]
  gpus    = tonumber(trimsuffix(split(".", var.node_type)[1], "x"))
  # GB200/GB300 (NVL72) need the IMEX node list
  is_nvl = startswith(local.gpu_gen, "gb")
}

//vms
resource "crusoe_compute_instance" "node" {
  count      = var.node_count
  name       = "${var.node_name_prefix}-${count.index}"
  type       = var.node_type
  ssh_key    = local.ssh_public_key
  location   = var.location
  project_id = var.project_id
  image      = var.image_name
  host_channel_adapters = var.transport_partition_id != null && var.transport_partition_id != "" ? [{
    transport_partition_id = var.transport_partition_id
  }] : null
  network_interfaces = [{
    subnet = var.vpc_subnet_id,
    public_ipv4 = {
      type = "static"
    }
  }]

  # A new image_name must not replace running VMs (image forces replacement). New nodes use it;
  # to move an existing node: terraform apply -replace='crusoe_compute_instance.node[N]'
  lifecycle {
    ignore_changes = [image]
  }
}

resource "local_file" "node_hostfile" {
  count = local.is_nvl ? 1 : 0
  content = templatefile("${path.module}/nodes.tpl", {
    ips = crusoe_compute_instance.node[*].network_interfaces[0].private_ipv4.address

  })
  filename = "${path.module}/imex_nodes.txt"
}

resource "local_file" "hosts_hostfile" {
  count = 1
  content = templatefile("${path.module}/hostfile.tpl", {
    ips  = crusoe_compute_instance.node[*].network_interfaces[0].private_ipv4.address
    gpus = local.gpus
  })
  filename = "${path.module}/hostfile"
}

# Static inventory written by Terraform. Replaces the cloud.terraform inventory plugin,
# which breaks on ansible-core >= 2.21 (ansible-collections/cloud.terraform#214).
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tpl", {
    hosts = [for n in crusoe_compute_instance.node : {
      name       = n.name
      ip         = n.network_interfaces[0].public_ipv4.address
      private_ip = n.network_interfaces[0].private_ipv4.address
      type       = n.type
      location   = n.location
    }]
    use_raid0            = var.raid0_enabled
    ssh_private_key_file = pathexpand(var.ssh_private_key_path)
  })
  filename        = "${path.module}/ansible/inventory/hosts.yml"
  file_permission = "0644"
}

resource "null_resource" "ansible_playbook" {
  # Always run ansible-playbook.
  triggers = {
    always_run = "${timestamp()}"
  }

  # Run from the module folder so ansible.cfg applies (inventory path, unparsed_is_failed)
  provisioner "local-exec" {
    command     = "ansible-playbook ansible/nodes.yml -f 128"
    working_dir = path.module
  }

  depends_on = [
    local_file.ansible_inventory,
    local_file.hosts_hostfile,
    local_file.node_hostfile,
    local_sensitive_file.cluster_private_key,
    local_file.cluster_public_key,
  ]
}

output "nodes_addr" {
  description = "Node addresses"
  value       = crusoe_compute_instance.node[*].network_interfaces[0].public_ipv4.address
}
