# Note: this module always creates a new TGW. Attaching to an existing TGW is
# out of scope; simplest-first approach — bring your own TGW by forking if needed.
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = "${var.deployment_name} TGW"
  amazon_side_asn                 = var.aws_asn
  vpn_ecmp_support                = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  tags                            = { Name = var.deployment_name }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "vpc" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  tags               = { Name = "${var.deployment_name}-vpc" }
}

resource "aws_customer_gateway" "crusoe" {
  bgp_asn    = var.crusoe_asn
  ip_address = var.crusoe_public_ip
  type       = "ipsec.1"
  tags       = { Name = "${var.deployment_name}-crusoe" }
}

resource "aws_vpn_connection" "vpn" {
  customer_gateway_id = aws_customer_gateway.crusoe.id
  transit_gateway_id  = aws_ec2_transit_gateway.tgw.id
  type                = "ipsec.1"

  tunnel1_inside_cidr = length(var.bgp_inside_cidrs) > 0 ? var.bgp_inside_cidrs[0] : null
  tunnel2_inside_cidr = length(var.bgp_inside_cidrs) > 1 ? var.bgp_inside_cidrs[1] : null

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256-GCM-16"]
  tunnel2_phase1_encryption_algorithms = ["AES256-GCM-16"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-384"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-384"]
  tunnel1_phase1_dh_group_numbers      = [20]
  tunnel2_phase1_dh_group_numbers      = [20]
  tunnel1_phase2_encryption_algorithms = ["AES256-GCM-16"]
  tunnel2_phase2_encryption_algorithms = ["AES256-GCM-16"]
  tunnel1_phase2_dh_group_numbers      = [20]
  tunnel2_phase2_dh_group_numbers      = [20]

  tags = { Name = var.deployment_name }
}

# Return routes: VPC -> TGW for Crusoe CIDRs. Cloud-side of what GCP's
# Cloud Router does automatically.
resource "aws_route" "to_crusoe" {
  for_each = {
    for pair in setproduct(var.route_table_ids, var.crusoe_cidrs) :
    "${pair[0]}-${replace(pair[1], "/", "-")}" => { rt = pair[0], cidr = pair[1] }
  }
  route_table_id         = each.value.rt
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.vpc]
}
