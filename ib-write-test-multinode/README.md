# ib-write-test-multinode

Tests InfiniBand NIC bandwidth across multiple nodes using `ib_write_bw`, then summarizes which NICs passed or failed.

## Prerequisites

- `ib_write_bw` must be installed on all nodes.
- The first node in the cluster (where the scripts run) must be **known good** — all of its NICs (`ionic_0` through `ionic_7`) should have already passed this test or a multinode RCCL test.
- Passwordless SSH must be configured from the first node to all other nodes listed in the `nodes` file.

## Setup

1. Copy the scripts to the first node in the cluster:

   ```bash
   scp ib-write-test.sh summarize-rail-test.sh <first-node-ip>:~/
   ```

2. On the first node, create a `nodes` file based on `nodes-example`:

   ```bash
   cp nodes-example nodes
   # Edit nodes with your actual IP addresses
   ```

   The format is one IP address per line. The **first IP address must be the IP address of the first node** (the one you are running the scripts on). The remaining lines are the nodes to be tested:

   ```
   172.27.0.100
   172.27.0.101
   172.27.0.102
   172.27.0.103
   ```

3. Ensure the scripts are executable:

   ```bash
   chmod +x ib-write-test.sh summarize-rail-test.sh
   ```

## Running the test

From the first node, run:

```bash
./ib-write-test.sh
```

This will test all 8 InfiniBand NICs (`ionic_0` through `ionic_7`) on each non-first node by running `ib_write_bw` between the first node and each target node. Results are saved to `ib-write-test-results.log` in the current directory.

## Summarizing results

Once the test completes, run:

```bash
./summarize-rail-test.sh
```

Or pass a specific log file:

```bash
./summarize-rail-test.sh ib-write-test-results.log
```

This prints a table showing each NIC on each node, its peak bandwidth (Gb/s), and its status:

| Status | Meaning |
|--------|---------|
| `OK` | Bandwidth met or exceeded the 320 Gb/s threshold |
| `LOW` | Bandwidth was below the 320 Gb/s threshold |
| `FAILED` | Test did not produce a result (connection or device error) |

NICs with `LOW` or `FAILED` status are flagged for investigation. A summary count is printed at the end.
