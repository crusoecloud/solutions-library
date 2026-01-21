output "bastion_public_ips" {
  description = "Public IP addresses of bastion host(s)"
  value       = [for instance in crusoe_compute_instance.bastion : instance.network_interfaces[0].public_ipv4.address]
}

output "bastion_private_ips" {
  description = "Private IP addresses of bastion host(s)"
  value       = [for instance in crusoe_compute_instance.bastion : instance.network_interfaces[0].private_ipv4.address]
}

output "bastion_names" {
  description = "Names of bastion host(s)"
  value       = [for instance in crusoe_compute_instance.bastion : instance.name]
}

output "ssh_commands" {
  description = "SSH commands to connect to bastion host(s)"
  value = [
    for idx, instance in crusoe_compute_instance.bastion :
    "ssh -i ~/.ssh/your-private-key ${var.admin_username}@${instance.network_interfaces[0].public_ipv4.address}"
  ]
}

output "connection_instructions" {
  description = "Instructions for connecting through the bastion"
  value = <<-EOT
    
    ╔════════════════════════════════════════════════════════════════════════════╗
    ║                    BASTION HOST DEPLOYMENT COMPLETE                        ║
    ╚════════════════════════════════════════════════════════════════════════════╝
    
    Bastion Host(s) Deployed: ${local.bastion_count}
    
    ${join("\n    ", [for idx, instance in crusoe_compute_instance.bastion :
      "Bastion ${idx + 1}:\n      Name: ${instance.name}\n      Public IP: ${instance.network_interfaces[0].public_ipv4.address}\n      Private IP: ${instance.network_interfaces[0].private_ipv4.address}"
    ])}
    
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ CONNECT TO BASTION                                                      │
    └─────────────────────────────────────────────────────────────────────────┘
    
    ssh -i ~/.ssh/your-private-key ${var.admin_username}@${crusoe_compute_instance.bastion[0].network_interfaces[0].public_ipv4.address}
    
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ CONNECT TO PRIVATE INSTANCE VIA BASTION                                │
    └─────────────────────────────────────────────────────────────────────────┘
    
    # Method 1: SSH Jump Host
    ssh -i ~/.ssh/your-private-key -J ${var.admin_username}@${crusoe_compute_instance.bastion[0].network_interfaces[0].public_ipv4.address} user@<private-instance-ip>
    
    # Method 2: SSH ProxyJump (add to ~/.ssh/config)
    Host bastion
        HostName ${crusoe_compute_instance.bastion[0].network_interfaces[0].public_ipv4.address}
        User ${var.admin_username}
        IdentityFile ~/.ssh/your-private-key
    
    Host private-instance
        HostName <private-instance-ip>
        User ubuntu
        ProxyJump bastion
        IdentityFile ~/.ssh/your-private-key
    
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ MANAGE USERS                                                            │
    └─────────────────────────────────────────────────────────────────────────┘
    
    # Add a new user
    cd ../scripts
    ./add-user.sh <username> <ssh-public-key-file>
    
    # Remove a user
    ./remove-user.sh <username>
    
    # View audit logs
    ./audit-logs.sh
    
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ SECURITY NOTES                                                          │
    └─────────────────────────────────────────────────────────────────────────┘
    
    ✓ SSH key-based authentication enabled
    ✓ Root login disabled
    ✓ Automatic security updates: ${var.auto_update_enabled ? "ENABLED" : "DISABLED"}
    ✓ Fail2ban intrusion prevention: ${var.fail2ban_enabled ? "ENABLED" : "DISABLED"}
    ✓ Session logging: ${var.enable_session_logging ? "ENABLED" : "DISABLED"}
    ✓ Session timeout: ${var.session_timeout_seconds} seconds
    
    For more information, see the README.md and SECURITY.md files.
    
  EOT
}

output "bastion_instance_ids" {
  description = "Instance IDs of bastion host(s)"
  value       = [for instance in crusoe_compute_instance.bastion : instance.id]
}

output "deployment_id" {
  description = "Unique deployment identifier"
  value       = random_id.deployment.hex
}

output "ssh_config_snippet" {
  description = "SSH config snippet for ~/.ssh/config"
  value = <<-EOT
    # Crusoe Bastion Host Configuration
    # Add this to your ~/.ssh/config file
    
    Host crusoe-bastion
        HostName ${crusoe_compute_instance.bastion[0].network_interfaces[0].public_ipv4.address}
        User ${var.admin_username}
        IdentityFile ~/.ssh/your-private-key
        ServerAliveInterval 60
        ServerAliveCountMax 3
    
    # Example private instance configuration
    # Host my-private-instance
    #     HostName <private-instance-ip>
    #     User ubuntu
    #     ProxyJump crusoe-bastion
    #     IdentityFile ~/.ssh/your-private-key
  EOT
}
