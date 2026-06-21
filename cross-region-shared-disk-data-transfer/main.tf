terraform {
  required_providers {
    crusoe = {
      source = "registry.terraform.io/crusoecloud/crusoe"
    }
    ansible = {
      version = "~> 1.3.0"
      source  = "ansible/ansible"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

locals {
  ssh_public_key = file(var.ssh_public_key_path)

  # VAST NFS defaults — not user-configurable.
  vast_nfs_server_host = "nfs.crusoecloudcompute.com"
  vast_nfs_remoteports = "dns"

  # Flatten source server groups into a map of individual instances keyed by
  # "<instance-class>-<index>" (e.g. "s1a-0", "s1a-1", "c1a-0").
  source_server_instances = merge([
    for group in var.source_server_groups : {
      for i in range(group.vm_count) :
        "${split(".", group.vm_type)[0]}-${i}" => {
          name    = "source-server-${split(".", group.vm_type)[0]}-${i}"
          vm_type = group.vm_type
        }
    }
  ]...)
}

# ============================================================
# SOURCE: nginx file server VMs (in source location)
# ============================================================

resource "crusoe_compute_instance" "source_server" {
  for_each   = local.source_server_instances
  name       = each.value.name
  type       = each.value.vm_type
  location   = var.source_server_location
  project_id = var.source_server_project_id
  image      = "ubuntu24.04:latest"
  ssh_key    = local.ssh_public_key

  network_interfaces = [{
    subnet = var.source_server_vpc_subnet_id
    public_ipv4 = {
      type = "static"
    }
  }]

  disks = [{
    id              = var.source_disk_id
    mode            = "read-write"
    attachment_type = "data"
  }]
}

# ============================================================
# DESTINATION: Kubernetes cluster + nodepools + storage disk
# ============================================================

locals {
  # Total VM count across all nodepool groups (known at plan time).
  total_nodepool_vms = sum([for g in var.nodepool_groups : g.vm_count])

  # Flatten nodepool groups into a keyed map for for_each.
  nodepool_map = {
    for group in var.nodepool_groups :
      split(".", group.vm_type)[0] => group
  }

  # Aggregate instance IDs from all node pools into a flat list.
  all_nodepool_instance_ids = flatten([
    for pool in values(crusoe_kubernetes_node_pool.nodepool) : pool.instance_ids
  ])
}

resource "crusoe_kubernetes_cluster" "destination_cluster" {
  name       = var.cluster_name
  version    = var.cluster_version
  location   = var.destination_location
  subnet_id  = var.cluster_subnet_id
  project_id = var.destination_project_id
  add_ons    = ["crusoe_csi"]
}

resource "crusoe_kubernetes_node_pool" "nodepool" {
  for_each       = local.nodepool_map
  name           = "${each.key}-nodepool"
  cluster_id     = crusoe_kubernetes_cluster.destination_cluster.id
  instance_count = each.value.vm_count
  type           = each.value.vm_type
  subnet_id      = var.cluster_subnet_id
  project_id     = var.destination_project_id
  ssh_key        = local.ssh_public_key
  version        = var.nodepool_version
}

# Look up each nodepool VM by ID to retrieve its public IP.
# count = total_nodepool_vms is known at plan time. instance_ids are
# resolved after the node pools are created in the same apply.
data "crusoe_compute_instance" "nodepool_vms" {
  count      = local.total_nodepool_vms
  id         = local.all_nodepool_instance_ids[count.index]
  project_id = var.destination_project_id
}

# Firewall rules: one /32 rule per (source server, nodepool VM) pair.
# The Crusoe API accepts a single CIDR per rule, so N×M rules are required.
# Node IPs are auto-discovered from the data source — no second terraform apply needed.
resource "crusoe_vpc_firewall_rule" "allow_source_http" {
  for_each = {
    for pair in flatten([
      for server in values(crusoe_compute_instance.source_server) : [
        for i, vm in data.crusoe_compute_instance.nodepool_vms : {
          key     = "${server.name}-node${i}"
          server  = server
          node_ip = vm.network_interfaces[0].public_ipv4.address
        }
      ]
    ]) : pair.key => pair
  }

  action            = "allow"
  destination       = each.value.server.network_interfaces[0].private_ipv4.address
  destination_ports = "8080"
  direction         = "ingress"
  name              = "source-http-${each.key}"
  network           = each.value.server.network_interfaces[0].network
  project_id        = var.source_server_project_id
  protocols         = "tcp"
  source            = "${each.value.node_ip}/32"
  source_ports      = "1-65535"
}

# ============================================================
# ANSIBLE: Inventory (ansible/ansible provider)
# ============================================================

resource "ansible_host" "source_server" {
  for_each = {
    for inst in values(crusoe_compute_instance.source_server) : inst.name => inst
  }
  name   = each.value.name
  groups = ["source_servers"]
  variables = {
    ansible_host                    = each.value.network_interfaces[0].public_ipv4.address
    ansible_user                    = "ubuntu"
    ansible_ssh_private_key_file    = replace(var.ssh_public_key_path, ".pub", "")
    http_user                       = var.http_user
    http_password                   = var.http_password
    serve_addr                      = each.value.network_interfaces[0].private_ipv4.address
    data_path                       = var.source_disk_mount_path
    serve_path                      = var.source_serve_path
    source_disk_id                  = var.source_disk_id
  }
}

resource "ansible_group" "source_servers" {
  name = "source_servers"
  variables = {
    ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    destination_mount_path  = var.destination_disk_mount_path
    vast_nfs_server_host    = local.vast_nfs_server_host
    vast_nfs_remoteports    = local.vast_nfs_remoteports
  }
}

resource "ansible_host" "destination_node" {
  count  = local.total_nodepool_vms
  name   = "destination-node-${count.index}"
  groups = ["destination_nodes"]
  variables = {
    ansible_host                 = data.crusoe_compute_instance.nodepool_vms[count.index].network_interfaces[0].public_ipv4.address
    ansible_user                 = "ubuntu"
    ansible_ssh_private_key_file = replace(var.ssh_public_key_path, ".pub", "")
  }
}

resource "ansible_group" "destination_nodes" {
  name = "destination_nodes"
  variables = {
    ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  }
}

resource "ansible_group" "all" {
  name = "all"
  variables = {
    destination_cluster_id   = crusoe_kubernetes_cluster.destination_cluster.id
    destination_project_id   = var.destination_project_id
    destination_location     = var.destination_location
    grafana_cmk_manifests    = abspath(var.grafana_cmk_manifests_path)
    grafana_monitoring_token = var.grafana_monitoring_token

    # aria2c-download.py configuration
    # 8 pods per VM.
    aria2c_num_pods       = local.total_nodepool_vms * 8
    aria2c_data_mount     = var.destination_disk_mount_path
    aria2c_http_user      = var.http_user
    aria2c_http_password  = var.http_password

    # Destination disk (for PV/PVC provisioning)
    destination_disk_id  = var.destination_disk_id
  }
}

resource "null_resource" "ansible_playbook" {
  # Always run ansible-playbook on every terraform apply.
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = "ansible-galaxy install -r ansible/roles/requirements.yml"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -i ansible/inventory/inventory.yml ansible/playbook.yml -f 16"
  }

  depends_on = [
    ansible_host.source_server,
    ansible_host.destination_node,
    ansible_group.source_servers,
    ansible_group.destination_nodes,
    ansible_group.all,
    crusoe_kubernetes_node_pool.nodepool,
  ]
}
