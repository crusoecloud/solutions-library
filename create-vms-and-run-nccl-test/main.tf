// Crusoe Provider
terraform {
  required_providers {
    crusoe = {
      source  = "registry.terraform.io/crusoecloud/crusoe"
    }
    ansible = {
      version = "~> 1.3.0"
      source  = "ansible/ansible"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

// Generate SSH keypair for inter-node communication
resource "tls_private_key" "cluster_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

// Save the private key locally for reference
resource "local_file" "cluster_private_key" {
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
  ssh_public_key = file("~/.ssh/id_ed25519.pub") # replace with path to your public SSH key if different
}

//vms
resource "crusoe_compute_instance" "node" {
  count    = var.node_count
  name     = "${var.node_name_prefix}-${count.index}"
  type       = var.node_type
  ssh_key  = local.ssh_public_key
  location = var.location
  project_id = var.project_id
  image    = var.image_name
  host_channel_adapters = var.ib_partition_id != null ? [{
    ib_partition_id = var.ib_partition_id
  }]: null
  network_interfaces = [{
    subnet = var.vpc_subnet_id,
    public_ipv4 = {
      type = "static"
    }
  }]
}

resource "local_file" "node_hostfile" {
  count = var.imex_support ? 1 : 0
  content = templatefile("${path.module}/nodes.tpl", {
    ips = crusoe_compute_instance.node[*].network_interfaces[0].private_ipv4.address

  })
  filename = "${path.module}/imex_nodes.txt"
}

resource "local_file" "hosts_hostfile" {
  count = 1
  content = templatefile("${path.module}/hostfile.tpl", {
    ips = crusoe_compute_instance.node[*].network_interfaces[0].private_ipv4.address

  })
  filename = "${path.module}/hostfile"
}

resource "ansible_host" "node_host" {
  for_each = {
    for n in crusoe_compute_instance.node : n.name => n
  }
  name      = each.value.name
  groups    = [
    "nodes",
    replace(split(".", each.value.type)[0], "-", "_"),
  ]
  variables = {
    ansible_host = each.value.network_interfaces[0].public_ipv4.address
    instance_type = each.value.type
    location = each.value.location
    # volumes = jsonencode(var.slurm_shared_volumes)
  }
}

resource "ansible_group" "all" {
  name     = "all"
  variables = {
    use_imex = var.imex_support
    cluster_ssh_private_key = tls_private_key.cluster_ssh.private_key_pem
    cluster_ssh_public_key  = tls_private_key.cluster_ssh.public_key_openssh
  }
}

resource "null_resource" "ansible_playbook" {
  # Always run ansible-playbook.
  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "local-exec" {
    command = "ansible-galaxy install -r ansible/roles/requirements.yml"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -i ansible/inventory/inventory.yml ansible/nodes.yml -f 128"
  }

  depends_on = [
    ansible_host.node_host,
    ansible_group.all
  ]
}

// Copy nccltest.sh to the first compute node and execute it
resource "null_resource" "copy_and_run_nccltest" {
  # Run after ansible playbook completes
  depends_on = [null_resource.ansible_playbook]

  triggers = {
    always_run = "${timestamp()}"
  }
  # Copy the script to the first node
  provisioner "file" {
    source      = "${path.module}/nccltest.sh"
    destination = "/home/ubuntu/nccltest.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = crusoe_compute_instance.node[0].network_interfaces[0].public_ipv4.address
      private_key = file("~/.ssh/id_ed25519")  # Update this path if your SSH key is different
    }
  }

  # Make the script executable and run it
  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ubuntu/nccltest.sh",
      "/home/ubuntu/nccltest.sh > /home/ubuntu/nccltest_output.txt 2>&1"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = crusoe_compute_instance.node[0].network_interfaces[0].public_ipv4.address
      private_key = file("~/.ssh/id_ed25519")  # Update this path if your SSH key is different
    }
  }

  # Retrieve the output file
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@${crusoe_compute_instance.node[0].network_interfaces[0].public_ipv4.address}:/home/ubuntu/nccltest_output.txt ${path.module}/nccltest_output.txt"
  }
}

// Read the output file to display in terraform output
data "local_file" "nccltest_output" {
  filename   = "${path.module}/nccltest_output.txt"
  depends_on = [null_resource.copy_and_run_nccltest]
}

output "nodes_addr" {
  description = "Node addresses"
  value = crusoe_compute_instance.node[*].network_interfaces[0].public_ipv4.address
}

output "nccltest_output" {
  description = "Output from nccltest.sh execution on first node"
  value       = data.local_file.nccltest_output.content
}
