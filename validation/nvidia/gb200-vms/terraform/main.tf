provider "crusoe" {}

// Dedicated keypair for node-to-node SSH (mpirun). Installed on the GB200 VMs by
// ansible/00-prep.yml; not authorized at VM creation.
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

data "crusoe_vpc_subnets" "all" {
  project_id = var.project_id
}

data "crusoe_transport_networks" "all" {
  project_id = var.project_id
}

locals {
  ssh_key                   = trimspace(file(pathexpand(trimspace(var.ssh_public_key_path))))
  operator_private_key_path = pathexpand(trimspace(coalesce(var.ssh_private_key_path, trimsuffix(var.ssh_public_key_path, ".pub"))))

  subnet_id = coalesce(var.vpc_subnet_id, try([
    for s in data.crusoe_vpc_subnets.all.vpc_subnets : s.id if s.location == var.location
  ][0], "NO_SUBNET_IN_LOCATION"))

  use_ib = length(regexall("-ib\\.", var.gpu_node_type)) > 0

  // Transport networks in this location that list capacity for the GB200 type, most capacity first.
  gb200_networks = [
    for n in data.crusoe_transport_networks.all.transport_networks : {
      id  = n.id
      qty = sum(concat([0], [for c in n.capacities : c.quantity if c.slice_type == var.gpu_node_type]))
    }
    if n.location == var.location && anytrue([for c in n.capacities : c.slice_type == var.gpu_node_type])
  ]
  transport_network_id = coalesce(var.transport_network_id, try(
    [for n in local.gb200_networks : n.id if n.qty == max(concat([0], [for m in local.gb200_networks : m.qty])...)][0],
    "NO_GB200_TRANSPORT_NETWORK"
  ))

  create_partition = local.use_ib && var.transport_partition_id == null
  partition_id     = local.use_ib ? coalesce(var.transport_partition_id, try(crusoe_transport_partition.ib[0].id, null)) : null
  hca              = local.use_ib ? [{ transport_partition_id = local.partition_id }] : null

  gpu_nodes = crusoe_compute_instance.gpu
}

resource "crusoe_transport_partition" "ib" {
  count                = local.create_partition ? 1 : 0
  name                 = "${var.name_prefix}-ib"
  transport_network_id = local.transport_network_id
  project_id           = var.project_id

  lifecycle {
    precondition {
      condition     = local.transport_network_id != "NO_GB200_TRANSPORT_NETWORK"
      error_message = "No transport network in ${var.location} lists ${var.gpu_node_type}. Set transport_network_id or transport_partition_id."
    }
  }
}

// Changing the operator SSH key forces the VMs to be recreated.
resource "terraform_data" "ssh_key" {
  input = local.ssh_key
}

// GB200 VMs, all pinned to one NVLink domain (rack). The provider only reports a VM's domain
// when it was set at creation, so the domain must be given explicitly for more than one VM:
//   crusoe networking nvl-domains list --project-id <project-id>
resource "crusoe_compute_instance" "gpu" {
  count            = var.gpu_node_count
  name             = format("%s-%02d", var.name_prefix, count.index + 1)
  type             = var.gpu_node_type
  image            = var.gpu_image
  location         = var.location
  project_id       = var.project_id
  ssh_key          = local.ssh_key
  nvlink_domain_id = var.nvlink_domain_id

  network_interfaces = [{
    subnet = local.subnet_id
    public_ipv4 = {
      type = contains(var.static_public_ip_nodes, format("%s-%02d", var.name_prefix, count.index + 1)) ? "static" : var.public_ip_type
    }
  }]
  host_channel_adapters = local.hca

  lifecycle {
    precondition {
      condition     = local.subnet_id != "NO_SUBNET_IN_LOCATION"
      error_message = "No VPC subnet found in ${var.location}; set vpc_subnet_id."
    }
    precondition {
      condition     = var.gpu_node_count == 1 || var.nvlink_domain_id != null
      error_message = "Set nvlink_domain_id when gpu_node_count > 1 so every GB200 VM lands in the same NVLink domain. List domains (and available_nodes) with: crusoe networking nvl-domains list --project-id ${var.project_id}"
    }
    // nvlink_domain_id is ignored after creation so a canary created without it is not
    // replaced when the domain is set later (the smoke test verifies all VMs share a clique).
    ignore_changes       = [image, ssh_key, nvlink_domain_id]
    replace_triggered_by = [terraform_data.ssh_key]
  }
}

// Earlier versions created VM 1 as a separate resource.
moved {
  from = crusoe_compute_instance.gpu_first
  to   = crusoe_compute_instance.gpu[0]
}

resource "crusoe_compute_instance" "cpu" {
  count      = var.cpu_node_count
  name       = format("%s-cpu-%02d", var.name_prefix, count.index + 1)
  type       = var.cpu_node_type
  image      = var.cpu_image
  location   = var.location
  project_id = var.project_id
  ssh_key    = local.ssh_key

  network_interfaces = [{
    subnet      = local.subnet_id
    public_ipv4 = { type = var.public_ip_type }
  }]

  lifecycle {
    ignore_changes       = [image, ssh_key]
    replace_triggered_by = [terraform_data.ssh_key]
  }
}

check "single_nvlink_domain" {
  assert {
    condition     = length(distinct(compact([for n in local.gpu_nodes : n.nvlink_domain_id]))) <= 1
    error_message = "GB200 VMs report more than one nvlink_domain_id: ${join(", ", distinct(compact([for n in local.gpu_nodes : n.nvlink_domain_id])))}"
  }
}

// ---------------------------------------------------------------- inventory for Ansible
locals {
  inv_gpu = [for n in local.gpu_nodes : {
    name       = n.name
    vm_id      = n.id
    public_ip  = n.network_interfaces[0].public_ipv4.address
    private_ip = n.network_interfaces[0].private_ipv4.address
    nvl_domain = coalesce(n.nvlink_domain_id, "-")
  }]
  inv_cpu = [for n in crusoe_compute_instance.cpu : {
    name       = n.name
    vm_id      = n.id
    public_ip  = n.network_interfaces[0].public_ipv4.address
    private_ip = n.network_interfaces[0].private_ipv4.address
    nvl_domain = "-"
  }]
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../inventory/hosts.ini"
  content = templatefile("${path.module}/templates/hosts.ini.tpl", {
    gpu      = local.inv_gpu
    cpu      = local.inv_cpu
    key_path = local.operator_private_key_path
  })
}

resource "local_file" "hostfile" {
  filename = "${path.module}/../inventory/hostfile"
  content  = join("", [for n in local.inv_gpu : "${n.private_ip} slots=4\n"])
}

resource "local_file" "imex_nodes" {
  filename = "${path.module}/../inventory/imex_nodes"
  content  = join("", [for n in local.inv_gpu : "${n.private_ip}\n"])
}

resource "local_file" "vm_map" {
  filename = "${path.module}/../inventory/vms.tsv"
  content = join("", concat(["role\tname\tvm_id\tpublic_ip\tprivate_ip\tnvlink_domain_id\n"],
    [for n in local.inv_gpu : "gb200\t${n.name}\t${n.vm_id}\t${n.public_ip}\t${n.private_ip}\t${n.nvl_domain}\n"],
    [for n in local.inv_cpu : "cpu\t${n.name}\t${n.vm_id}\t${n.public_ip}\t${n.private_ip}\t-\n"]
  ))
}
