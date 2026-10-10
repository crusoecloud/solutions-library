# Validation

Acceptance and smoke tests for Crusoe Cloud GPU nodes, organized by vendor. Each solution
provisions or targets a set of nodes, checks each node on its own, then runs collective
communication across the set and reports pass/fail against reference numbers.

| Solution | Platform | What it validates |
|---|---|---|
| [AMD MI355X VMs](./AMD/mi355x-vms/) | Crusoe VMs (`mi355x-288gb-roce.8x`) | Terraform + Ansible smoke test (~12 min): software versions, GPUs, ECC, Pollara NIC rails, RVS GEMM throughput and 8-GPU RCCL per node, then RCCL all_reduce and all_gather across every node, with a markdown report |

For MI355X on Crusoe Managed Kubernetes, see [cmk-amd-mi355x](../cmk-amd-mi355x/).
