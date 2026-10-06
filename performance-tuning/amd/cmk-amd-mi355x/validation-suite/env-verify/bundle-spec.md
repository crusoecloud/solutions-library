# Bundle spec — reference for env-verify

The versions the suite was validated against. Compare the
`env-verify/logs/env-report-<node>-<ts>.txt` output from
[env-verify.sh](src/env-verify.sh) against this table, and update the table
when the deployed Crusoe software bundle changes.

| Component | Version |
|---|---|
| Bundle | B.MI355.2.1 |
| Linux kernel | `6.8.0-124-generic` |
| ROCm | `7.2.0` |
| RCCL | `2.27.7` |
| `amdgpu` module | `6.16.13` |
| AINIC firmware | `1.117.5-a-77` |
| Mellanox CX-7 firmware | `28.43.3608` |
| GPU | MI355X (`0x75a3`, gfx950, 256 CUs, 288 GB HBM3E) — 8 per node |
| NIC | AMD Pensando Pollara 400 — 8 × 400 Gbps VFs per node (`ionic_0…ionic_7`) |
| GPU-Direct path | dma-buf (`NCCL_DMABUF_ENABLE=1`) |
