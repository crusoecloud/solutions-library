# Running this with a coding agent

Paste one of the prompts below into Claude Code or a similar agent, from the
root of this repository.

These do not restate the procedure. [README.md](./README.md) is the
procedure, and the agent reads it. What they add are the guardrails: the
handful of things that are easy to get wrong here and expensive when you do.

Three tests, three prompts. Run them in order the first time — test 1 proves
binding works at all, and there is no point debugging test 3 if it does not.

---

## Before you start

> **This is not a dry run.** The agent will bind your NVMe drives to a
> userspace driver, enable `vfio` no-IOMMU mode (which taints the host
> kernel), and run privileged pods with `hostNetwork` and `hostPID`. The node
> is only restored by the cleanup step.
>
> Run it on a cluster you own and can afford to disrupt.
>
> One drive on each node holds the OS. SPDK's `setup.sh` detects active
> mounts and refuses to bind those devices, which is the main protection, but
> you should know the failure mode exists: binding the OS drive takes the node
> down.

Timings: test 1 ~2 min, test 2 ~12 min, test 3 ~30 min.

---

## Test 1 — device binding

```
Run test 1 (device binding) from:
  validation/amd/cmk-amd-mi355x/kv-cache/nvme-spdk-binding-test/README.md

Read the README first, then follow it. Script is src/run-spdk-binding-test.sh,
pod is src/spdk-test-pod.yaml (edit nodeName).

HARD RULES

1. LET SPDK PROTECT THE MOUNTED DRIVES. setup.sh skips devices with active
   mounts and prints "Active devices: ... so not binding PCI dev". That is
   correct behaviour. NEVER override it, and never add a drive to PCI_ALLOWED
   that setup.sh skipped.

2. WHICH DRIVE HOLDS THE OS VARIES BY NODE. Do not copy a device list from
   the README, from RESULTS.md, or from any other node's output.

3. CLEANUP IS NOT OPTIONAL and must run in the FOREGROUND. Cleanup commands
   are short. Backgrounding them has previously resulted in them being killed
   partway, leaving drives half-released.

4. VERIFY, do not assume. Report the real output of:
       ls /dev/nvme?n1 | wc -l                                      want 8
       ls /sys/bus/pci/drivers/vfio-pci/0*                          want none
       cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode   want 0

   If a drive will not return to the nvme driver, its driver_override is
   still vfio-pci. Clear it and re-probe:
       echo        > /sys/bus/pci/devices/$BDF/driver_override
       echo "$BDF" > /sys/bus/pci/drivers_probe

Do not edit, commit or push anything. `git status --short` must be empty.

REPORT: bind result, reset result, cleanup verification verbatim, and any
place the README was wrong or insufficient.
```

---

## Test 2 — NVMe-oF over RDMA, single node

```
Run test 2 (NVMe-oF over RDMA) from:
  validation/amd/cmk-amd-mi355x/kv-cache/nvme-spdk-binding-test/README.md

Read the README first. Script is src/run-spdk-nvmeof-rdma-test.sh, pod is
src/spdk-nvmeof-pod.yaml (edit nodeName).

HARD RULES

1. All four rules from test 1 still apply: respect setup.sh's mount
   detection, do not reuse device lists, foreground cleanup, verify it.

2. BOTH HUGEPAGE CGROUP LIMITS, AT EVERY LEVEL. cgroup v2 needs
   hugetlb.2MB.max AND hugetlb.2MB.rsvd.max, and the effective limit is the
   MINIMUM along the path from root to leaf. Setting only the container's own
   cgroup is the common failure: the pod-level cgroup usually holds 0.

3. --no-huge IS NOT A WORKAROUND. No-IOMMU forces IOVA=PA, which requires
   hugepages. nvmf_tgt starts and then devices refuse to attach, which looks
   like progress and is not.

4. /dev/vfio/<group> IS NOT AUTO-CREATED in no-IOMMU mode. Without the mknod,
   DPDK reports "Cannot find device" for a drive that is correctly bound.

5. NO IONIC DEVICES means the userspace RDMA provider is missing. It is not
   in stock images. Report it rather than working around it.

6. NEVER INVENT ADDRESSES. Read GIDs and IPs from the cluster.

Do not edit, commit or push anything. `git status --short` must be empty.

REPORT: pass or fail per step, cleanup verification verbatim, and any place
the README was wrong or insufficient.
```

---

## Test 3 — two-node performance

```
Run test 3 (two-node performance) from:
  validation/amd/cmk-amd-mi355x/kv-cache/nvme-spdk-binding-test/README.md

Read the README first. Script is
src/run-nvmeof-performance-validation.sh <kubeconfig> <target> <initiator>.

HARD RULES

1. All rules from tests 1 and 2 apply, on BOTH nodes.

2. CLEAN UP BOTH NODES. It is easy to clean the target and forget the
   initiator. Verify each separately.

3. DISJOINT CORE MASKS. Target and benchmark must not share cores.
   Overlapping masks produce latency that reads as a fabric problem and is
   not. A previous run measured 9ms this way.

4. MEASURE THE FABRIC WITH 8 QUEUE PAIRS, not 1. A single QP understates this
   fabric by roughly 2.8x: 136 Gb/s at 1 QP against 380.72 Gb/s at 8. Any
   efficiency percentage computed against a single-QP ceiling is wrong.

5. SAME RAIL INDEX ON BOTH ENDS. The fabric is rail-isolated: ionic_0 on one
   node reaches ionic_0 on the other and nothing else.

6. GID INDEX 1. Index 0 is link-local. Index 2 holds an IPv4-mapped address
   on SOME nodes and nothing on others, so it cannot be relied on. Index 1 is
   the routable global IPv6 and was present on every node observed.

7. NEVER INVENT ADDRESSES.

Do not edit, commit or push anything. `git status --short` must be empty.

REPORT: the PCIe baseline and RDMA results side by side, QD scaling, latency
delta at 4K QD1, cleanup verification for BOTH nodes verbatim, and any place
the README was wrong or insufficient.

Expected on healthy hardware, for comparison:
  fabric          380.72 Gb/s, 10.34 us    (ib_write_bw, 8 QPs)
  PCIe 128K QD32  ~6,672 MiB/s
  RDMA 128K QD32  ~6,668 MiB/s             within 0.1% of local
  added latency   ~26 us at 4K QD1
```

---

## When something breaks

The documentation may be wrong. If it is, that is a finding, not an obstacle.

| | |
|---|---|
| Cannot proceed at all | **Stop.** Report the exact command, exact output, and what needs to change in which file. Do not improvise around it. |
| Can continue with a workaround | Record it verbatim, apply the smallest one, flag later steps as "ran with workaround N", continue. |

A workaround applied but not reported is the worst outcome: it produces a
green result and leaves the repo broken for the next reader.

## If a run is interrupted

Check whether drives were left bound:

```bash
kubectl debug node/<node> -it --image=busybox:1.36 -- chroot /host sh -c '
  cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  ls /dev/vfio/ 2>&1
  for d in /sys/bus/pci/drivers/vfio-pci/0*; do [ -e "$d" ] && basename "$d"; done
  ls /dev/nvme?n1 2>/dev/null | wc -l
'
```

`0`, no vfio nodes, nothing on vfio-pci and 8 NVMe devices means clean.
Anything else needs the `driver_override` remedy above.

## Why prompts rather than more scripting

The scripts already automate the mechanical parts. What they cannot do is
decide which drives are free on this particular node, tell a cgroup hugepage
failure from a genuine one, or recognise that a throughput number is a
measurement artifact. Those are judgement calls.

The rules above exist because each one was learned by getting it wrong.
