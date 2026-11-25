# Provision GPU VMs and run validation tests

Creates NVIDIA InfiniBand GPU VMs of the chosen SKU with Terraform and prepares them with Ansible (packages, hostname, cluster SSH, hostfile, IMEX, optional RAID0) as part of `terraform apply`. The validation tests (node health, DCGM diagnostics, single-node and multi-node NCCL, InfiniBand write bandwidth) are separate Ansible playbooks that can be run independently.

**Contents:**
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Local NVMe RAID0](#local-nvme-raid0)
- [Quick start](#quick-start)
- [Tests](#tests)
- [Bring your own VMs](#bring-your-own-vms)
- [Cleanup](#cleanup)

## Prerequisites
- `terraform` — `brew install hashicorp/tap/terraform`
- `ansible` (provides `ansible-playbook`) — `brew install ansible` or `pipx install --include-deps ansible`. No extra collections are needed.
- `crusoe` CLI — `brew install crusoecloud/cli/crusoe` ([Linux](https://docs.crusoe.ai/installing-the-cli))

Set up credentials (Terraform uses the same `~/.crusoe/config`):
```
crusoe config init
crusoe whoami
```

## Configuration
```
cp terraform.tfvars.example terraform.tfvars
```

| Key | Command |
|---|---|
| `project_id` | `crusoe projects list` |
| `location` | `crusoe locations list` |
| `vpc_subnet_id` | `crusoe networking vpc-subnets list` (same location) |
| `transport_partition_id` | see below (same location) |

Transport partition (required for `-ib` SKUs):
```
crusoe networking transport-networks list
crusoe networking transport-partitions list                      # reuse an existing one, or:
crusoe networking transport-partitions create --name <name> --transport-network-id <transport_network_id>
```

Uncomment one SKU block (`image_name`, `node_type`) and set `node_count` and a unique `node_name_prefix`. A filled-in example is in `examples/b300.tfvars.example`.
To check images: `crusoe compute images list | grep nvidia-b.<gpu>`

NCCL settings (`NCCL_IB_HCA`, `UCX_NET_DEVICES`, `NCCL_TOPO_FILE`), hostfile slots and IMEX (on for `gb*` SKUs) are derived from the instance type in `ansible/inventory/group_vars/all.yml`. To add a SKU, add a tfvars block; change `group_vars/all.yml` only if it needs different NCCL settings.

Supported: NVIDIA InfiniBand SKUs (`-ib` instance types). RoCE or PCIe SKUs (for example L40S, A100 PCIe) are not supported. GB200 has not been validated here, and its IMEX and NCCL settings may need adjustment.

## Local NVMe RAID0
By default, the local NVMe disks are left untouched. To combine them into a RAID0 array (XFS) mounted at `/raid0`, as in the [Crusoe ephemeral disk docs](https://docs.crusoe.ai/storage/disks/managing-ephemeral-disks/index.html), uncomment this line in `terraform.tfvars`:
```
raid0_enabled = true
```
The array has no redundancy, and its data is lost on VM stop/start. Use it only for scratch data.

Later applies with `true` keep the array. After the array is built, an apply with `raid0_enabled = false` (or with the line commented out again) fails before it changes anything, and the array stays as it is. To remove the array, recreate the VMs.

## Quick start
Run all commands from this folder.
```
terraform init
terraform apply
ansible-playbook ansible/node-health.yml ansible/dcgm-diag.yml ansible/nccl-single-node.yml \
                 ansible/nccl-allreduce.yml ansible/ib-write.yml
```
`terraform apply` only creates and prepares the VMs and prints `nodes_addr`. Run all test playbooks, or one at a time, as often as necessary. In one command, a node that fails a per-node test is left out of the later per-node tests, but the multi-node tests still use every node in the hostfile, and if the first node failed they do not run. To test every node in every playbook, run them one at a time.

## Tests
Run the tests only on idle VMs: they use all GPUs and HCAs, and `dcgm-diag` runs GPU stress tests.

| Playbook | Runs on | What it does | Fails if |
|---|---|---|---|
| `node-health.yml` | every node, in parallel | GPU count, Xid in `dmesg`, uncorrected ECC, row remap, GPU PCIe width, IB HCAs ACTIVE at top rate, fabric manager, IMEX (`gb*`). Prints driver, CUDA and NCCL versions | a `FAIL` row |
| `dcgm-diag.yml` | every node, in parallel | `dcgmi diag -r 2`: software, memory, PCIe (about 6 min on 8× B300). Uses the image's DCGM and starts `nvidia-dcgm` if it is stopped | non-zero exit or a `Fail` |
| `nccl-single-node.yml` | every node, in parallel | `all_reduce_perf` 8G–32G over all GPUs of each node alone (NVLink); reports busbw per node | a node gives no result |
| `nccl-allreduce.yml` | first node, all GPUs of all nodes | prints NVRM kernel messages per host (information only), then `all_reduce_perf` 8G–32G over InfiniBand; reports avg busbw. Skipped (not failed) with fewer than 2 nodes | the test gives no result |
| `ib-write.yml` | each node to the next node (ring), one client at a time | `ib_write_bw`, same HCA on both ends, one HCA at a time, 4 QPs, 10 s; reports Gb/s per pair and min / median / max. Skipped (not failed) with fewer than 2 nodes. Uses host memory, so the result can be below the HCA link speed (on B300, about 474 Gb/s). For fabric speed, use `nccl-allreduce` | a pair gives no result |

Options:

| Command | Effect |
|---|---|
| `ansible-playbook ansible/dcgm-diag.yml -e dcgm_level=3` | adds diagnostic, targeted stress, targeted power and memory bandwidth tests (NVIDIA: about 15–30 min) |
| `ansible-playbook ansible/nccl-allreduce.yml -e collective=all_gather` | other collective: `all_gather`, `reduce_scatter`, `alltoall`, ... (also for `nccl-single-node.yml`) |
| `ansible-playbook ansible/ib-write.yml -e ib_topology=mesh` | every node to every other node; time grows with the node count squared (4 nodes: 96 HCA pairs, about 12 s each) |
| `ansible-playbook ansible/ib-write.yml -e ib_topology=star` | only the first node to every other node (the shortest run) |
| `ansible-playbook ansible/node-health.yml -l <node>` | test only some nodes (per-node playbooks) |

Each run writes a new log with the same name in two places: `/home/ubuntu/fabric-validation/<test>-<timestamp>.txt` on the node (`ib-write` uses the `ib-write/` subfolder), and `results/` here (a folder with one file per node for the per-node tests). No run overwrites an earlier one. The scripts and the MPI hostfile are in the same folder on the node.

Each node also has `/home/ubuntu/fabric-validation/consolidated_output.txt`: one row per test with its latest result, value, node count, time and log file. A test that runs again replaces its row. Multi-node tests write their row on every node.
```
TEST                         RESULT  VALUE                                                          NODES  LAST RUN             LOG
node-health                  PASS    0 failed, 0 warnings                                           this   2026-11-20 11:00:00  node-health-20261120-110000.txt
nccl all_gather              OK      733.861 GB/s                                                   2      2026-11-20 10:27:50  nccl-all_gather-20261120-102750.txt
```

## Bring your own VMs
To test VMs that were not created by this Terraform, skip `terraform apply`. No Terraform state is needed.

Requirements: all VMs are the same instance type, use a Crusoe NVIDIA image (HPC-X, `/opt/nccl-tests`, `/etc/crusoe/nccl_topo`) with user `ubuntu`, are in the same transport partition, and can reach each other on their private IPs.

```
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml   # set IPs, instance_type, SSH key
ansible-playbook ansible/test-prep.yml                               # one time
ansible-playbook ansible/node-health.yml                             # then any test from the table above
```
`test-prep.yml` creates `./cluster_ssh_key` (if it does not exist), installs it on the nodes as `~/.ssh/fabric_validation_key` for node-to-node SSH between the cluster's private IPs only (existing keys such as `~/.ssh/id_rsa`, and SSH settings for other hosts, are not changed), and writes `/home/ubuntu/fabric-validation/hostfile` in inventory order. It does not build RAID0, install packages or change the hostname. IMEX setup for `gb*` VMs is not included; `node-health.yml` only checks that `nvidia-imex` is active.

`terraform apply` in this folder overwrites `ansible/inventory/hosts.yml`.

After testing, the cluster key stays on the VMs. Everything `test-prep.yml` adds is marked `vm-fabric-validation`. To remove it, run this on each node:
```
rm ~/.ssh/fabric_validation_key
sed -i '/ vm-fabric-validation$/d' ~/.ssh/authorized_keys
sed -i '/^# BEGIN vm-fabric-validation$/,/^# END vm-fabric-validation$/d' ~/.ssh/config
```
The test logs are in `~/fabric-validation/` on each node. The same key is also in this folder on your workstation as `./cluster_ssh_key`.

## Cleanup
VMs keep running. If you do not need them: `terraform destroy`
