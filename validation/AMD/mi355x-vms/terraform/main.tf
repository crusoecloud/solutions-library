provider "crusoe" {}

// Dedicated keypair for this validation cluster. Used for operator SSH,
// Ansible, and node-to-node SSH (mpirun).
resource "tls_private_key" "cluster" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "cluster_private_key" {
  content         = tls_private_key.cluster.private_key_openssh
  filename        = "${path.module}/../keys/cluster_ssh_key"
  file_permission = "0600"
}

resource "local_file" "cluster_public_key" {
  content         = tls_private_key.cluster.public_key_openssh
  filename        = "${path.module}/../keys/cluster_ssh_key.pub"
  file_permission = "0644"
}

locals {
  // Only the operator's key is authorized at VM creation. The generated cluster
  // key is distributed by Ansible later for node-to-node (mpirun) SSH.
  ssh_public_key_path = pathexpand(trimspace(var.ssh_public_key_path))
  ssh_key             = trimspace(file(local.ssh_public_key_path))

  // Defaults to the public key path without ".pub" (e.g. ~/.ssh/id_ed25519).
  operator_private_key_path = pathexpand(trimspace(coalesce(var.ssh_private_key_path, trimsuffix(var.ssh_public_key_path, ".pub"))))

  partition_id = var.create_partition ? crusoe_transport_partition.cluster[0].id : var.existing_partition_id

  // Remaining capacity for this instance type on the target transport network.
  roce_capacity = sum(concat([0], flatten([
    for n in data.crusoe_transport_networks.all.transport_networks : [
      for c in n.capacities : c.quantity if c.slice_type == var.node_type
    ] if n.id == var.transport_network_id
  ])))
}

data "crusoe_transport_networks" "all" {
  project_id = var.project_id
}

resource "crusoe_transport_partition" "cluster" {
  count                = var.create_partition ? 1 : 0
  name                 = "${var.name_prefix}-roce"
  transport_network_id = var.transport_network_id
  project_id           = var.project_id
}

// Changing the operator SSH key forces every VM to be recreated.
resource "terraform_data" "ssh_key" {
  input = local.ssh_key
}

resource "crusoe_compute_instance" "node" {
  count      = var.node_count
  name       = format("%s-%02d", var.name_prefix, count.index + 1)
  type       = var.node_type
  image      = var.image
  location   = var.location
  project_id = var.project_id
  ssh_key    = local.ssh_key

  network_interfaces = [{
    subnet = var.vpc_subnet_id
    public_ipv4 = {
      type = var.public_ip_type
    }
  }]

  host_channel_adapters = [{
    transport_partition_id = local.partition_id
  }]

  lifecycle {
    precondition {
      condition     = var.create_partition || var.existing_partition_id != null
      error_message = "Set existing_partition_id when create_partition = false."
    }
    // Don't replace running VMs if the image tag is changed mid-validation.
    // ssh_key is ignored here because key changes are handled by
    // replace_triggered_by (a forced recreate), not an in-place update.
    ignore_changes       = [image, ssh_key]
    replace_triggered_by = [terraform_data.ssh_key]
  }
}

// Inventory artifacts consumed by Ansible and the validation scripts.
resource "local_file" "hostfile" {
  filename = "${path.module}/../inventory/hostfile"
  content = join("", [
    for n in crusoe_compute_instance.node : "${n.network_interfaces[0].private_ipv4.address} slots=8\n"
  ])
}

resource "local_file" "nodes" {
  filename = "${path.module}/../inventory/nodes"
  content = join("", [
    for n in crusoe_compute_instance.node : "${n.network_interfaces[0].private_ipv4.address}\n"
  ])
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../inventory/hosts.ini"
  content = templatefile("${path.module}/templates/hosts.ini.tpl", {
    nodes = [for n in crusoe_compute_instance.node : {
      name       = n.name
      public_ip  = n.network_interfaces[0].public_ipv4.address
      private_ip = n.network_interfaces[0].private_ipv4.address
      vm_id      = n.id
    }]
    key_path = local.operator_private_key_path
  })
}

resource "local_file" "vm_map" {
  filename = "${path.module}/../inventory/vms.tsv"
  content = join("", concat(["name\tvm_id\tpublic_ip\tprivate_ip\n"], [
    for n in crusoe_compute_instance.node :
    "${n.name}\t${n.id}\t${n.network_interfaces[0].public_ipv4.address}\t${n.network_interfaces[0].private_ipv4.address}\n"
  ]))
}
