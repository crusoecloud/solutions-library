# Performance Tuning

Cluster validation and performance benchmarking for Crusoe GPU clusters: NCCL / RCCL collective tests and InfiniBand health checks. Use these before a long training run, after provisioning a new nodepool, or when investigating a suspected straggler node.

Solutions are grouped by GPU vendor: `nvidia/` and `amd/`.

| Solution | Description |
|---|---|
| [cmk-nccltests](./nvidia/cmk-nccltests/) | SKU-tuned NCCL all_reduce MPIJobs (B200, B300, GB200, H100, H200) |
| [ib-health-probe-cmk](./nvidia/ib-health-probe-cmk/) | Per-HCA InfiniBand health probe for CMK |
| [cmk-amd-mi355x](./amd/cmk-amd-mi355x/) | AMD MI355X acceptance and validation suite |
| [ib-write-test-mi355x](./amd/ib-write-test-mi355x/) | Parallel `ib_write_bw` sweep across MI355X nodes |
