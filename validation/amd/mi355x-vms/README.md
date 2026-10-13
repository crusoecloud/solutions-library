# AMD MI355X Validation for Crusoe VMs

A Terraform + Ansible smoke test for AMD Instinct **MI355X** VMs (`mi355x-288gb-roce.8x`:
8× MI355X + 8× AMD Pensando Pollara 400 AI NICs per node). It provisions the VMs, checks
every node on its own (software versions, GPUs, NIC rails, GEMM throughput, 8-GPU RCCL),
then runs RCCL **all_reduce** and **all_gather** across the whole set, and writes a
markdown report. Use it to accept a new set of MI355X nodes, or to re-check a cluster
before a long training run. A full pass takes about **12 minutes** (prep ~1, smoke ~7, multi-node ~3); the per-node steps run in parallel, so time grows only slowly with node count.

It also works on VMs you already have — skip the Terraform step and write the inventory by
hand (see [Bring your own VMs](#bring-your-own-vms)).

## What it checks

| Step | Playbook | Runs on | Pass criteria |
|---|---|---|---|
| Environment | `10-smoke.yml` | every node, in parallel | ROCm, amdgpu, RCCL, ANP, ionic, OpenMPI, UCX, vastnfs and firmware versions match [`bundle-2.2.env`](scripts/rdma/bundle-2.2.env); 8 GPUs; 0 uncorrectable ECC; 8 rails `ACTIVE` with a RoCEv2 GID; PCIe x16; no amdgpu/ionic errors in `dmesg` |
| Rails | `10-smoke.yml` | every node | 8/8 `ionic` rails up, GID present |
| GEMM | `10-smoke.yml` | every node, all 8 GPUs at once | ROCm Validation Suite (RVS) GST: FP8 / BF8 / FP16 / BF16 GEMMs at 8K×8K×16K each meet AMD's per-GPU target in the MI355X config |
| RCCL, 1 node | `10-smoke.yml` | every node | `all_reduce_perf` 2G–32G over 8 GPUs: avg busbw ≥ 360 GB/s, 0 wrong |
| RCCL, all nodes | `30-multinode.yml` | anchor node + every node that passed the smoke | `all_reduce_perf` and `all_gather_perf` 2G–32G: see [Pass criteria](#pass-criteria) |
| Rails pairwise (opt-in) | `30-multinode.yml -e steps=rails,scale` | anchor vs each node | same-rail `ib_write_bw` ≥ 320 Gb/s per rail |

## Layout

```
terraform/            VMs, optional transport partition, generates inventory/ and keys/
ansible/
  00-prep.yml         node-to-node SSH, MPI hostfile, copy scripts, wait for 8 GPUs
  10-smoke.yml        per-node checks (env, rails, GEMM, 1-node RCCL) -> results/smoke-<ts>/
  30-multinode.yml    multi-node RCCL from an anchor node -> results/multinode-<ts>/
scripts/
  rdma/               env_verify.sh, rail_census.sh, rail_rate.sh, pair_rail.sh, bundle-2.2.env
  rccl/               run_rccl_mi355x.sh, rccl_env.sh, thresholds.env, build_rccl_tests.sh
  gemm/               run_rvs_gst.sh
  parse_results.py    results/ -> markdown report
```

## Prerequisites

- A Crusoe project with MI355X capacity and a RoCE transport network in the target location,
  and the [Crusoe CLI](https://docs.crusoecloud.com/) configured (`~/.crusoe/config`).
- Terraform ≥ 1.5, Ansible (`ansible-core` ≥ 2.15 with the `ansible.posix` collection),
  `rsync`, and Python 3 on your workstation:
  ```bash
  pip install ansible-core && ansible-galaxy collection install ansible.posix
  ```
- An SSH key pair. It is the only key put on the VMs.
- The VM image `ubuntu24.04-amd-mi355-vm-bundle2.2` (ROCm 7.2.0, RCCL 2.27.7, rccl-tests,
  ANP plugin, OpenMPI 4.1.6, RVS). Nothing is installed on the nodes; the scripts use what
  the image ships (`scripts/rccl/build_rccl_tests.sh` is an optional fallback if an image
  lacks rccl-tests).

## Quick start

### 1. Provision the VMs

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in project, location, subnet, network, partition, key
terraform init

# Canary: confirm the image boots before creating the rest
terraform apply -var node_count=1

# Full set. -parallelism raises Terraform's default of 10 concurrent creates.
terraform plan  -var node_count=<N> -parallelism=<N> -out=full.tfplan
terraform apply -parallelism=<N> full.tfplan
```

`terraform apply` writes, at the top of this directory:

| File | Used by |
|---|---|
| `inventory/hosts.ini` | Ansible (public IPs, private IPs, VM IDs) |
| `inventory/hostfile`, `inventory/nodes` | mpirun / pair-rail (private IPs) |
| `inventory/vms.tsv` | name, VM ID, public and private IP |
| `keys/cluster_ssh_key{,.pub}` | node-to-node SSH for mpirun (installed by `00-prep.yml`) |

Wait until every VM is `STATE_RUNNING`
(`crusoe compute vms list --project-id <project-id> | grep <name_prefix>`).

### 2. Run the smoke test

```bash
cd ../ansible
ulimit -n 4096                        # macOS: default 256 open files is too low for 40 parallel workers
ansible-playbook 00-prep.yml          # ~1 min
ansible-playbook 10-smoke.yml         # ~7 min, all nodes in parallel
ansible-playbook 30-multinode.yml     # ~3 min, all_reduce + all_gather on every smoke-passing node
```

`10-smoke.yml` ends with a per-node table; `30-multinode.yml` ends with one `RESULT` line
per collective:

```
RESULT run=rccl-all_reduce-n<N>-... collective=all_reduce nodes=<N> verdict=PASS avg_busbw=... peak_busbw=...@16G gate=peak>=360 ...
```

### 3. Build the report

```bash
python3 ../scripts/parse_results.py          # newest results/smoke-* and results/multinode-*
```

It prints a markdown report and saves it as `results/report-<ts>.md`: per-check pass counts,
failing nodes with their VM IDs, a per-node table, and the multi-node results with average
busbw, peak busbw with the message size it was reached at, and busbw at every message size.

### 4. Clean up

```bash
cd ../terraform && terraform destroy
```

## Reference results

Measured on `ubuntu24.04-amd-mi355-vm-bundle2.2:2026-10-05` (ROCm 7.2.0, RCCL 2.27.7,
AINIC 1.117.5-a-196). Busbw is the rccl-tests out-of-place column, float sum, in GB/s.

| Test | Expected |
|---|---|
| GEMM FP8 8K×8K×16K | ~3.4–4.0 PFLOPS per GPU (target 2.06) |
| GEMM BF16 8K×8K×16K | ~1.6–1.7 PFLOPS per GPU (target 0.96) |
| all_reduce, 1 node | ~368 avg |
| all_reduce, 2–16 nodes | ~380–384 avg; peak ~383–386 |
| all_reduce, 32+ nodes | peak ~375–385 at 16–32G; 2G drops to ~210–245 |
| all_gather, 32+ nodes | peak ~360–382 at 4–8G (varies run to run) |
| Per-rail traffic during all_reduce | ~405 Gb/s tx and rx on each of the 8 rails |
| `ib_write_bw` per rail, 4 QPs | ~389 Gb/s |

## Pass criteria

All gates live in [`scripts/rccl/thresholds.env`](scripts/rccl/thresholds.env) and can be
overridden with environment variables.

| Collective | 1 node | 2–8 nodes | > 8 nodes |
|---|---|---|---|
| all_reduce | avg ≥ 360 | avg ≥ 370 | **peak** ≥ 360 |
| all_gather | avg ≥ 330 | avg ≥ 340 | **peak** ≥ 340 |

Every run also needs `#wrong == 0`, no out-of-bounds values, and no fabric errors
(`status=12`, CQE errors, port errors). A hang (no completion within 900 s) is a failure.

Why the peak above 8 nodes: in a 2G–32G sweep the 2G size is latency-bound at scale (each
ring step moves only a few MB per rank), so the mean drops well below line rate even on a
healthy fabric. The 16–32G sizes still reach ~375–385 GB/s, and a slow node or rail caps
every size, so the peak is the meaningful number.

## Options

| Command | Effect |
|---|---|
| `ansible-playbook 10-smoke.yml -l <node>,<node>` | re-test specific nodes |
| `ansible-playbook 10-smoke.yml -e steps=env,rails` | only the quick checks (any of `env,rails,gemm,rccl`) |
| `ansible-playbook 10-smoke.yml -e gemm_full=true` | full RVS `gst_single.conf` (15 GEMMs, one GPU at a time, ~45 min) |
| `ansible-playbook 10-smoke.yml -e fix_sysctl=true` | set and persist `ndisc_notify=1` (see [Gotchas](#gotchas)) |
| `ansible-playbook 30-multinode.yml -e scale_sizes=auto` | also run 2, 4, 8, 16, … nodes to see the scaling curve |
| `ansible-playbook 30-multinode.yml -e scale_sizes=2,8` | specific node counts (the full set is always included) |
| `ansible-playbook 30-multinode.yml -e collectives=all_reduce,all_gather,reduce_scatter,alltoall` | add collectives |
| `ansible-playbook 30-multinode.yml -e steps=rails,scale` | add the pairwise per-rail test (~1.5 min per node) |
| `ansible-playbook 30-multinode.yml -e use_all=true` | every inventory node, ignoring smoke results |
| `ansible-playbook 30-multinode.yml -e min_bytes=1G -e max_bytes=8G` | different message-size sweep |

Run a single collective by hand from any node after `00-prep.yml`:

```bash
cd ~/validation/rccl
./run_rccl_mi355x.sh -c all_gather -n 4             # first 4 hosts of ~/hostfile
./run_rccl_mi355x.sh -c all_reduce -H <ip1>,<ip2>   # explicit hosts
./run_rccl_mi355x.sh --help
```

Watch the rails while a job runs (per-rail Gb/s plus retransmit, retry-exceeded, CQE error and
CNP/ECN counter deltas):

```bash
~/validation/rdma/rail_rate.sh 5
```

## Bring your own VMs

Skip Terraform and create `inventory/hosts.ini` and `inventory/hostfile` by hand:

```ini
# inventory/hosts.ini
[mi355x]
node-01 ansible_host=<public-ip> private_ip=<private-ip> vm_id=<vm-id>
node-02 ansible_host=<public-ip> private_ip=<private-ip> vm_id=<vm-id>

[mi355x:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=/path/to/private/key
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

```
# inventory/hostfile (private IPs, same order)
<private-ip> slots=8
<private-ip> slots=8
```

Also create `inventory/nodes` (one private IP per line) and a key pair for node-to-node SSH
at `keys/cluster_ssh_key` (`ssh-keygen -t ed25519 -N '' -f keys/cluster_ssh_key`).

## Gotchas

- **`amd-smi` reports "driver not initialized" right after boot.** `00-prep.yml` retries for
  up to 3 minutes before giving up.
- **`ndisc_notify` WARN in env_verify.** The image does not set
  `net.ipv6.conf.*.ndisc_notify=1`. It is recommended (avoids an IPv6 neighbor-discovery wedge
  after a rail reset) but does not affect a fresh boot. Use `-e fix_sysctl=true` to set it.
- **A single-node RCCL run occasionally dips at the first message size.** Re-test the node
  (`ansible-playbook 10-smoke.yml -l <node> -e steps=rccl`) before treating it as bad.
- **`30-multinode.yml` uses the newest smoke `summary.csv`**, which only lists the nodes of
  that run. After re-testing a few nodes with `-l`, run a full smoke again or pass
  `-e use_all=true`, otherwise the multi-node run covers only the re-tested nodes.
- **alltoall needs PXN.** The 8 rails are isolated planes, so GPU *i* on one node can only
  reach GPU *i*'s rail on another. alltoall sends GPU *i* → GPU *j*, which must be forwarded
  over xGMI first. `run_rccl_mi355x.sh` sets `NCCL_PXN_DISABLE=0` for alltoall; with PXN
  disabled, inter-node alltoall hangs or fails with `status=12` at any size.
- **`ib_write_bw` needs 4 QPs and one rail at a time** to show line rate. A single QP tops out
  around 260 Gb/s, and running all 8 rails of a node at once saturates VM host memory
  (150–290 Gb/s per rail). `pair_rail.sh` defaults to both.
- **The image's `perftest` is not built with ROCm**, so GPU-direct (`--use_rocm`) RDMA tests
  are not part of this suite.
- **Ansible crashes with "Unexpected Exception ... process object is closed".** The open-file
  limit is too low for 40 parallel SSH workers (macOS terminals default to 256). Run
  `ulimit -n 4096` in the shell first, or lower parallelism with `-f 10`. The playbooks check
  this at start-up.
- **Ansible errors with "requires blocking IO on stdin/stdout/stderr"** when its output is
  piped in some terminals. Redirect to a file instead (`ansible-playbook ... > run.log 2>&1`).
- **Changing `ssh_public_key_path` recreates every VM** (the key can only be set at creation).
  Image changes are ignored so a tag bump never replaces running VMs.

## Interpreting failures

| Symptom | Likely cause | Next step |
|---|---|---|
| env FAIL on a version | node built from a different image | recreate the VM with the right image tag |
| rail not `ACTIVE`, or GID missing | rail did not come up | reboot the VM once; if it persists, contact Crusoe support with the VM ID |
| `pcie_link` x8 on a rail | rail trained at reduced width (caps ~223 Gb/s) | hardware issue; contact Crusoe support with the VM ID |
| GEMM below target on one GPU | throttling or a degraded GPU | re-run `-e steps=gemm` on that node; if it repeats, contact support |
| multi-node `status=12` / CQE errors | a peer stopped acknowledging on a rail; the **peer** IP in the log is the suspect | re-run without that node; check its rails with `rail_census.sh`, or run `-e steps=rails,scale` |
| multi-node HANG | a node that cannot reach the others on one or more rails | run `30-multinode.yml -e scale_sizes=auto` to find the smallest failing set |
| segfault at RCCL init | node-level fault | the node fails in every set it joins; remove it and re-test it alone |
