# StrongSwan Site-to-Site VPN for Crusoe Cloud

Encrypted IPsec VPN between a Crusoe Cloud region and a remote site — a
customer datacenter, another Crusoe region, or Azure, GCP or AWS. Configures
standalone VMs with Ansible and managed Kubernetes nodes with a DaemonSet.

**Capabilities**

- Subnet-to-subnet routing over encrypted IPsec, plus full-tunnel mode
- Managed K8s support — the DaemonSet configures nodes, no SSH needed
- **Selectable client transport** — GRE-over-FOU overlay (default) or plain
  static routes
- **Named crypto profiles**, including `gcmaes256`
- **Multiple tunnels per gateway** with ECMP, for peers that publish more than
  one outer address — most managed cloud VPNs do in their redundant mode
- **Multiple gateway VMs** with client-side ECMP, for throughput beyond one
  tunnel. BGP (FRR) is included, and managed cloud VPNs generally require it
  before they will spread return traffic across several on-premises devices;
  between two sites you control, static routes are enough.

**The defaults target a managed cloud VPN peer** (Azure, GCP, AWS) **and have
changed** from earlier
versions of this solution: GCMAES256 for IKE and ESP, one tunnel per peer
address, a stateless datapath (conntrack off, no SNAT), host tuning on, and a
VAES-capable kernel installed — and, on a host with no VPN yet, booted —
automatically. To pin the old behaviour set `vpn_crypto_profile: default`,
`vpn_tunnel_count: 1`, `vpn_disable_conntrack: false`,
`vpn_stateful_forward_rule: true`, `vpn_perf_tuning: false` and
`vpn_kernel_upgrade: false`.

To measure any of this, use the separate
[bandwidth-test](../bandwidth-test/) solution. It drives iperf3 across
one-or-many hosts and collects results from the receivers, so it works through
a managed gateway on either end.

## Measured throughput

Iceland ⇄ Norway across the public internet (54 ms RTT), 20 client pairs,
GRE-over-FOU, `gcmaes256`, dedicated 8 vCPU gateway VMs:

| gateways/site | tunnels/gateway | kernel 6.8 | **kernel 6.11** | change | per gateway |
|---|---|---|---|---|---|
| 1 | 1 | 2.05 | **2.37** | +15.5% | 2.37 |
| 2 | 1 | 4.38 | **5.60** | +27.8% | 2.80 |
| 3 | 1 | 7.38 | **9.42** | +27.7% | 3.14 |
| 4 | 1 | 10.78 | **16.16** | +49.9% | 4.04 |
| 5 | 1 | 14.79 | **20.66** | +39.7% | 4.13 |
| 5 | 5 (full mesh) | 42.4 | not re-run | — | 8.5 |

Both columns were deployed and measured with the shipped playbook. Kernel 6.11
is worth +15% to +50% for a package install — see below.

Measured separately, in the shape a managed cloud peer presents: **one 8 vCPU
gateway VM holding two tunnels to two distinct peer public IPs carried
8.46 Gbps** of client traffic, with both tunnels active (ECMP split them
41% / 59% across 24 flows).

Note that a managed cloud VPN will usually cap a tunnel well below what this
side can drive, so the peer — not Crusoe — sets your VM count. Work that out
from your provider's published per-tunnel figure; the arithmetic for Azure is
in [AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md).

**Four gateways per side clears 10 Gbps**; three gives 9.42, just short.

Throughput scales with the **number of tunnels**, because each tunnel's
inbound decrypt runs on its own single CPU core. Per-gateway throughput also
*rises* with gateway count (2.37 → 4.13): with one gateway per side the same
box receives every client's FOU flow and terminates the tunnel, so both
directions contend on one machine. Nothing reached a link ceiling — 42.4 Gbps
on the mesh was still CPU-bound.

Failover: killing one of five gateways mid-transfer degraded throughput to
**84%** (strongSwan stopped) and **79%** (all forwarding dropped) of before —
both matching the expected 4/5 — and recovered on restore. Proportional
degradation, not a blackhole.

### Per-tunnel throughput, and the kernel

Measured separately, gateway to gateway (pure IPsec, no GRE leg), one tunnel,
`c` series VMs (AMD EPYC 9655P), 54 ms path, with a 9.01 Gbps no-tunnel
control repeated either side of the change:

| kernel | bound AES-GCM driver | mean | peak | decrypt core |
|---|---|---|---|---|
| 6.8.0-78 | `rfc4106-gcm-aesni` | 4.67 | 5.18 | 83% |
| **6.11.0-29** | **`rfc4106-gcm-vaes-avx10_512`** | **5.75** | **6.07** | **62%** |
| 7.0.0-30 | `rfc4106-gcm-vaes-avx512` | 2.16 | 2.23 | 83% |

Kernel 6.11 is worth **+23% per tunnel** for a package install: it is the first
release with a VAES/AVX-512 AES-GCM implementation, which drops crypto from
22.6% of receive cycles to under 3%. Kernel 7.0 carries the same fast crypto
and still measured 2.4× slower overall, so do not assume newer is better —
measure. `vpn_check_crypto_accel` reports which driver you are actually on.

Two other measured limits worth knowing before you size anything:

- A **single outer flow** delivers at most **8.1 Gbps** to the receiver's NIC
  across this WAN path, flat across offered rates from 3 to 9 Gbps.
- A single `iperf3` **server process** is single-threaded and caps out around
  4–5 Gbps. Use one process per flow or you will measure your test tool.

**[AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md)** works a full 10 Gbps deployment
end to end against Azure: the VM-count arithmetic, every host knob that was
measured (including the ones that made things worse), the settings Azure does
not enable for you, and where the bottleneck sits before and after. §4 there —
instance size, the kernel, and the host knobs — applies to **any** peer; only
§3.1 is Azure-specific.

## Sizing

**8 vCPU per gateway is the right default.** Each tunnel's decrypt occupies one
core, and against a managed cloud VPN you typically get **two tunnels per
gateway** — a redundant cloud VPN gateway publishes two outer addresses, and
one on-premises device gets one tunnel to each. Two decrypt cores plus 3–5
lightly loaded cores for the client-facing side fits comfortably in 8, with
headroom.

Scale throughput by **adding gateway VMs**, not by growing them. Each gateway
pair is worth roughly 2–3 Gbps on kernel 6.8; see
[AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md) for the kernel that improves that and
for a worked VM count to reach 10 Gbps with N+1 redundancy.

Two caveats worth knowing:

- With **one** tunnel per gateway, a 16 vCPU instance measured no faster than 8
  — it pinned a single core at 94% and left the rest idle. Verified in both
  traffic directions.
- With **many** tunnels per gateway (a Crusoe-to-Crusoe mesh, which no cloud
  peer will give you), cores do start to matter: at 5 tunnels each, 8 vCPU
  saturated all 8 cores while 16 vCPU still had headroom. Size for roughly one
  core per terminating tunnel plus 3–5 for the client side.

Gateways sustained 15–18 Gbps of NIC traffic each, so the NIC is rarely the
limit. Note that every user packet crosses a gateway's NIC **twice** — inbound
as GRE-over-FOU, outbound as ESP — so NIC load is about 2× the user traffic.

## Architecture

```
      Crusoe Cloud                               Remote Site
  ========================                   ========================

  +--------------------+                     +--------------------+
  | K8s Nodes          | GRE-over-FOU        | VMs / services     |
  | (DaemonSet)        |----+                | (datacenter)       |
  | Standalone VMs     |    |  (UDP 9473)    |                    |
  | (Ansible)          |    |   or plain     +--------+-----------+
  +--------------------+    |   routing               |
                            v                         |
                  +------------+    IPsec    +------------+
                  |    gw-1    |============|    peer    |
                  | xfrm0..N   |  encrypted | direct fwd |
                  | (Crusoe)   | (UDP 4500) | + SNAT     |
                  +------------+            +------------+
                                                  |
                                            Firewall / Internet
```

Scaled out, with several gateway VMs:

```
  clients ---ECMP---> gw-1     ==tunnel(s)==> +
                      gw-2     ==tunnel(s)==> | remote gateway(s)
                      gw-3     ==tunnel(s)==> +
```

**How it works**

1. **Route-based IPsec.** Each tunnel is a CHILD_SA bound to its own `if_id`
   with its own XFRM interface (`xfrm0`, `xfrm1`, …). Routing decides what
   enters which tunnel.
2. **Client transport** — how local VMs and K8s nodes reach the gateway. See
   [Client transports](#client-transports). GRE-over-FOU is the default because
   Crusoe's SDN port security blocks a VM from forwarding packets whose source
   is not its own address.
3. **Multipoint GRE** on the gateway with a pre-populated neighbour table
   covering the client CIDR, so new VMs and nodes are handled automatically.
4. **Mark-based routing** forwards client traffic into IPsec even for
   destinations outside the remote CIDR (needed for full tunnel) without
   touching the gateway's own default route.
5. **Full tunnel** routes `0.0.0.0/1` + `128.0.0.0/1` through the gateway —
   more specific than the default route, so it catches internet traffic while
   leaving intra-VPC routes alone.
6. **ECMP, and nothing stateful.** With several tunnels or gateways, traffic is
   hashed per flow. No NAT and no connection tracking sit in the path, which is
   what allows a reply to return through a *different* tunnel or gateway —
   exactly what a cloud VPN gateway does.

## Prerequisites

**Crusoe VPC firewall**

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 500 | UDP | Between gateways (public IPs) | IKE handshake |
| 4500 | UDP | Between gateways (public IPs) | IKE NAT-T (all IPsec traffic) |
| 9473 | UDP | Within VPC (gateway ↔ VMs/nodes) | GRE-over-FOU |
| 179 | TCP | Between gateway and peer BGP address | BGP, if enabled |
| — | ICMP | Within VPC (clients → gateways) | Client health probe, with >1 gateway |

**Remote side**

- UDP 500 + 4500 inbound from every Crusoe gateway public IP
- If the peer is a VM you run: NIC-level IP forwarding (see Cloud
  Prerequisites below)

> **Check both directions before deploying.** IPsec needs UDP 500/4500 each
> way, and a one-way block presents as "IKE timeout" with nothing useful in the
> strongSwan log. Between gateways in your inventory the preflight play tests
> exactly that on every run. Against a managed cloud peer there is nothing to
> run a listener on, so the proof is the tunnel establishing — check both
> firewalls before you deploy.
>
> If clients cannot ICMP their gateways, the multi-gateway health probe cannot
> tell a dead gateway from a live one. It fails safe — leaving routes alone
> rather than removing them — but you lose automatic failover.

**For `vpn_client_transport: route` only, and no playbook can do it:** Crusoe
must **disable port security** on every gateway VM's vNIC, or add
allowed-address-pairs covering `vpn_remote_subnet`. A gateway in `route` mode
forwards decrypted packets whose source is a *remote* private IP, and the SDN
drops those by default. The symptom is a healthy tunnel with no return traffic.

## Quick Start

### 1. Configure — two files

```bash
cd ansible
vim inventory.ini            # WHO: your gateway VM(s) and client VMs
vim group_vars/all.yml       # WHAT: five values
```

`group_vars/all.yml` asks for exactly five things:

| Value | What it is |
|---|---|
| `vpn_psk` | `openssl rand -base64 48`, and the same string on the peer (Azure calls it the Connection's *shared key*) |
| `vpn_remote_addrs` | the peer's public IPs — list **every** one to get a tunnel each (a redundant cloud VPN gateway publishes two) |
| `vpn_local_subnet` | your Crusoe CIDR |
| `vpn_remote_subnet` | the peer's CIDR (your cloud VPC/VNet, or the remote site's subnet) |
| `vpn_client_cidr` | which Crusoe IPs join the overlay, usually the same as `vpn_local_subnet` |

Everything else is already set for a managed cloud peer: GCMAES256, one tunnel
per peer address, GRE-over-FOU to your VMs, a stateless datapath, every
measured host tweak, and a VAES-capable kernel installed and booted if the
running one predates 6.11. The IKE identities derive from `ansible_host`, so
there is nothing to fill in for those.

> **Encrypt the PSK before committing anything.** Either keep
> `group_vars/all.yml` out of version control, or encrypt just the value:
>
> ```bash
> ansible-vault encrypt_string --stdin-name vpn_psk
> ```
>
> Run with `--ask-vault-pass`. The role already sets `no_log: true` on the task
> that writes the swanctl config.

### 2. Deploy

```bash
ansible-playbook -i inventory.ini site.yml
```

Four plays run in order, and the first one gates the rest:

| Play | Does |
|---|---|
| **preflight** | the five values are filled in · the OS is apt-based and its mirrors answer · `xfrm_interface`, `fou`, `ip_gre`, `esp4` exist · uplink MTU ≥ 1500 · every client VM is inside some gateway's `vpn_client_cidr` · **UDP 500 + 4500 pass in both directions between gateways** |
| **kernel** | installs a VAES-capable kernel if the running one predates 6.11, and reboots **only a host with no VPN on it yet** — on a first deploy that is before any config exists. A host already carrying tunnels gets the kernel installed and a note; reboot it in a window, or pass `-e vpn_kernel_reboot_live=true` |
| **gateways** | IPsec, XFRM interfaces, ECMP, firewall, host tuning |
| **clients** | routes from the Crusoe VMs into the overlay |

Preflight runs with `any_errors_fatal`, so one bad host stops the run before
anything is touched. A half-configured VPN is worse than an unconfigured one.

The bidirectional UDP test is the one that saves the most time: IPsec needs
both ports both ways, and a one-way block presents as "IKE timeout" with
nothing useful in the strongSwan log. It runs only when the peer is a host in
your inventory — a managed cloud gateway has nothing to run a listener on —
and is skipped when a tunnel is already up, because an installed SA is
stronger evidence than any probe.

Adding a gateway VM later means adding it to `inventory.ini` and re-running —
clients ECMP across every host in the `vpn_gateways` group automatically, with
no list to maintain. A managed cloud peer will usually need BGP enabled before
it spreads return traffic across them; see `group_vars/all.yml`.

### 3. K8s nodes

```bash
vim ../k8s/vpn-client.yaml            # GATEWAY_IPS, TRANSPORT, REMOTE_CIDRS
kubectl apply -f ../k8s/vpn-client.yaml
```

### 4. Verify

```bash
ansible-playbook -i inventory.ini site.yml --tags verify
ssh <crusoe-vm> ping <remote-vm-private-ip>
```

To measure throughput, use [bandwidth-test](../bandwidth-test/).

## Client transports

`vpn_client_transport` on the gateway; the client role inherits it.

| Value | Meaning | Prerequisite |
|---|---|---|
| `gre_fou` | GRE-over-FOU overlay (**default**) | none |
| `route` | plain static routes via the gateway's private IP | **port security disabled on each gateway vNIC** |
| `none` | gateway carries no local clients; forwards its own LAN subnet | none |

`vpn_use_gre: true/false` still works as a deprecated alias.

`gre_fou` stays the default because `route` needs a manual network change no
playbook can make. Where `route` is allowed it is better:

| | `gre_fou` | `route` |
|---|---|---|
| Client devices | N GRE devices + FOU sockets | none |
| Client MTU | 1400 | 1400 |
| Gateway setup | FOU module, multipoint GRE, one neighbour entry per host in the CIDR, 2 policy tables | plain FIB forwarding |
| **GRO on the uplink** | **must be OFF** — see troubleshooting | unaffected |
| **Client CIDR size** | a `/20` is 4094 neighbour entries; a `/16` is refused | any size |
| Flow entropy on the fabric | one FOU 4-tuple per client↔gateway pair unless `vpn_fou_sport_auto` | the real client 5-tuples |
| Dead-gateway detection | needs the ICMP probe | `fib_multipath_use_neigh` handles VM death for free |

On `gre_fou`, set `vpn_fou_sport_auto: true` for better flow spread without the
port-security change — the kernel then hashes the outer FOU source port per
inner flow.

## Crypto profiles

| Profile | IKE | ESP |
|---|---|---|
| `default` | `aes256-sha384-ecp256-modp3072` | `aes256gcm128-ecp256-modp3072` |
| **`gcmaes256`** | `aes256gcm16-prfsha384-ecp384` | `aes256gcm16-ecp384` |
| `gcmaes256_fast` | `aes256gcm16-prfsha256-ecp256` | `aes256gcm16-ecp256` |
| `cbc_compat` | `aes256-sha256-modp2048` | `aes256-sha256-modp2048` |

Setting `vpn_ike_proposals` or `vpn_esp_proposals` explicitly overrides the
profile.

Two things worth knowing:

- In strongSwan, `aes256gcm128` and `aes256gcm16` are **the same thing** —
  AES-256-GCM with a 128-bit ICV. Azure spells it **GCMAES256**; other clouds
  use their own names for the same cipher. So this role's **ESP has always been
  GCM**; it was **IKE** that was AES-CBC before `gcmaes256` became the default.
- **AES-GCM is worth several times CBC+HMAC per tunnel** on a managed peer,
  because their published per-tunnel rates differ sharply by cipher suite —
  Azure's own figures are 2.3 Gbps versus 700 Mbps. Both ends must offer the
  same suite or IKE fails with `NO_PROPOSAL_CHOSEN`, and most clouds do **not**
  pick GCM by default. See [AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md) §3.1 for
  the exact Azure policy fields.

Verify what was actually negotiated, not what was requested:

```bash
sudo swanctl --list-sas | grep -i aes
```

## Multiple tunnels and multiple gateways

Two independent kinds of fan-out.

### Several tunnels from one gateway

For a peer that publishes more than one outer address. A redundant cloud VPN
gateway has two, which is the practical maximum per on-premises device:

```yaml
# group_vars/all.yml - nothing else to set
vpn_remote_addrs:
  - "<peer-instance-0-public-ip>"
  - "<peer-instance-1-public-ip>"
```

Two addresses give two tunnels (`vpn_tunnel_count: 0` means one per address)
with IP identities, which is what a managed cloud peer matches on.

Tunnel *i* gets `xfrm{i}` and `if_id 100+i`, all with identical traffic
selectors, plus one ECMP route across them.

> **The failure that looks like success:** raising `vpn_tunnel_count` while both
> `vpn_local_addrs` and `vpn_remote_addrs` resolve to a single address. With
> NAT-T both UDP ports are pinned to 4500, so every tunnel shares one outer
> 4-tuple, lands on one receive queue, and performs exactly like one tunnel.
> The role warns when it sees this.

### Several gateway VMs

Crusoe gives a VM one public IP, and a managed cloud peer identifies each
on-premises device by a unique public IP, so throughput past one gateway comes
from **more gateway VMs**:

```ini
# inventory.ini
[vpn_gateways]
gw-1  ansible_host=<public-ip-1>
gw-2  ansible_host=<public-ip-2>
gw-3  ansible_host=<public-ip-3>
```

That is the whole change: clients ECMP across every host in `vpn_gateways`
automatically. (A two-site Crusoe deployment needs `vpn_gateway_hosts` set per
site instead — see `host_vars/gw-2.yml.example`.)

**Against a managed cloud VPN, BGP becomes mandatory.** These services will not
spread return traffic across several on-premises devices without it, and
generally want one peer definition per device with a unique ASN and BGP peer
address. Set `vpn_bgp_enabled: true` plus `vpn_bgp_local_asn`,
`vpn_bgp_advertise`, `vpn_bgp_accept` and `vpn_bgp_peer_addrs`. The exact
objects to create on the Azure side are in
[AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md) §3.1.

**Between two sites you control, BGP is not needed.** Pair the gateways 1:1 and
give each pair its own tunnel:

```yaml
# host_vars/site-a-gw-1.yml   (and -2, -3 ... paired with the same index)
vpn_local_id:      "site-a-gw-1@crusoe.vpn"
vpn_remote_id:     "site-b-gw-1@crusoe.vpn"
vpn_remote_gw_ip:  "<site-b-gw-1 public IP>"
vpn_local_subnet:  "<site A CIDR>"
vpn_remote_subnet: "<site B CIDR>"
vpn_client_cidr:   "<site A CIDR>"
```

For maximum throughput between two sites you own, give every gateway a tunnel
to every peer gateway. `vpn_id_style: indexed` keeps the local identity fixed
and indexes the remote one:

```yaml
vpn_tunnel_count: 5
vpn_remote_addrs: ["<peer-gw-1>", "<peer-gw-2>", "<peer-gw-3>", "<peer-gw-4>", "<peer-gw-5>"]
vpn_local_id:  "site-a-gw-1@crusoe.vpn"
vpn_remote_id: "site-b-gw@crusoe.vpn"    # becomes site-b-gw-1@ .. -5@
vpn_id_style:  "indexed"
```

That is what produced 42.4 Gbps. No cloud peer will let you do it — it needs
control of both ends.

### Rules that come with ECMP

The role enforces these because getting them wrong silently drops traffic:

- `net.ipv4.fib_multipath_hash_policy = 1` on gateways **and clients**. At the
  default `0` the kernel hashes source/destination IP only, so every flow takes
  one path and the rest idle.
- **No SNAT and no conntrack in the path.** SNAT is stateful, so a reply
  returning through a different gateway has no matching entry. Set
  `vpn_disable_conntrack: true`, `vpn_stateful_forward_rule: false`,
  `vpn_snat_internet_egress: false`. The role fails if these disagree.
- `rp_filter = 2` (loose). Strict reverse-path filtering rejects the asymmetric
  return, which is normal here.

## Full Tunnel Mode

Route all internet traffic through the remote site's firewall.

**Standalone VMs** — `group_vars/all.yml`:
```yaml
vpn_remote_subnets: ["0.0.0.0/1", "128.0.0.0/1"]
```

**K8s nodes** — `k8s/vpn-client.yaml` ConfigMap:
```yaml
REMOTE_CIDRS: "0.0.0.0/1 128.0.0.0/1"
```

**Source gateway** — `vpn_remote_subnet: "0.0.0.0/0"`
**Remote gateway** — `vpn_local_subnet: "0.0.0.0/0"`, plus internet access and
a default route for egress.

> With full tunnel, VMs are only reachable via a jump host. Set
> `ansible_ssh_common_args` with `ProxyJump` in the inventory.

> **Multi-gateway caveat:** full-tunnel internet egress needs SNAT on the
> *remote* gateway, and SNAT is stateful. So the remote side cannot itself be
> ECMP'd across several SNAT gateways. With a managed cloud VPN as the remote
> this is a non-issue — the provider owns its own egress NAT.

## Cloud Prerequisites (Remote Side)

Whatever the peer, four things have to be true on its side. None of them can be
set from this repo.

| # | Requirement | Why |
|---|---|---|
| 1 | UDP **500 and 4500** open inbound from every Crusoe gateway public IP | IKE and NAT-T. A one-way block presents as "IKE timeout" with nothing useful in the log |
| 2 | A **route** for your Crusoe CIDR pointing at the peer gateway | otherwise return traffic never leaves |
| 3 | **AES-GCM** offered by the peer's IPsec policy | most managed VPNs default to AES-CBC + HMAC, which their own tables rate several times slower — see [Crypto profiles](#crypto-profiles) |
| 4 | One **unique public IP** per Crusoe gateway VM, and **BGP** if you run more than one | a managed peer identifies each on-premises device by IP, and will not spread return traffic across several without BGP |

If your peer is a **managed cloud VPN service** (Azure VPN Gateway, GCP HA VPN,
AWS Site-to-Site VPN), it also imposes a per-tunnel and an aggregate rate cap,
and those caps — not this side — will set your VM count.

> **Azure**, worked end to end, including the three settings Azure leaves off
> by default and what each costs you:
> **[AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md) §3**.

If the peer is a **VM you run** (another Crusoe region, a datacenter, an EC2 or
Compute Engine instance), there is no per-tunnel cap and it needs NIC-level IP
forwarding plus a route — the per-cloud commands below.

### Azure VM as the peer

```bash
az network nic update --resource-group <rg> --name <gw-nic> --ip-forwarding true

az network route-table create --resource-group <rg> --name vpn-to-crusoe --location <loc>
az network route-table route create \
    --resource-group <rg> --route-table-name vpn-to-crusoe --name to-crusoe \
    --address-prefix <crusoe-private-subnet> \
    --next-hop-type VirtualAppliance --next-hop-ip-address <gw-private-ip>
az network vnet subnet update \
    --resource-group <rg> --vnet-name <vnet> --name <subnet> --route-table vpn-to-crusoe
```

### GCP VM as the peer

```bash
gcloud compute instances create <gw-vm> --can-ip-forward ...
gcloud compute routes create vpn-to-crusoe \
    --destination-range=<crusoe-private-subnet> \
    --next-hop-instance=<gw-vm> --next-hop-instance-zone=<zone>
```

### AWS instance as the peer

```bash
aws ec2 modify-network-interface-attribute --network-interface-id <eni> --no-source-dest-check
aws ec2 create-route --route-table-id <rt> \
    --destination-cidr-block <crusoe-private-subnet> --network-interface-id <eni>
```

## File Structure

```
.
├── README.md
├── AZURE-10G-GUIDE.md                       # 10 Gbps N+1 against Azure, worked
├── k8s/
│   └── vpn-client.yaml                      # DaemonSet: transport, ECMP, node sysctls
└── ansible/
    ├── inventory.ini                        # EDIT: who - gateway VMs, client VMs
    ├── group_vars/
    │   └── all.yml                          # EDIT: what - five values
    ├── site.yml                             # check -> kernel -> gateways -> clients
    ├── host_vars/
    │   └── gw-2.yml.example                # optional, inert: Crusoe<->Crusoe
    │                                        # subnets, or per-gateway BGP
    └── roles/
        ├── vpn_gateway/
        │   ├── defaults/main.yml
        │   ├── tasks/main.yml
        │   ├── tasks/preflight.yml         # gates everything; must pass first
        │   ├── tasks/kernel.yml            # VAES kernel: install, boot, verify
        │   ├── handlers/main.yml
        │   └── templates/
        │       ├── tunnels.json.j2         # derives the tunnel list
        │       ├── swanctl-vpn.conf.j2
        │       ├── strongswan-vpn.conf.j2
        │       ├── sysctl-vpn.conf.j2
        │       ├── vpn-network.sh.j2       # ALL links, routes, rules, marks
        │       ├── vpn-network.service.j2
        │       ├── ecmp-health.{sh,service,timer}.j2
        │       ├── preflight-probe.sh.j2   # bidirectional UDP 500/4500 probe
        │       ├── perf-tuning.sh.j2
        │       └── frr{-daemons,.conf}.j2  # BGP
        └── vpn_client/
            ├── defaults/main.yml
            ├── tasks/main.yml
            └── templates/
                ├── client-paths.json.j2    # derives the gateway path list
                ├── vpn-client.{sh,service}.j2
                ├── vpn-client-health.{sh,service,timer}.j2
                ├── sysctl-vpn-client.conf.j2
                └── client-perf-tuning.sh.j2
```

`vpn-network.sh` and `vpn-client.sh` are rendered once and called by **both**
the playbook and the systemd unit, so live state and boot state cannot drift.

## Key Variables

Gateway (`roles/vpn_gateway/defaults/main.yml` documents every one):

| Variable | Default | Purpose |
|----------|---------|---------|
| `vpn_psk` | — | IKE pre-shared key |
| `vpn_client_transport` | `""` → `gre_fou`/`none` | `gre_fou`, `route`, or `none` |
| `vpn_client_cidr` | — | subnet of VMs/nodes behind this gateway |
| `vpn_local_subnet` / `vpn_remote_subnet` | — | IPsec traffic selectors |
| `vpn_remote_gw_ip` | — | peer public IP; the fallback when `vpn_remote_addrs` is empty |
| `vpn_remote_addrs` | `[]` | peer outer IPs, one per tunnel |
| `vpn_tunnel_count` | `0` (auto) | one tunnel per entry in `vpn_remote_addrs`, minimum 1 |
| `vpn_id_style` | `""` (auto) | `fixed`, `indexed`, or `address` |
| `vpn_crypto_profile` | `gcmaes256` | `default` is the legacy AES-CBC profile |
| `vpn_bgp_enabled` | `false` | required for multi-gateway ECMP against a managed cloud peer |
| `vpn_xfrm_mtu` / `vpn_gre_mtu` | `1400` / `1400` | the tunnel MTU managed cloud VPNs document |
| `vpn_mss_clamp` / `_value` | `true` / `""` (derived) | see troubleshooting |
| `vpn_fou_disable_gro` | `true` | **required** for `gre_fou`; see troubleshooting |
| `vpn_perf_tuning` | `true` | offloads, queues, RPS, IRQ pinning, performance governor |
| `vpn_disable_rfs` | `true` | **keep it** — RFS reorders one SA's packets into anti-replay drops; measured 176× more retransmits when on |
| `vpn_replay_window` | `1024` | ESP anti-replay; 0–4096, and 32768 stops the SA installing |
| `vpn_check_crypto_accel` | `true` | warns when the kernel has no VAES AES-GCM driver (+23%/tunnel) |
| `vpn_require_crypto_accel` | `false` | make that a hard failure instead |
| `vpn_nic_rings` | `0` (leave) | raising to 8192 measured **−9.1%** |
| `vpn_rx_usecs` | `0` (adaptive) | fixed coalescing; 64 measured +2.6%, 128 measured −2.0% |
| `vpn_disable_conntrack` | `true` | NOTRACK; required for multi-gateway ECMP (`vpn_stateful_forward_rule` is therefore `false`) |
| `vpn_kernel_upgrade` / `vpn_kernel_reboot` | `true` / `true` | install a VAES kernel; reboot only a host with no VPN yet |
| `vpn_kernel_reboot_live` | `false` | allow that reboot on a host already carrying tunnels |

Client (`roles/vpn_client/defaults/main.yml`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `vpn_gateway_hosts` | `groups['vpn_gateways']` | gateways to ECMP across; set per site in a two-site deployment |
| `vpn_remote_subnets` | — | CIDRs to route through the VPN |
| `vpn_client_tcp_tuning` | `true` | buffers + BBR; removes a ~1 Gbps/flow cap |
| `vpn_client_healthcheck` | auto | probe gateways, rebuild ECMP |

DaemonSet (`k8s/vpn-client.yaml`): `GATEWAY_IPS`, `TRANSPORT`, `REMOTE_CIDRS`,
`DISABLE_GRO`, `MULTIPATH_HASH_POLICY`, `TCP_TUNING`.

## Known limitations

- **One client CIDR per gateway.** `vpn_client_cidr` is a single prefix.
  Clients across disjoint subnets need a covering supernet.
- **`gre_fou` cannot serve a large client CIDR.** One permanent neighbour entry
  per host: a `/20` is 4094, a `/16` is refused by the role.
- **`gre_fou` requires GRO off on every uplink.** Host-wide setting, affecting
  all traffic on that NIC.
- **`route` transport needs port security disabled**, and is **the one path not
  validated live** — it renders and passes static checks, but port security was
  enabled throughout testing. Treat the first `route` deployment as supervised.
- **BGP is not validated live** either; it is not needed for a
  Crusoe-to-Crusoe pairing. All Azure figures quoted come from Microsoft's
  published tables, not measurement.
- **SNAT and multi-gateway ECMP are mutually exclusive.** The role refuses the
  combination.
- **Ansible reports `changed`** on the script-driven tasks every run. The
  scripts are idempotent — a re-run against a live deployment causes no traffic
  loss — but the tasks are not annotated to detect a no-op.
- **Failover is probe-based**, so clients notice a dead gateway within
  `vpn_client_healthcheck_interval` (15 s), not instantly.
- **Redeploys can leave a duplicate IKE SA.** Cosmetic — traffic uses one set
  of kernel states — but `swanctl --list-sas` shows more SAs than tunnels.
  `systemctl restart strongswan` clears them.
- **No IPv6.**

## Operations

```bash
ansible-playbook -i inventory.ini site.yml                    # deploy all
ansible-playbook -i inventory.ini site.yml --limit gw-1       # one gateway (UDP probe skipped: peer not in run)
ansible-playbook -i inventory.ini site.yml --tags verify      # check only
ansible-playbook -i inventory.ini site.yml --tags teardown    # remove all (preflight skipped on purpose)

kubectl apply -f k8s/vpn-client.yaml
kubectl rollout restart ds/vpn-client -n kube-system
kubectl logs -n kube-system ds/vpn-client
```

## Troubleshooting

```bash
# --- Gateway ---
sudo swanctl --list-sas                     # SA status and negotiated algorithms
ip -br link show type xfrm                  # every tunnel's interface
ip route show <remote-cidr>                 # one nexthop per tunnel
sysctl net.ipv4.fib_multipath_hash_policy   # MUST be 1 with ECMP
ethtool -k ens3 | grep generic-receive      # MUST be off with gre_fou
sudo iptables -t mangle -S FORWARD | grep TCPMSS
sudo vtysh -c "show ip bgp summary"         # if BGP is enabled
sudo /usr/local/sbin/vpn-network.sh up      # re-apply links/routes/marks
sudo conntrack -C                           # should be ~0 for tunnel traffic

# --- Client VM ---
ip route show <remote-cidr>                 # one nexthop per gateway
sysctl net.ipv4.fib_multipath_hash_policy net.ipv4.tcp_congestion_control
systemctl status vpn-client vpn-client-health.timer
sudo /usr/local/sbin/vpn-client-health.sh   # re-probe now

# --- K8s ---
kubectl logs -n kube-system ds/vpn-client
```

| Symptom | Check |
|---------|-------|
| IKE timeout | UDP 500+4500 open **both ways** between every gateway public IP and the peer? Between gateways you own the preflight play tests exactly this; against a cloud peer check both firewalls — a one-way block looks exactly like a broken config. |
| `NO_PROPOSAL_CHOSEN` | Both ends offering the same crypto? A managed cloud peer usually needs a custom IPsec/IKE policy set to match — most default to AES-CBC. |
| **Ping and UDP fine, TCP collapses to a few Mbit/s** | **GRO on the physical NIC.** It coalesces inbound FOU packets that then cannot be re-encapsulated, so they are dropped — measured **3.65 Mbps vs 4590 Mbps**. `ethtool -K <uplink> gro off` on gateways **and** clients; the role does this automatically for `gre_fou`. Look for `UdpInErrors` climbing on the receiving gateway. |
| TCP stalls only for full-size packets | MSS clamped **above** the path MTU. `iptables --set-mss` raises as well as lowers. Leave `vpn_mss_clamp_value` empty so it is derived. |
| Tunnel up, no traffic | Routes through xfrm? Mark rules present? (`ip rule show`) |
| `route` mode: tunnel up, no return traffic | **Port security still enabled on the gateway vNIC.** The usual cause. |
| N tunnels but no more throughput | `fib_multipath_hash_policy` = 1? Does `vpn_remote_addrs` have more than one address? Are per-SA byte counters even? |
| Throughput per flow stuck near 1 Gbps | Client TCP buffers. `vpn_client_tcp_tuning` and `tcp_rmem` max ≥ 64 MB. |
| **Tunnel healthy, ping clean, TCP retransmitting hard** | **Anti-replay is discarding reordered packets.** `grep XfrmInStateSeqError /proc/net/xfrm_stat` — if it climbs, check `cat /sys/class/net/<uplink>/queues/rx-0/rps_flow_cnt`. RFS hands one SA's packets between CPUs so they arrive out of order. Measured 18,624 retransmits with RFS on versus 106 with it off. Keep `vpn_disable_rfs: true`. |
| Tunnel never installs after changing `vpn_replay_window` | Values the kernel refuses leave the SA uninstalled. 1024 works; 32768 does not. The role now validates 0–4096. |
| Per-tunnel throughput ~20% below expectation | Kernel has no VAES AES-GCM driver. `sed -n "/^name .*: rfc4106(gcm(aes))$/,+1p" /proc/crypto` — want a `*vaes*` driver. Needs kernel ≥ 6.11; see [AZURE-10G-GUIDE.md](AZURE-10G-GUIDE.md) §4.2 (host-side, applies to any peer). |
| Benchmark plateaus at 4–5 Gbps regardless of tuning | A single `iperf3` server process is single-threaded. Use one process per flow — the `bandwidth-test` solution does. |
| Some flows blackhole after a gateway dies | Health timer running? `vpn_client_healthcheck: true`? |
| Return traffic dropped intermittently | SNAT or a conntrack-only firewall rule in the path. Both break multi-gateway ECMP. |
| Client play fails on "could not resolve every gateway's private IP" | Ran with `--limit vpn_clients`, so the gateways play never set its facts. Run the whole `site.yml`, or set `vpn_local_gw_ip=<private-ip>` per gateway in the inventory. |
| FOU packets not arriving | UDP 9473 open within the VPC? |
| Full tunnel: no internet | Remote gateway has internet access and a SNAT rule? |
| `strongswan-starter` conflict | Ansible disables it; if manual, `systemctl stop strongswan-starter` |
