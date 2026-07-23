# Routing Crusoe cluster / multi-VM traffic through the gateway VM

This documents a **validated** way to send traffic from other Crusoe hosts —
including CMK (Kubernetes) pods — out through the standalone VPN gateway VM to
the remote peer (GCP or AWS), and the platform constraint that makes it
necessary.

## The platform constraint (Crusoe VPC)

A Crusoe VM only receives packets whose **destination IP is its own**. A bare
IP packet addressed to a remote CIDR (e.g. `10.200.0.2`) with the gateway VM as
next-hop is **dropped by the fabric before it reaches the VM** — confirmed by
packet capture (only ARP arrives; the IP frame never does). There is no
user-managed VPC route table and no "disable source/dest check" /
"can-IP-forward" flag in the Crusoe CLI or Terraform provider (checked
`crusoe networking` and the provider binary).

Consequence: a Crusoe VM **cannot act as a plain L3 transit router** for other
VMs. The gateway carries its *own* traffic through the tunnel fine; forwarding
*other hosts'* traffic requires encapsulation so the fabric only ever sees
VM-to-VM packets (real destinations).

This is the same reason `ipsec-tunnel-cmk` runs strongSwan as pods and relies on
Cilium's vxlan: the encapsulated outer destination is always a real node IP.

## Validated architecture: node→gateway overlay + SNAT

```
pod → Cilium → node ──vxlan (outer dst = gateway VM IP)──▶ gateway VM
                                                              │ decap
                                                              │ SNAT to gateway LAN IP
                                                              ▼
                                                        IPsec tunnel → GCP/AWS
```

Three requirements, each learned empirically:

1. **Encapsulate the host→gateway hop.** Build a point-to-point overlay
   (vxlan/GENEVE/IPIP/WireGuard) from each host to the gateway VM's internal IP.
   The outer destination is the gateway VM itself, so the fabric delivers it.
   Route the remote CIDR into that overlay on the host.

2. **Open the gateway's host firewall for the overlay.** The gateway's
   `nftables` input chain is default-deny; add an allow for the overlay
   transport (e.g. `udp dport 4789` for vxlan) from the Crusoe VPC CIDR.
   Otherwise the kernel drops the encapsulated packet before decapsulating it.

3. **SNAT on the gateway to an advertised, peer-allowed source.** After decap,
   masquerade/SNAT the inner traffic to the gateway's **LAN IP** (which is
   inside `crusoe_vpc_cidrs` and advertised via BGP). Do **not** let it egress
   with the overlay link-local or the tunnel `/30` source — the peer's firewall
   only accepts the advertised CIDR and would drop it, and return routing would
   fail. With SNAT to the LAN IP, the peer accepts the traffic and returns it
   through the tunnel to the gateway, which un-SNATs and sends it back over the
   overlay.

### Proof (2026-07-23, iceland ⇄ GCP us-east4)

- CMK pod `10.234.0.104` → GCP `10.200.0.2`: ICMP 0% loss (~130 ms iceland↔us-east4),
  20 MB HTTP transfer completed (HTTP 200).
- Node hostNetwork → GCP: same, plus ~92 Mbit/s single-stream over the
  double-encapsulated path.

## Trade-offs vs. `ipsec-tunnel-cmk`

| | This (standalone gateway + overlay) | ipsec-tunnel-cmk (strongSwan as pods) |
|---|---|---|
| strongSwan / PSKs location | off the cluster, on a hardened VM | privileged pods inside the cluster |
| One gateway serves | multiple clusters + non-k8s VMs | one cluster |
| Extra overlay | yes (node→gateway) | no (reuses Cilium vxlan) |
| Per-pod source identity at peer | lost under SNAT (all traffic = gateway IP) | preserved (advertise pod CIDR) |
| Best when | you want the VPN isolated from workloads / shared | you want the simplest CMK-only path |

For a CMK-only deployment, `ipsec-tunnel-cmk` is simpler. Choose the standalone
gateway when you want the VPN termination isolated from the cluster (no
privileged pods, PSKs off the nodes) or shared across several clusters/VMs.

## Productization status

The mechanism is proven manually. Making it a first-class feature would add:
a node-side overlay DaemonSet (build vxlan to the gateway, route the remote
CIDR in), the gateway firewall allow, and the gateway SNAT rule — none of which
exist in the module yet. Until then, treat this page as a validated runbook,
not automation.
