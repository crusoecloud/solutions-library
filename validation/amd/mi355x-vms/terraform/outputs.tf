output "roce_capacity_available" {
  description = "Free slices of var.node_type on the transport network (as reported at plan/apply time)."
  value       = local.roce_capacity
}

output "transport_partition_id" {
  value = local.partition_id
}

output "nodes" {
  description = "name => {vm_id, public_ip, private_ip}"
  value = {
    for n in crusoe_compute_instance.node : n.name => {
      vm_id      = n.id
      public_ip  = n.network_interfaces[0].public_ipv4.address
      private_ip = n.network_interfaces[0].private_ipv4.address
    }
  }
}

output "ssh_example" {
  value = length(crusoe_compute_instance.node) > 0 ? "ssh -i ${local.operator_private_key_path} ubuntu@${crusoe_compute_instance.node[0].network_interfaces[0].public_ipv4.address}" : null
}
