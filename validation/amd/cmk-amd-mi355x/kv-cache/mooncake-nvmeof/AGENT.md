# Running this with a coding agent

Paste the prompt below into Claude Code or a similar agent, from the root of
this repository.

It does not restate the procedure. [README.md](./README.md) is the procedure,
and the agent reads it. What this adds are the guardrails: the handful of
things that are easy to get wrong here and expensive when you do.

---

## Before you start

> **This is not a dry run.** The agent will bind your NVMe drives to a
> userspace driver, enable `vfio` no-IOMMU mode (which taints the host
> kernel), and run privileged pods with `hostNetwork` and `hostPID`. The node
> is only restored by the cleanup step.
>
> Run it on a cluster you own and can afford to disrupt. Not on anything
> serving traffic, and not on a cluster shared with people who do not know
> this is happening.
>
> One drive on each node holds the OS. Binding it takes the node down. The
> procedure detects and skips it, but you should know the failure mode exists.

Budget roughly 90 minutes: ~20 for the image build, the rest for the run.

---

## The prompt

```
Validate the Mooncake NVMe-oF KV cache tier on this MI355X cluster.

PROCEDURE
  validation/amd/cmk-amd-mi355x/kv-cache/mooncake-nvmeof/README.md
Read it fully before running anything, then follow it. BUILD.md covers the
image build and registry setup. I am not restating the steps here; the README
is the source of truth.

HARD RULES — these are the things that go wrong

1. CLEANUP IS NOT OPTIONAL. README step 8 restores the node. If you run out
   of context or time, stop early and clean up rather than finishing the
   measurements. A node left with drives bound to vfio-pci and no-IOMMU mode
   enabled is worse than an incomplete test.

2. RUN CLEANUP IN THE FOREGROUND. Previous runs had background cleanup
   commands killed partway, leaving drives half-released while the agent
   reported success. Cleanup commands are short. Do not background them.

3. VERIFY CLEANUP, do not assume it. Report the actual output of:
       cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode   want 0
       ls /dev/vfio/                                                want empty
       ls /sys/bus/pci/drivers/vfio-pci/0*                          want none
       nvme list                                                    want 8
   If drives will not rebind to the kernel nvme driver, the device's
   driver_override is still set to vfio-pci. Clear it and re-probe:
       echo        > /sys/bus/pci/devices/$BDF/driver_override
       echo "$BDF" > /sys/bus/pci/drivers_probe

4. NEVER BIND THE OS DRIVE. Identify free drives by enumerating and checking
   for mountpoints, as the README describes. The BDF and the mount point both
   vary between nodes. Do not copy a drive list from any other source.

5. USE spdk_nvme_perf, NOT fio. fio does not drive the SPDK path and queue
   depth will not scale. A previous run recorded 87,752 IOPS at QD1 against
   89,973 at QD32 before this was noticed.

6. DISJOINT CORE MASKS. The target and the benchmark must not share cores.
   Overlapping masks produce latency that reads as a fabric problem and is
   not.

7. --no-huge IS NOT A WORKAROUND for hugepage failures. No-IOMMU forces
   IOVA=PA, which requires hugepages. nvmf_tgt will start and then real
   devices will refuse to attach.

8. ReplicateConfig.nof_replica_num = 1 for the put/get test. The default is 0,
   which stores to DRAM only. A put without it returns success and never
   touches NVMe.

9. NEVER INVENT ADDRESSES. Read every IP, GID and BDF from the cluster.

WHEN SOMETHING BREAKS

The documentation may be wrong. If it is, that is a finding, not an obstacle.

  Cannot proceed at all  -> STOP. Report the exact command, the exact output,
                            and what you think needs to change in which file.
                            Do not improvise around it.
  Can continue with a
  documented workaround  -> Record it verbatim, apply the smallest workaround,
                            flag every later step as "ran with workaround N",
                            continue.

Do not edit, commit or push anything in this repository. `git status --short`
must be empty when you finish.

REPORT

  - pass or fail per README step, with the measured numbers
  - cross-node throughput, and whether it cleared 27 GB/s
  - the put/get checksum comparison
  - cleanup verification output, verbatim
  - any documentation defects, in the format above
  - confirmation that `git status --short` is empty

Expected on healthy MI355X hardware, for comparison:
  registration     ~24.45 TB across 7 namespaces, adrfam:IPv6
  throughput       42 GB/s at 128KB QD32, against a 27 GB/s bar
  fabric ceiling   47.6 GB/s, 10.34 us (ib_write_bw, 8 queue pairs)
```

---

## If the run goes wrong

The one state worth catching early is drives left bound after a failed or
interrupted run. From a node shell:

```bash
kubectl debug node/<node> -it --image=busybox:1.36 -- chroot /host sh -c '
  cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  ls /dev/vfio/ 2>&1
  for d in /sys/bus/pci/drivers/vfio-pci/0*; do [ -e "$d" ] && basename "$d"; done
  ls /dev/nvme?n1 2>/dev/null | wc -l
'
```

`0`, no vfio nodes, nothing on vfio-pci and 8 NVMe devices means the node is
clean. Anything else needs the `driver_override` remedy in rule 3.

## Why a prompt rather than a script

The procedure has decision points a script cannot make: which drives are free
on this particular node, whether a hugepage failure is the cgroup hierarchy or
something else, whether a throughput number is real or a measurement artifact.
Those are judgement calls, and an agent reading the README makes them with
context a script would need hardcoded assumptions to fake.

The rules above exist because each one was learned by getting it wrong.
