output "nvlink_domain_id" {
  description = "NVLink domain the GB200 VMs are pinned to."
  value       = var.nvlink_domain_id
}

output "transport_partition_id" {
  value = local.partition_id
}

output "gpu_nodes" {
  description = "name => {vm_id, public_ip, private_ip}"
  value       = { for n in local.inv_gpu : n.name => { vm_id = n.vm_id, public_ip = n.public_ip, private_ip = n.private_ip } }
}

output "cpu_nodes" {
  value = { for n in local.inv_cpu : n.name => { vm_id = n.vm_id, public_ip = n.public_ip, private_ip = n.private_ip } }
}

output "ssh_example" {
  value = "ssh -i ${local.operator_private_key_path} ubuntu@${local.inv_gpu[0].public_ip}"
}
