# Tested-against matrix

One row per full test-suite run (see [README.md](README.md) for the phases).
Record versions exactly as resolved (`terraform providers` output / `apt policy` on the VM; lock files are gitignored, so the constraints below are the committed pinning),
plus measured baselines.

## Pinned versions (current)

| Component | Constraint | Resolved |
|---|---|---|
| Terraform | `>= 1.9.0` (crusoe render test), `>= 1.7.0` (gcp/aws modules) | — |
| Crusoe provider (`crusoecloud/crusoe`) | `~> 0.5.44` | `0.5.46` |
| Google provider (`hashicorp/google`) | `~> 6.0` | `6.50.0` at build |
| AWS provider (`hashicorp/aws`) | `~> 5.0` | `5.100.0` at build |
| OS image | `ubuntu24.04:latest` | — |
| strongSwan / FRR | apt-current at bootstrap (Ubuntu 24.04 archive + security) | record from VM |

## Runs

| Date | Cloud | ha_mode | Terraform | crusoe | google/aws | strongswan | frr | Phases run | Result | Notes (throughput floor, failover loss, reconverge) |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-07-23 | gcp | single | >=1.9 | 0.5.46 | google 6.50.0 | 5.9.13-2ubuntu4 | 8.4.4 (ubuntu) | 0–5 | PASS | Crusoe us-east1-a ⇄ GCP us-east4. RTT ~5 ms; single-stream HTTP through tunnel ~460 Mbit/s (curl, 20 MB, no stall — MSS clamp proven); failover loss 0% over 120 s window (kernel prunes dead ECMP nexthop instantly, BGP hold 30 s); rekey loss 0%; reboot recovery clean; security 6/6 (IKEv1/weak-proposal probes skipped: no ike-scan on runner; SSH-filtered probe skipped: allow-listed caller). Phase 6 teardown pending. |
| 2026-07-24 | gcp | single | >=1.9 | 0.5.46 | google 6.50.0 | 5.9.13-2ubuntu4 | 8.4.4 (ubuntu) | cluster-egress | PASS | Crusoe eu-iceland1-a ⇄ GCP us-east4, `cluster_egress.enabled` snat_mode=gateway. Fresh-boot bootstrap validated (tunnels+BGP+data plane auto-up, no manual restart). CMK pod → node vxlan overlay → gateway → IPsec → GCP: 0% loss + 20 MB HTTP 200. **Multi-node (2 pool nodes) both PASS**; gateway auto-populated PERMANENT neigh for all 10 cluster nodes via the reconcile loop (deterministic MAC). **Churn:** deleting a node's DaemonSet pod self-healed with no traffic loss. snat_mode=node + WireGuard transport render-tested, live re-validation pending. |
