# Customer side: AWS Site-to-Site VPN

How a customer builds the AWS side against a Crusoe endpoint. The optional
`terraform/aws/` module automates these steps for testing; this page is the
reference for doing it properly in a real account.

## The AWS model (differs from GCP)

One AWS Site-to-Site VPN **connection** = **2 tunnels, 2 AWS outside IPs, 2
AWS-generated PSKs**. Key inversions versus GCP:

- **AWS generates the PSKs**, not the Crusoe operator. They must flow from
  you to the Crusoe operator, securely (below).
- The Crusoe apply therefore happens **after** the AWS VPN connection exists
  (it needs the two outside IPs and the PSKs), whereas on GCP the PSKs flow
  the other way.
- One **Customer Gateway (CGW) per Crusoe public IP**: one CGW for
  `ha_mode=single`; two CGWs and two VPN connections (4 tunnels total) for
  `ha_mode=dual` behind a Transit Gateway with ECMP.

## Steps

### 1. Customer Gateway — one per Crusoe VM public IP

Console: *VPC → Customer gateways → Create*. Set:

- IP address: the Crusoe endpoint public IP (from `handoff.txt` or the
  operator, since the Crusoe VM may already exist; if not, the operator can
  pre-allocate/communicate the IP).
- BGP ASN: the **Crusoe ASN** (`local_asn`, e.g. 65000).
- Type: `ipsec.1`.

### 2. VPN connection — on Transit Gateway (preferred) or VGW

**TGW (recommended):** enables ECMP across tunnels/connections and transitive
routing to other VPCs. Create a TGW with `VPN ECMP support` enabled, attach
your VPC(s), then create the Site-to-Site VPN connection targeting the TGW
and the CGW from step 1.

**VGW:** simpler, single-VPC only, no ECMP across connections. Fine for one
VPC + `ha_mode=single`.

Tunnel options to set on the connection (per tunnel):

| Option | Value |
|---|---|
| IKE version | IKEv2 only |
| Phase 1 encryption / integrity / DH | AES256-GCM-16 / SHA2-384 / group 20 |
| Phase 2 encryption / DH | AES256-GCM-16 / group 20 |
| Inside IPv4 CIDR | a /30 from 169.254.0.0/16 (constraints below) — coordinate with the Crusoe operator or let AWS auto-assign and report back |
| Pre-shared key | AWS-generated (default) or supply your own compliant string |

These match the module defaults (`terraform/aws/main.tf`) and the Crusoe-side
crypto profile — see [docs/crypto-profiles.md](crypto-profiles.md).

### 3. Inside CIDR constraints

AWS requires each tunnel inside CIDR to be a **/30 within 169.254.0.0/16**,
and reserves several blocks that you must not use, including:

`169.254.0.0/30`, `169.254.1.0/30`, `169.254.2.0/30`, `169.254.3.0/30`,
`169.254.4.0/30`, `169.254.5.0/30`, and `169.254.169.252/30` (adjacent to the
instance metadata service range).

This repo's convention (169.254.21.0/30 upward, see
[docs/ip-planning.md](ip-planning.md)) avoids all reserved blocks. AWS takes
the first usable address of each /30 and Crusoe the second — which matches
this repo's `bgp_remote_ip` (.1) / `bgp_local_ip` (.2) convention.

### 4. Hand off values to the Crusoe operator

From the VPN connection (console *Download configuration*, or
`aws ec2 describe-vpn-connections`), the Crusoe operator needs, per tunnel:

- Outside IP address → `tunnels[*].peer_public_ip`
- Inside IPv4 CIDR → `tunnels[*].bgp_inside_cidr` (+ derived local/remote IPs)
- Your ASN (TGW/VGW Amazon-side ASN) → `tunnels[*].remote_asn`
- Pre-shared key → `TF_VAR_tunnel_psks`

**PSK handoff — never email, never chat, never a ticket.** Use one of:

- A shared secret manager both parties can reach (AWS Secrets Manager with a
  cross-account resource policy, Vault, etc.) — hand over the ARN/path only.
- A one-time-view link (e.g., a burn-after-reading secret sharing service run
  by one of the parties).
- If the operator runs the `terraform/aws/` module themselves, the PSKs never
  leave their machine: `terraform output -json aws_tunnel_psks` feeds
  `TF_VAR_tunnel_psks` directly.

Rotate immediately if a PSK ever transits an insecure channel (AWS: *Modify
VPN tunnel options*; Crusoe: in-place rotation in
[docs/runbook.md §7](runbook.md#7-rotate--rekey)).

### 5. Routing

- **TGW:** with default route table association/propagation enabled, the VPN
  attachment propagates the BGP-learned Crusoe CIDRs into the TGW route
  table automatically. You still must add **return routes in each VPC route
  table**: Crusoe CIDRs → the TGW. The `terraform/aws/` module wires this
  when you pass `route_table_ids` + `crusoe_cidrs`; if you leave
  `route_table_ids = []`, that's on you.
- **VGW:** enable *route propagation* on the VPC route tables instead.
- Security groups / NACLs must permit the Crusoe CIDRs to reach your
  workloads.

## Verify

```bash
aws ec2 describe-vpn-connections --vpn-connection-ids <id> \
  --query 'VpnConnections[0].VgwTelemetry[].{ip:OutsideIpAddress,status:Status}'
```

Both tunnels `UP`. AWS also shows BGP status per tunnel in the console
(*Tunnel details*). If a tunnel is `DOWN`, work the decision tree in
[docs/runbook.md](runbook.md#6-troubleshoot-decision-tree) — with AWS the
usual suspects are cipher/tunnel-option mismatches and PSK copy errors.

Note AWS DPDs idle tunnels; the Crusoe side uses `start_action = trap` +
`dpd_action = restart`, so tunnels re-establish on traffic or DPD failure
without intervention.
