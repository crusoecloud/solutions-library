output "source_server_public_ips" {
  description = "Public IP addresses of the source nginx server VMs."
  value       = [for s in values(crusoe_compute_instance.source_server) : s.network_interfaces[0].public_ipv4.address]
}

output "source_server_private_ips" {
  description = "Private IP addresses of the source nginx server VMs (used in firewall rules)."
  value       = [for s in values(crusoe_compute_instance.source_server) : s.network_interfaces[0].private_ipv4.address]
}

output "destination_cluster_id" {
  description = "Kubernetes cluster ID for the destination cluster."
  value       = crusoe_kubernetes_cluster.destination_cluster.id
}

output "destination_disk_id" {
  description = "Crusoe disk ID of the destination shared disk."
  value       = var.destination_disk_id
}

output "nodepool_vm_public_ips" {
  description = "Public IP addresses of the aria2c nodepool VMs (used as /32 firewall rule sources)."
  value       = [for vm in data.crusoe_compute_instance.nodepool_vms : vm.network_interfaces[0].public_ipv4.address]
}

output "aria2c_num_pods" {
  description = "Recommended NUM_PODS value for aria2c-download.py (8 pods per nodepool VM)."
  value       = local.total_nodepool_vms * 8
}

output "get_kubeconfig_command" {
  description = "Command to get kubeconfig for the destination cluster."
  value       = "crusoe kubernetes clusters get-credentials --project-id ${var.destination_project_id} ${crusoe_kubernetes_cluster.destination_cluster.id}"
}
