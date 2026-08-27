output "aws_tunnel_public_ips" {
  description = "Feed into params.tfvars as tunnels[*].peer_public_ip."
  value       = [aws_vpn_connection.vpn.tunnel1_address, aws_vpn_connection.vpn.tunnel2_address]
}
output "aws_tunnel_inside_cidrs" {
  value = [aws_vpn_connection.vpn.tunnel1_inside_cidr, aws_vpn_connection.vpn.tunnel2_inside_cidr]
}
output "aws_asn" { value = var.aws_asn }
output "aws_tunnel_psks" {
  description = "AWS-generated PSKs. Export into TF_VAR_tunnel_psks for the Crusoe apply. Sensitive."
  value       = [aws_vpn_connection.vpn.tunnel1_preshared_key, aws_vpn_connection.vpn.tunnel2_preshared_key]
  sensitive   = true
}
