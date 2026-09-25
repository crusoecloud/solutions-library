# ib-write-test-multinode

Tests InfiniBand NIC bandwidth across multiple nodes using `ib_write_bw`, then summarizes which NICs passed or failed.

## Prerequisites

- `ib_write_bw` must be installed on all nodes.
- The first node in the cluster (where the scripts run) must be **known good** — all of its NICs (`ionic_0` through `ionic_7`) should have already passed this test or a multinode RCCL test.
- Passwordless SSH must be configured from the first node to all other nodes listed in the `nodes` file.

## Setup

1. Copy the script to the first node in the cluster:

   ```bash
   scp ib-write-test.sh <first-node-ip>:~/
   ```

2. On the first node, create a `nodes` file based on `nodes-example`:

   ```bash
   cp nodes-example nodes
   # Edit nodes with your actual IP addresses
   ```

   The format is one IP address per line. The **first IP address must be the IP address of the first node** (the one you are running the script on). The remaining lines are the nodes to be tested:

   ```
   172.27.0.100
   172.27.0.101
   172.27.0.102
   172.27.0.103
   ```

3. Ensure the script is executable:

   ```bash
   chmod +x ib-write-test.sh
   ```

## Running the test

From the first node, run:

```bash
./ib-write-test.sh
```

This will test all 8 InfiniBand NICs (`ionic_0` through `ionic_7`) on each non-first node by running `ib_write_bw` between the first node and each target node.

When all tests are complete, a summary is printed to the terminal and saved to `ib-write-test-summary.txt`. The full raw output is saved to `ib-write-test-results.log`.

The summary lists any NICs that did not achieve the 320 Gb/sec threshold, for example:

```
========================================================
  IB Write BW Test Summary
  Threshold : 320 Gb/sec
  Generated : Fri Sep 25 16:30:00 2026
========================================================

  STATUS: FAILURES DETECTED

  NICs below 320 Gb/sec:
  --------------------------------------------------------
  172.27.0.101         ionic_3     298.44 Gb/sec

  Total: 23 passed, 1 failed, 0 errors
========================================================
```
