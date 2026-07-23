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
| 2026-07-23 | gcp | single | >=1.9 | 0.5.46 | ~>6.0 | n/a | n/a | 0 only | static PASS | not yet run against live cloud — static phases only; baselines TBD at first live deploy |
