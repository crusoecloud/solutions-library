output "crusoe_public_ips" {
  description = "Public IPs of the Crusoe VPN VM(s); customer points tunnels here."
  value       = [for vm in crusoe_compute_instance.vpn : vm.network_interfaces[0].public_ipv4.address]
}

output "crusoe_private_ips" {
  value = [for vm in crusoe_compute_instance.vpn : vm.network_interfaces[0].private_ipv4.address]
}

output "crusoe_vpc_cidrs" {
  value = var.crusoe_vpc_cidrs
}

output "local_asn" {
  value = var.local_asn
}

output "handoff_file" {
  value = local_file.handoff.filename
}
