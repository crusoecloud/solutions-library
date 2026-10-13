# IP planning, multi-tenancy, isolation

## Overlap is the top day-one hazard

Three CIDR sets are in play, and **no pair may overlap**:

1. `crusoe_vpc_cidrs` — what Crusoe advertises via BGP
2. `customer_cidrs` — what the customer advertises back
3. `tunnels[*].bgp_inside_cidr` — the link-local /30s

If the Crusoe VPC and the customer VPC share address space, BGP will happily
install routes that black-hole or hairpin traffic, and the failure mode is
"some hosts unreachable, others fine" — miserable to debug. Plan address
space **before** deploying.

### The Terraform guard

`terraform/crusoe/main.tf` has a `precondition` that cross-checks every pair
across the three sets at plan time. Feeding it overlapping CIDRs fails the
plan before anything is created:

```
Error: Resource precondition failed

  on main.tf line ..., in resource "terraform_data" "cidr_overlap_guard":
     condition = alltrue([...])

CIDR overlap detected between crusoe_vpc_cidrs, customer_cidrs, and/or bgp_inside_cidrs. See docs/ip-planning.md.
```

This is also exercised as a negative test — see `tests/README.md` (Phase 0).

## /30 allocation convention

Each tunnel needs a /30 inside 169.254.0.0/16 for its BGP session. This repo
allocates **from `169.254.21.0/30` upward**, one /30 per tunnel:

| Tunnel | Inside CIDR | Customer BGP IP | Crusoe BGP IP |
|---|---|---|---|
| tunnel-a | 169.254.21.0/30 | 169.254.21.1 | 169.254.21.2 |
| tunnel-b | 169.254.22.0/30 | 169.254.22.1 | 169.254.22.2 |
| (next) | 169.254.23.0/30 | .1 | .2 |

Rules:

- **Customer = first usable (.1), Crusoe = second (.2).** This matches AWS's
  convention (AWS takes the low address) and the `terraform/gcp/` module
  (`cidrhost(c, 1)` = GCP, `cidrhost(c, 2)` = Crusoe), so one convention
  works for both clouds.
- **Avoid AWS-reserved blocks**: `169.254.0.0/30` through `169.254.5.0/30`
  and `169.254.169.252/30` (near the metadata service). Starting at
  169.254.21.0 clears all of them with margin.
- Unique per tunnel — enforced by a variable validation on
  `bgp_inside_cidr`.

## Per-customer isolation

Each customer deployment is fully independent:

- **Own Terraform state** — one workspace/state per customer; no shared
  state.
- **Own VM(s)** — no VPN VM terminates tunnels for two customers.
- **Own routing domain** — a separate FRR instance per deployment; there is
  no shared BGP fabric, so one customer's route churn or leak cannot touch
  another. Prefix filters (`CUSTOMER-IN` / `CRUSOE-OUT`) additionally pin
  each session to exactly the agreed CIDRs.

Inside /30s may repeat *across* customers (they're link-local and never
routed), but keep `crusoe_vpc_cidrs` disjoint per customer if the deployments
share any upstream routing.

## Non-transitive peering (customer-side scope)

The tunnel reaches **only the landing VPC** on the customer side. Plain VPC
peering is non-transitive on both AWS and GCP: a VPC peered to the landing
VPC does **not** get a path through the tunnel. Multi-VPC reach requires:

- **AWS:** Transit Gateway (this is why the `terraform/aws/` module
  terminates on a TGW), with the additional VPCs attached and routed.
- **GCP:** Network Connectivity Center (hub-and-spoke), or per-VPC HA VPN.

Either way it is the **customer's responsibility** — this repo provisions and
documents up to the landing VPC only. State the reachable CIDRs explicitly in
`customer_cidrs`; anything else is filtered.

## NAT escape hatch

When overlap is genuinely unavoidable (e.g., both sides use 10.0.0.0/8
internally and neither can renumber), the escape hatch is **per-customer
NAT**: pick a dedicated, non-overlapping "presentation" CIDR per side and
NAT real addresses behind it at the tunnel edge (nftables `snat`/`dnat` on
the Crusoe VPN VM; private NAT gateway or equivalent on the cloud side). Then
advertise only the presentation CIDRs via BGP. This is deliberately **not
automated** here — it complicates troubleshooting, breaks protocols that
embed addresses, and should be a last resort. Renumber if you can.
