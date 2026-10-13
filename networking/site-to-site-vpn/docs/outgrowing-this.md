# Outgrowing this solution

This repo is a software VPN on general-purpose VMs. It is the right answer
for getting connected in an afternoon, for dev/test, and for moderate
production traffic. It has two structural ceilings you should know about
before betting heavier workloads on it.

## Ceiling 1: software IPsec throughput

Every packet is encrypted/decrypted in the kernel on a VM's CPU. Practical
expectations:

- A single IPsec SA is largely **single-flow, single-core bound**: with
  AES-GCM and AES-NI, expect on the order of **1–5 Gbit/s per tunnel**
  depending on instance CPU, packet size, and the far end. The managed
  gateways have their own per-tunnel caps too (AWS ~1.25 Gbit/s per tunnel;
  GCP ~1.5–3 Gbit/s per tunnel).
- ECMP across two tunnels helps aggregate throughput but not a single flow
  (per-flow hashing keeps one flow on one tunnel).
- MTU 1400 + MSS 1360 means more packets per byte than a LAN; small-packet
  workloads hit packets-per-second limits before bandwidth limits.

Symptoms you've hit it: VPN VM CPU pegged on softirq/crypto, throughput flat
while adding parallel streams, latency rising under load. A bigger
`instance_type` and more tunnels buy some headroom — measure with
`iperf3` (Phase 3 in `tests/README.md`) and record it in `tests/matrix.md`.

## Ceiling 2: single-VM SPOF and operational surface

- `ha_mode=single` is a hard SPOF: VM reboot, kernel update, or host failure
  drops the link for boot+bootstrap time.
- `ha_mode=dual` removes the VM SPOF but doubles the fleet you patch,
  monitor, and rotate, and it is still **your** strongSwan/FRR to operate —
  no SLA, no managed control plane.
- Day-2 config changes that touch the startup script replace VMs (see
  runbook §7).

## When to graduate

Move to a dedicated/partner interconnect when any of these hold:

| Trigger | Why the VPN loses |
|---|---|
| Sustained > a few Gbit/s, or single flows > ~1 Gbit/s | software crypto + per-tunnel caps |
| Latency/jitter-sensitive traffic (storage replication, RDMA-adjacent) | internet path + encryption overhead |
| Contractual availability targets | no SLA on a self-run VPN over internet |
| Many customer VPCs/regions | per-deployment VM sprawl |

The graduation path is a physical or partner interconnect between Crusoe and
the customer cloud (AWS Direct Connect / GCP Cloud Interconnect on the
customer side) — dedicated capacity, deterministic latency, provider SLAs.

## Migration outline (no-flag-day cutover)

Because this design is BGP end-to-end, you can migrate without renumbering or
a hard cutover:

1. **Parallel-run.** Stand up the interconnect alongside the VPN. Establish
   BGP on the new path advertising the same prefixes both ways.
2. **Prefer the new path.** Make the interconnect win BGP best-path while
   the VPN stays as backup: on the Crusoe FRR side, set higher
   **local-preference** for routes learned via the interconnect (or AS-path
   prepend outbound on the VPN sessions); mirror the preference on the cloud
   side (GCP: advertised route priority / MED; AWS: DX is already preferred
   over VPN on equal prefix length by default).
3. **Verify traffic shifted.** `ip route show proto bgp` nexthops move off
   the `ipsecN` interfaces; tunnel throughput drops to keepalive levels.
4. **Soak, then decide the VPN's fate.** Either keep it as a cold/warm
   backup path (it is cheap) or `terraform destroy` it per runbook §8.

Rollback at any point is "remove the preference" — the VPN path is still
established underneath.
