# Customer side: AWS Site-to-Site VPN

How a customer builds the AWS side against a Crusoe endpoint.

**Pick your path:**

- **[Path A](#path-a--existing-aws-site-to-site-vpn-managed-deployment)** — you already run AWS Site-to-Site VPN (TGW or VGW). Add or re-point a VPN connection to Crusoe using the AWS CLI or console; no Terraform required.
- **[Path B](#path-b--greenfield-optional-terraform-module)** — you are standing up new infrastructure. Use the optional `terraform/aws/` module for a complete greenfield deployment.

Both paths produce the same output: two tunnels with matching crypto, PSKs
handed to the Crusoe operator, and BGP sessions exchanging routes.

---

## The AWS model (differs from GCP)

One AWS Site-to-Site VPN **connection** = **2 tunnels, 2 AWS outside IPs, 2
AWS-generated PSKs**. Key inversions versus GCP:

- **AWS generates the PSKs**, not the Crusoe operator. They must flow from
  you to the Crusoe operator, securely (see [PSK handoff](#6-psk-handoff)).
- The Crusoe apply therefore happens **after** the AWS VPN connection exists
  (it needs the two outside IPs and the PSKs), whereas on GCP the PSKs flow
  the other way.
- One **Customer Gateway (CGW) per Crusoe public IP**: one CGW for
  `ha_mode=single`; two CGWs and two VPN connections (4 tunnels total) for
  `ha_mode=dual` behind a Transit Gateway with ECMP.

---

## Path A — existing AWS Site-to-Site VPN managed deployment

Use this path when you already have a Transit Gateway (TGW) or Virtual Private
Gateway (VGW) and simply want to add Crusoe as a new VPN peer, or re-point an
existing VPN connection to Crusoe.

### 1. Create a Customer Gateway for each Crusoe public IP

The Crusoe operator provides a `handoff.txt` after their side is provisioned.
It lists one public IP per VPN VM (one for `ha_mode=single`, two for
`ha_mode=dual`) and the Crusoe BGP ASN (`local_asn`).

**AWS CLI:**

```bash
aws ec2 create-customer-gateway \
  --type ipsec.1 \
  --bgp-asn <crusoe_local_asn> \
  --public-ip <crusoe_vm_public_ip> \
  --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=crusoe-vpn-cgw}]' \
  --region <region>
```

Save the returned `CustomerGatewayId` (e.g. `cgw-0abc123...`).

**Console:** *VPC → Customer gateways → Create customer gateway.* Set:
- IP address: Crusoe endpoint public IP (from `handoff.txt`).
- BGP ASN: the Crusoe `local_asn` (e.g. `65000`).
- Type: `ipsec.1`.

For `ha_mode=dual`, repeat once per Crusoe VM public IP — you will have two
CGWs and two VPN connections (four tunnels total), both attached to the same
TGW with ECMP enabled.

### 2a. Add a new VPN connection to your existing TGW (recommended)

Create a new Site-to-Site VPN connection targeting your existing TGW and the
CGW from step 1. The `--options` blob below pins IKEv2 and the crypto profile
from [docs/crypto-profiles.md](crypto-profiles.md).

```bash
aws ec2 create-vpn-connection \
  --type ipsec.1 \
  --customer-gateway-id <cgw-id> \
  --transit-gateway-id <tgw-id> \
  --options '{
    "TunnelOptions": [
      {
        "TunnelInsideCidr": "169.254.21.0/30",
        "IKEVersions": [{"Value": "ikev2"}],
        "Phase1EncryptionAlgorithms": [{"Value": "AES256-GCM-16"}],
        "Phase1IntegrityAlgorithms":  [{"Value": "SHA2-384"}],
        "Phase1DHGroupNumbers":       [{"Value": 20}],
        "Phase2EncryptionAlgorithms": [{"Value": "AES256-GCM-16"}],
        "Phase2DHGroupNumbers":       [{"Value": 20}]
      },
      {
        "TunnelInsideCidr": "169.254.22.0/30",
        "IKEVersions": [{"Value": "ikev2"}],
        "Phase1EncryptionAlgorithms": [{"Value": "AES256-GCM-16"}],
        "Phase1IntegrityAlgorithms":  [{"Value": "SHA2-384"}],
        "Phase1DHGroupNumbers":       [{"Value": 20}],
        "Phase2EncryptionAlgorithms": [{"Value": "AES256-GCM-16"}],
        "Phase2DHGroupNumbers":       [{"Value": 20}]
      }
    ]
  }' \
  --tag-specifications 'ResourceType=vpn-connection,Tags=[{Key=Name,Value=crusoe-vpn}]' \
  --region <region>
```

Notes on the inside CIDRs:
- Both must be `/30` within `169.254.0.0/16`. See [Inside CIDR constraints](#inside-cidr-constraints) below.
- If you omit `TunnelInsideCidr` entirely, AWS auto-assigns — that is fine; read the assigned values back in step 5 before filling `params.tfvars`.
- You can also omit `Phase1IntegrityAlgorithms` for AEAD-mode connections; AWS accepts `AES256-GCM-16` without a separate integrity algorithm. Keeping it explicit here avoids ambiguity.

**VGW alternative:** replace `--transit-gateway-id` with `--vpn-gateway-id <vgw-id>`. All tunnel options are identical.

### 2b. Re-use an existing VPN connection (alternative — maintenance window required)

If you want to re-point an existing VPN connection rather than add a new one,
change its Customer Gateway. **Both tunnels drop and renegotiate** — plan a
maintenance window.

```bash
# Step 1: swap the Customer Gateway on the connection
aws ec2 modify-vpn-connection \
  --vpn-connection-id <vpn-id> \
  --customer-gateway-id <crusoe-cgw-id> \
  --region <region>

# Step 2: harden tunnel options if the existing connection allowed IKEv1
# or weak proposals. Run once per tunnel (tunnel index 1 and 2).
aws ec2 modify-vpn-tunnel-options \
  --vpn-connection-id <vpn-id> \
  --vpn-tunnel-outside-ip-address <tunnel1-outside-ip> \
  --tunnel-options '{
    "IKEVersions": [{"Value": "ikev2"}],
    "Phase1EncryptionAlgorithms": [{"Value": "AES256-GCM-16"}],
    "Phase1IntegrityAlgorithms":  [{"Value": "SHA2-384"}],
    "Phase1DHGroupNumbers":       [{"Value": 20}],
    "Phase2EncryptionAlgorithms": [{"Value": "AES256-GCM-16"}],
    "Phase2DHGroupNumbers":       [{"Value": 20}]
  }' \
  --region <region>
```

Repeat `modify-vpn-tunnel-options` for the second tunnel (using its outside IP).

`modify-vpn-tunnel-options` causes a **brief tunnel interruption** per tunnel
— stagger the two calls or accept both tunnels down simultaneously.

### 3. Inside CIDR constraints

AWS requires each tunnel inside CIDR to be a **/30 within 169.254.0.0/16**,
and reserves several blocks that you must not use, including:

`169.254.0.0/30`, `169.254.1.0/30`, `169.254.2.0/30`, `169.254.3.0/30`,
`169.254.4.0/30`, `169.254.5.0/30`, and `169.254.169.252/30` (adjacent to the
instance metadata service range).

This repo's convention (`169.254.21.0/30` and `169.254.22.0/30`, see
[docs/ip-planning.md](ip-planning.md)) avoids all reserved blocks. **AWS takes
the first usable address of each /30 (`.1`); Crusoe takes the second (`.2`)**
— this matches `bgp_remote_ip` (`.1`) / `bgp_local_ip` (`.2`) in
`params.tfvars`.

### 4. Route propagation — check or enable

**TGW:** with default route table association/propagation enabled, the VPN
attachment propagates BGP-learned Crusoe CIDRs into the TGW route table
automatically.

Check whether propagation is already on for your TGW route table:

```bash
aws ec2 get-transit-gateway-route-table-propagations \
  --transit-gateway-route-table-id <tgw-rtb-id> \
  --region <region> \
  --query 'TransitGatewayRouteTablePropagations[?ResourceType==`vpn`].{id:ResourceId,state:State}'
```

If your new VPN attachment is not listed or shows `disabled`, enable it:

```bash
aws ec2 enable-transit-gateway-route-table-propagation \
  --transit-gateway-route-table-id <tgw-rtb-id> \
  --transit-gateway-attachment-id <vpn-attachment-id> \
  --region <region>
```

Find the VPN attachment ID:

```bash
aws ec2 describe-transit-gateway-attachments \
  --filters Name=resource-id,Values=<vpn-connection-id> \
  --query 'TransitGatewayAttachments[0].TransitGatewayAttachmentId' \
  --region <region>
```

You still must add **return routes in each VPC route table**: Crusoe CIDRs →
the TGW. The `terraform/aws/` module handles this when `route_table_ids` +
`crusoe_cidrs` are set; doing it manually:

```bash
aws ec2 create-route \
  --route-table-id <rtb-id> \
  --destination-cidr-block <crusoe_vpc_cidr> \
  --transit-gateway-id <tgw-id> \
  --region <region>
```

**VGW:** enable *route propagation* on each VPC route table instead:

```bash
aws ec2 enable-vgw-route-propagation \
  --route-table-id <rtb-id> \
  --gateway-id <vgw-id> \
  --region <region>
```

Ensure security groups and NACLs permit the Crusoe CIDRs to reach your
workloads.

### 5. Extract values for `params/params.tfvars`

After the connection is created, pull all values needed to fill `params.tfvars`
in one call:

```bash
aws ec2 describe-vpn-connections \
  --vpn-connection-ids <vpn-id> \
  --region <region> \
  --query 'VpnConnections[0].{
    Tunnel1OutsideIP:   Options.TunnelOptions[0].OutsideIpAddress,
    Tunnel2OutsideIP:   Options.TunnelOptions[1].OutsideIpAddress,
    Tunnel1InsideCIDR:  Options.TunnelOptions[0].TunnelInsideCidr,
    Tunnel2InsideCIDR:  Options.TunnelOptions[1].TunnelInsideCidr,
    AWSASN:             Options.TunnelOptions[0].TunnelOptions,
    VgwTelemetry:       VgwTelemetry
  }'
```

For the TGW ASN (your `remote_asn`):

```bash
aws ec2 describe-transit-gateways \
  --transit-gateway-ids <tgw-id> \
  --query 'TransitGateways[0].Options.AmazonSideAsn' \
  --region <region>
```

Map to `params.tfvars` fields:

| `describe-vpn-connections` field | `params.tfvars` field |
|---|---|
| `Options.TunnelOptions[0].OutsideIpAddress` | `tunnels[0].peer_public_ip` |
| `Options.TunnelOptions[1].OutsideIpAddress` | `tunnels[1].peer_public_ip` |
| `Options.TunnelOptions[0].TunnelInsideCidr` | `tunnels[0].bgp_inside_cidr` (AWS takes `.1`, Crusoe takes `.2`) |
| `Options.TunnelOptions[1].TunnelInsideCidr` | `tunnels[1].bgp_inside_cidr` |
| TGW `AmazonSideAsn` | `tunnels[*].remote_asn` (same value for both tunnels on one connection) |
| PSKs — see below | `TF_VAR_tunnel_psks` |

**Retrieve PSKs** (these are secrets — avoid logging; consider piping directly
to an env var rather than printing to the terminal):

```bash
# Retrieve PSKs — avoid leaving these in shell history
aws ec2 describe-vpn-connections \
  --vpn-connection-ids <vpn-id> \
  --region <region> \
  --query 'VpnConnections[0].Options.TunnelOptions[*].PreSharedKey' \
  --output json
```

Alternatively, use *Download Configuration* in the console (choose *Generic*
vendor) — the downloaded file contains both PSKs and all tunnel parameters.

> **Terminal history caution:** the PSK query above prints secrets to stdout.
> Pipe directly into an env var or immediately clear history
> (`history -d $(history 1)`). Never screenshot or copy into a ticket.

> **PSK length — the Crusoe module requires ≥ 16 characters.** AWS
> auto-generated PSKs are 32+ chars of `[A-Za-z0-9._]`, which pass the Crusoe
> module's validation (`^[A-Za-z0-9+/=_.-]+$`, min 16) unchanged. But if you set
> a **custom** tunnel PSK on the AWS side shorter than 16 chars (AWS allows down
> to 8), the Crusoe `terraform apply` will reject it with
> *"PSKs must be >=16 chars…"*. Fix: use a ≥16-char PSK on both sides — set it
> explicitly with `aws ec2 modify-vpn-tunnel-options --tunnel-options
> PreSharedKey=<≥16 chars>` per tunnel, or let AWS generate it. AWS also forbids
> a leading `0` and the char set is a subset of the module's, so the only
> practical mismatch is length.

### 6. PSK handoff

**Never send PSKs by email, chat, or ticket.** Options:

- A shared secret manager both parties can reach (AWS Secrets Manager with a
  cross-account resource policy, Vault, etc.) — hand over the ARN/path only.
- A one-time-view link (burn-after-reading secret sharing service run by one
  of the parties).
- If you are co-located with the Crusoe operator (same terminal session or
  shared secret manager), pipe directly:

```bash
PSK_A=$(aws ec2 describe-vpn-connections --vpn-connection-ids <vpn-id> \
  --query 'VpnConnections[0].Options.TunnelOptions[0].PreSharedKey' \
  --output text --region <region>)
PSK_B=$(aws ec2 describe-vpn-connections --vpn-connection-ids <vpn-id> \
  --query 'VpnConnections[0].Options.TunnelOptions[1].PreSharedKey' \
  --output text --region <region>)
export TF_VAR_tunnel_psks="{\"PSK_TUNNEL_A\":\"$PSK_A\",\"PSK_TUNNEL_B\":\"$PSK_B\"}"
```

Rotate immediately if a PSK ever transits an insecure channel: AWS side via
*Modify VPN tunnel options* (or `modify-vpn-tunnel-options --pre-shared-key`);
Crusoe side via the in-place rotation in
[docs/runbook.md §7](runbook.md#7-rotate--rekey).

### 7. Verify

```bash
# Check both tunnel telemetry from the AWS side
aws ec2 describe-vpn-connections \
  --vpn-connection-ids <vpn-id> \
  --region <region> \
  --query 'VpnConnections[0].VgwTelemetry[].{ip:OutsideIpAddress,status:Status,bgp:AcceptedRouteCount}'
```

Both tunnels should show `Status: UP`. AWS also shows BGP status per tunnel in
the console (*Tunnel details*). Then run the end-to-end check from the Crusoe
side:

```bash
VPN_HOST=<crusoe_public_ip> REMOTE_TEST_IP=<customer_test_ip> bash scripts/verify.sh
```

If a tunnel is `DOWN`, work the decision tree in
[docs/runbook.md](runbook.md#6-troubleshoot-decision-tree) — with AWS the
usual suspects are cipher/tunnel-option mismatches and PSK copy errors.

Note: AWS DPDs idle tunnels; the Crusoe side uses `start_action = trap` +
`dpd_action = restart`, so tunnels re-establish on traffic or DPD failure
without intervention.

---

## Path B — greenfield (optional Terraform module)

Use this path when you are starting from scratch and want the whole AWS side
(TGW, CGW, VPN connection, return routes) provisioned by Terraform.

The optional `terraform/aws/` module automates the steps above for testing or
new deployments. The greenfield workflow:

1. Fill `terraform/aws/` variables (see `params/schema.md` → AWS mapping section).
2. Run `terraform apply` in `terraform/aws/` first → it creates a new TGW, one
   CGW, and the VPN connection with crypto pinned to the default profile.
3. Capture outputs → fill `params.tfvars`:

```bash
terraform -chdir=terraform/aws output -json aws_tunnel_public_ips
terraform -chdir=terraform/aws output -json aws_tunnel_inside_cidrs
terraform -chdir=terraform/aws output aws_asn
```

4. Retrieve AWS-generated PSKs and export for the Crusoe apply:

```bash
PSK_A=$(terraform -chdir=terraform/aws output -json aws_tunnel_psks \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
PSK_B=$(terraform -chdir=terraform/aws output -json aws_tunnel_psks \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[1])")
export TF_VAR_tunnel_psks="{\"PSK_TUNNEL_A\":\"$PSK_A\",\"PSK_TUNNEL_B\":\"$PSK_B\"}"
terraform apply -chdir=terraform/crusoe -var-file=../../params/params.tfvars
```

   If the operator runs the `terraform/aws/` module themselves, the PSKs never
   leave their machine — `terraform output -json aws_tunnel_psks` feeds
   `TF_VAR_tunnel_psks` directly.

5. Follow steps 4–7 from Path A for routing, PSK handoff, and verification.

### Inside CIDR constraints

Same rules as Path A — see [Inside CIDR constraints](#inside-cidr-constraints).

### Tunnel options

The `terraform/aws/` module pins: IKEv2 only; phase 1 `AES256-GCM-16` /
`SHA2-384` / DH group 20; phase 2 `AES256-GCM-16` / DH group 20. These match
the Crusoe-side crypto defaults — see [docs/crypto-profiles.md](crypto-profiles.md).

### Routing

Pass `route_table_ids` + `crusoe_cidrs` to the module to have it wire VPC
return routes toward the TGW automatically. If you leave `route_table_ids = []`,
adding those routes is on you (see step 4 of Path A).

### Module variables

See `params/schema.md` → `terraform/aws/ variables` for the full variable
reference including `route_table_ids` and `crusoe_cidrs`.
