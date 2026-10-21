# NVIDIA GB200 NVL72 Rack Validation for Crusoe VMs

A Terraform + Ansible smoke test for a **GB200 NVL72 rack** on Crusoe VMs: up to 18
`gb200-186gb-nvl-ib.4x` VMs (4 GB200 GPUs each) pinned to one NVLink domain. It provisions the
VMs, sets up IMEX for multi-node NVLink (MNNVL), checks every node in parallel, then runs NCCL
**all_reduce** and **all_gather** across the rack and verifies the traffic stayed on NVLink.
A full pass takes about 10 minutes.

You supply a project ID, an SSH public key and the NVLink domain (rack); the subnet, transport
network and IB partition are looked up or created automatically.

## What it checks

| Step | Playbook | Pass criteria |
|---|---|---|
| IMEX domain | `00-prep.yml` | every GB200 node in `nodes_config.cfg`; `nvidia-imex-ctl -N`: domain UP, every node READY, all pairs Connected |
| Environment | `10-smoke.yml` | driver / CUDA / DOCA / kernel match [`bundle-gb200-1.0.env`](scripts/env/bundle-gb200-1.0.env); 4 GPUs; no uncorrectable ECC or row-remap failures; NVLink fabric `Completed`; IMEX running; 4 × 400G IB rails ACTIVE; local NVMe controllers `live`; no Xid / NVMe-reset / XFS-shutdown in `dmesg` |
| NVLink domain | `10-smoke.yml` | every node reports the same ClusterUUID / CliqueId |
| GEMM | `10-smoke.yml` | `dcgmproftester` tensor-core GEMM, 60 s on all 4 GPUs: every GPU ≥ 1100 TFLOPS and within 10% of the node's best |
| NCCL, 1 node | `10-smoke.yml` | `all_reduce_perf` 2G–32G on 4 GPUs: avg busbw ≥ 640 GB/s |
| NCCL, rack | `30-multinode.yml` | `all_reduce_perf` / `all_gather_perf` 2G–32G on every smoke-passing node: avg busbw ≥ 800 / ≥ 650 GB/s, 0 wrong, NCCL reports `MNNVL ... cliqueSize <ranks>` |
| Local NVMe (optional) | `20-nvme-raid.yml`, `25-fio.yml` | RAID0 scratch volume at `/scratch/local`; fio benchmark vs the OS disk (reported, not gated) |
| DCGM diag (optional) | `10-smoke.yml -e dcgm_diag=true` | `dcgmi diag` memory, diagnostic, pcie, memory_bandwidth, targeted_stress, targeted_power |

## Layout

```
terraform/            GB200 VMs pinned to one NVLink domain, optional CPU VMs, IB partition; writes inventory/ and keys/
ansible/
  00-prep.yml         wait for boot, node-to-node SSH, hostfile, scripts, IMEX setup + check
  10-smoke.yml        per-node checks (env, GEMM, 1-node NCCL) -> results/smoke-<ts>/
  20-nvme-raid.yml    (optional) RAID0 over the local NVMe drives, XFS at /scratch/local
  25-fio.yml          (optional) fio: /scratch/local vs the OS disk -> results/fio-<ts>/
  30-multinode.yml    NCCL across the rack from an anchor node -> results/multinode-<ts>/
scripts/              env/ gemm/ nccl/ raid/ storage/ runners, parse_results.py (results/ -> markdown report)
```

## Prerequisites

- A Crusoe project with GB200 capacity in one NVLink domain, and the
  [Crusoe CLI](https://docs.crusoecloud.com/) configured.
- Terraform ≥ 1.5, Ansible (`ansible-core` ≥ 2.15 with `ansible.posix`), `rsync`, Python 3.
- An SSH key pair; its public key is the only key put on the VMs.
- VM image `ubuntu24.04-nvidia-b.gb200.1.0` (arm64; driver, CUDA, DOCA, nvidia-imex, DCGM and
  nccl-tests preinstalled). Nothing else is installed on the nodes.

## Quick start

### 1. Provision

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id, ssh_public_key_path, nvlink_domain_id
terraform init
terraform apply -var gpu_node_count=1          # canary: confirms image, capacity and placement
terraform apply -parallelism=20                # the full set (gpu_node_count in terraform.tfvars)
```

**Finding `nvlink_domain_id`** (required for more than one GB200 VM):

```bash
# NVLink domains with free GB200 capacity for the project
crusoe networking nvl-domains list --project-id <project-id>

# The domain of a GB200 VM that already exists (e.g. to add VMs to the same rack)
crusoe compute vms get <vm-name> --project-id <project-id> -f json | jq -r .nvlink_domain_id
```

The list only shows domains with free capacity for the project, so it is empty when the project
has no GB200 capacity reserved or when existing VMs already use all of it. Ask your Crusoe
contact for the domain in that case.

`terraform apply` writes `inventory/hosts.ini`, `inventory/hostfile`, `inventory/imex_nodes`,
`inventory/vms.tsv` and `keys/cluster_ssh_key` (node-to-node SSH for MPI) at the top of this
directory. Set `cpu_node_count` to also create general-purpose CPU VMs in the same subnet; the
tests do not need them.

### 2. Run the smoke test

```bash
cd ..
ulimit -n 4096                              # macOS default (256) is too low for parallel SSH
ansible-playbook ansible/00-prep.yml        # ~3 min; waits for the VMs to finish booting
ansible-playbook ansible/10-smoke.yml       # ~4 min, all nodes in parallel
ansible-playbook ansible/30-multinode.yml   # ~3 min, all_reduce + all_gather across the rack
python3 scripts/parse_results.py            # markdown report -> results/report-<ts>.md
```

Optional local storage (see below):

```bash
ansible-playbook ansible/20-nvme-raid.yml -e nvme_raid_wipe=true   # fresh VMs: build /scratch/local
ansible-playbook ansible/25-fio.yml                                # ~8 min, all nodes in parallel
```

### 3. Clean up

```bash
cd terraform && terraform destroy
```

## Reference results

nccl-tests out-of-place busbw, float sum, 2G–32G sweep, GB/s:

| Test | Expected |
|---|---|
| all_reduce, 1 VM (4 GPUs) | ~681 avg |
| all_reduce, 2 VMs | ~834 avg |
| all_reduce, 16–18 VMs | ~870–890 avg, ~930 peak at 32G |
| all_gather, 16–18 VMs | ~670–685 avg |
| GEMM, `dcgmproftester13 -t 1004` | ~1210–1280 TFLOPS per GPU |

Gates are in [`scripts/nccl/thresholds.env`](scripts/nccl/thresholds.env) and step down for
smaller sets (1 VM, ≤ 8 VMs); expected versions are in
[`scripts/env/bundle-gb200-1.0.env`](scripts/env/bundle-gb200-1.0.env). Both can be overridden
with environment variables.

## Local NVMe scratch (RAID0)

`20-nvme-raid.yml` stripes each VM's local NVMe drives into one md RAID0 (512 KiB chunk) with
XFS at `/scratch/local` (mode `1777`).

```bash
ansible-playbook ansible/20-nvme-raid.yml --check                  # preview what would be erased
ansible-playbook ansible/20-nvme-raid.yml -l <node>                # one node; builds only if every drive is blank
ansible-playbook ansible/20-nvme-raid.yml -e nvme_raid_wipe=true   # ERASE existing filesystems on the drives, then build
ansible-playbook ansible/20-nvme-raid.yml -e scratch_alias=/mnt/nvme   # also link an existing (empty) path to it
```

- Drives are found by `/dev/disk/by-id`; the boot disk is never touched, and drives in use are
  never erased. Re-running on a node with a healthy array changes nothing.
- A boot-time unit reassembles the array after a guest reboot (data kept).
- **Local NVMe is ephemeral**: data survives a guest reboot but not a VM stop/start, host
  maintenance or migration. Use it as a cache.

`25-fio.yml` installs `fio` if missing and benchmarks `/scratch/local` and the OS disk
(sequential and random, read / write / mixed, large and small files). Files it writes are
deleted when each job ends; the playbook fails if anything is left behind. Results:
`results/fio-<ts>/summary.{txt,csv}`. It saturates the disks, so run it on idle nodes.

## Options

| Command | Effect |
|---|---|
| `ansible-playbook ansible/10-smoke.yml -e steps=env` | only some steps (any of `env,gemm,nccl`) |
| `ansible-playbook ansible/10-smoke.yml -e dcgm_diag=true` | add DCGM diagnostics (~3 min) |
| `ansible-playbook ansible/30-multinode.yml -e scale_sizes=auto` | also 2, 4, 8, … nodes (scaling curve) |
| `ansible-playbook ansible/30-multinode.yml -e collectives=all_reduce,all_gather,reduce_scatter,alltoall` | more collectives |
| `ansible-playbook ansible/30-multinode.yml -e use_all=true` | every GB200 node, ignoring smoke results |
| `NCCL_IB_HCA=auto` (runner env) | for runs across NVLink domains: use the 400G IB rails |
| `NET_CIDR=<subnet>` (runner env) | override the auto-detected VPC subnet MPI uses |
| `ALLOW_BUSY=1` (runner env) | run even if another process holds GPU memory |
| `static_public_ip_nodes` (tfvars) | VMs whose public IP was switched to static outside Terraform |

### Testing a subset of nodes

`00-prep.yml`, `10-smoke.yml`, `20-nvme-raid.yml` and `25-fio.yml` accept `-l <node>,<node>`.
`30-multinode.yml` runs on the nodes that passed the **newest** smoke run, so smoke a subset
first:

```bash
ansible-playbook ansible/00-prep.yml  -l <node>,<node>   # IMEX domain of only these nodes
ansible-playbook ansible/10-smoke.yml -l <node>,<node>
ansible-playbook ansible/30-multinode.yml
```

Run `00-prep.yml` without `-l` to put every node back into one IMEX domain.

### Running by hand

From any GB200 node after `00-prep.yml`:

```bash
cd ~/validation/nccl
./run_nccl_gb200.sh -c all_reduce -n 4         # first 4 hosts of ~/hostfile
./run_nccl_gb200.sh -c all_gather -H <ip1>,<ip2>
./run_nccl_gb200.sh --help
```

## Bring your own VMs

Skip Terraform and create `inventory/hosts.ini`, `inventory/hostfile` (`<private-ip> slots=4`),
`inventory/imex_nodes` (one GB200 private IP per line) and `keys/cluster_ssh_key`
(`ssh-keygen -t ed25519 -N '' -f keys/cluster_ssh_key`):

```ini
[gb200]
node-01 ansible_host=<public-ip> private_ip=<private-ip> vm_id=<vm-id>

[cpu]

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=/path/to/private/key
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

All GB200 VMs must be in the same NVLink domain.

## How the NVLink path is verified

- `00-prep.yml` writes every GB200 private IP into `/etc/nvidia-imex/nodes_config.cfg`, makes
  IMEX channel0 persistent, restarts `nvidia-imex` and waits until every pair is Connected.
- The NCCL runner sets `NCCL_MNNVL_ENABLE=1` (fail rather than fall back to IB),
  `NCCL_NVLS_ENABLE=1` and `NCCL_CUMEM_ENABLE=1`, and fails a multi-node run unless every rank
  logs `MNNVL 1 cliqueId <x> cliqueSize <ranks>`.
- MPI is only a TCP bootstrap over the VPC subnet; ranks run with an 8 MiB stack (an unlimited
  stack crashes NCCL init).

## Gotchas

- **Run on idle GPUs.** If a workload holds GPU memory, NCCL fails at init with
  `Cuda failure 2 'out of memory'`; the preflight refuses such nodes ("GPUs in use on: …").
- **`00-prep.yml` restarts IMEX** on nodes whose peer list changes (e.g. after adding or
  recreating a VM), which breaks multi-node NVLink jobs already running. Re-run it after any
  change to the node set, and only when the nodes are idle.
- **Placement errors.** Pinning to a domain without enough free nodes fails with a generic
  "internal error"; check the domain's `available_nodes`.
- **`dcgmi health` reports "IMEX -3 not READY"** on healthy nodes; ignore it. `dcgmi diag`'s
  `software` test is skipped (Fabric Manager false positive on VMs).
- **`Failed to update instance network interface: 400 Bad Request`** on apply: a VM's public IP
  was made static outside Terraform; add its name to `static_public_ip_nodes`.
- **Changing `ssh_public_key_path` recreates the VMs.** Image and `nvlink_domain_id` changes are
  ignored after creation.
- **Ansible "process object is closed"**: raise `ulimit -n` or use `-f 10`.

## Interpreting failures

| Symptom | Likely cause | Next step |
|---|---|---|
| IMEX pairs never Connected / `imex_domain` FAIL | a node missing from the peer list (was down or recreated during prep) | re-run `00-prep.yml` once every node is up |
| `nvlink_fabric` FAIL or clique mismatch | node outside the rack, or fabric not initialised | recreate the VM in the rack's `nvlink_domain_id`; contact Crusoe support with the VM ID if it persists |
| multi-node "MNNVL not in use", or `status=12` errors | IMEX down or channel0 missing on some node, so traffic went to IB | `nvidia-imex-ctl -N`; re-run `00-prep.yml` |
| `Cuda failure 800 'operation not permitted'` | IMEX channel0 missing or not accessible | re-run `00-prep.yml` |
| GEMM spread > 10% on one node | throttling or a degraded GPU | `-l <node> -e steps=gemm -e dcgm_diag=true`; contact support if it repeats |
| `nvme_state` or `scratch_local` FAIL | local NVMe drives dropped off the bus; `/scratch/local` data is lost | recreate the VM; contact Crusoe support with the VM ID |
| `/scratch/local` not mounted after boot | the drives hold data that is not this array | `journalctl -b -u scratch-raid`; re-run `20-nvme-raid.yml -l <node> -e nvme_raid_wipe=true` |
| busbw below gate with MNNVL on | NVLS off, a slow node, or another job on the GPUs | check for `NVLS multicast support is available` in the log; `-e scale_sizes=auto` to find the slow set |
