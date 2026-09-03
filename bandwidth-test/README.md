# Bandwidth Test

Point-to-point and many-to-many throughput measurement with iperf3, driven by
Ansible. Generates traffic from one-or-many source hosts to one-or-many
destination hosts and **collects the results from the servers**.

Use it to measure a VPN tunnel, a peering link, a managed cloud gateway
(Azure ↔ GCP), or just two VMs in the same subnet for a baseline. It does not
care what is in the middle.

## Why server-side collection

The receiving end is the authoritative measurement — it counts what actually
arrived. It is also the only end that still reports usefully when the path in
between is an appliance you do not control: a managed VPN gateway, a customer
firewall, a carrier link. If the path degrades badly enough, a client's own
summary can be truncated or lost; the server's file is already on disk.

Every flow gets its own port and its own one-shot server (`iperf3 -s -1`), so
each result is a clean, complete JSON object rather than an appended stream.

## Quick start

```bash
cd ansible
vim inventory.ini          # source_hosts and dest_hosts, with bw_private_ip
ansible-playbook -i inventory.ini site.yml
```

Output:

```
======================================================================
BANDWIDTH TEST - 20 flow(s) measured at the receiver
======================================================================
  flow                                Gbps   secs   retrans
  000-src-1-to-dst-1                  2.11   30.0       412
  001-src-2-to-dst-2                  2.08   30.0       380
  ...
----------------------------------------------------------------------
  TOTAL                              42.41 Gbps across 20 flow(s)
  mean per flow                       2.12 Gbps
  total retransmits                 26,417,060
```

## Topologies

| `bw_mode` | Meaning |
|---|---|
| `paired` (default) | `source[i]` → `dest[i]`. Groups must be the same size. |
| `many_to_one` | every source → `dest[0]`. Load-tests one receiver. |
| `mesh` | every source → every destination. Flows = sources × destinations. |

```bash
ansible-playbook -i inventory.ini site.yml -e bw_mode=many_to_one
```

## Common runs

```bash
# baseline: straight over the public IPs, bypassing whatever you are testing
ansible-playbook -i inventory.ini site.yml -e bw_dest_address=public

# UDP, to separate packet loss from TCP's reaction to it
ansible-playbook -i inventory.ini site.yml -e bw_protocol=udp -e bw_udp_bitrate=2G

# the other direction
ansible-playbook -i inventory.ini site.yml -e bw_reverse=true

# longer, more streams
ansible-playbook -i inventory.ini site.yml -e bw_duration=120 -e bw_streams=16
```

## Reading the results

- **Run a baseline first** (`bw_dest_address=public`). Without it you cannot
  tell "the tunnel is slow" from "the path is slow" or "the hosts are small".
- **Never judge on a single stream.** One TCP flow pins to one path and one
  CPU core by design. Use `bw_streams` ≥ 8, or several flows.
- **Watch retransmits, not just Gbps.** A large retransmit count means the
  path is being driven past its knee. Throughput can look good while the link
  is thrashing.
- **If TCP is slow but UDP is clean**, you are looking at MTU, MSS, or an
  offload problem, not capacity. Re-run with `bw_protocol=udp` at a few packet
  sizes to confirm.
- **Compare like with like.** Stream count and duration both change the
  number; keep them fixed across the runs you intend to compare.

## Requirements

- SSH access to every host, with `become` for the package install
- `iperf3` (installed automatically unless `bw_install: false`)
- The chosen port range open between sources and destinations:
  `bw_port_base` .. `bw_port_base + flows - 1` (default 5201+)
- Python 3 on the controller for the summary

## Tunables

Everything lives in `ansible/roles/bandwidth_test/defaults/main.yml`:

| Variable | Default | Purpose |
|---|---|---|
| `bw_mode` | `paired` | `paired`, `many_to_one`, `mesh` |
| `bw_dest_address` | `private` | `private` through the path, `public` for a baseline |
| `bw_duration` | `30` | seconds per flow |
| `bw_streams` | `8` | parallel TCP streams per flow |
| `bw_omit` | `5` | seconds of slow start discarded |
| `bw_protocol` | `tcp` | `tcp` or `udp` |
| `bw_udp_bitrate` | `1G` | per flow, UDP only |
| `bw_reverse` | `false` | measure destination → source |
| `bw_port_base` | `5201` | first port; one per flow |
| `bw_results_dir` | `results` | where fetched JSON lands |
| `bw_install` | `true` | install iperf3 if missing |

## Limitations

- One flow per source/destination pair per run. For more concurrency per pair,
  raise `bw_streams` or use `mesh`.
- No traffic shaping or scheduling — every flow starts at once.
- Results are raw iperf3 JSON. The aggregator summarises; it does not chart.
- IPv4 only, as written.
