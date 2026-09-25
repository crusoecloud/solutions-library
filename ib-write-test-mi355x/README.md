# ib-write-test-multinode

Tests InfiniBand NIC bandwidth across multiple AMD MI355X nodes using `ib_write_bw`, then summarizes which NICs passed or failed.

## Prerequisites

- `ib_write_bw` must be installed on all nodes.
- The master node (on which the script is run) must be **known good** — all of its NICs (`ionic_0` through `ionic_7`) should have already passed this test or a multinode RCCL test.
- Passwordless SSH must be configured from the master node to all other nodes listed in the `nodes` file.

## Setup

1. Copy the script to the chosen master node:

   ```bash
   scp ib-write-test.sh <first-node-ip>:~/
   ```

2. On the master node, create a `nodes` file based on `nodes-example`:

   ```bash
   cp nodes-example nodes
   # Edit nodes with your actual IP addresses
   ```

   The format is one IP address per line. It's ok to include the master node's address in this list (the script will ignore it as needed).

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

From the master node, run:

```bash
./ib-write-test.sh
```

This will test all 8 InfiniBand NICs (`ionic_0` through `ionic_7`) on each node by running `ib_write_bw` between the master node (acting as the ib_write client) and each target node (acting as an ib_write server).

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
