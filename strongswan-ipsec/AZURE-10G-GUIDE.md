# Reaching 10 Gbps to Azure with N+1

A worked deployment against **Azure VPN Gateway**: how many Crusoe gateway VMs
you need, what the playbook already handles, and — the part that bites people —
**what Azure does not enable for you.**

For the solution itself — transports, crypto profiles, variables,
troubleshooting — see [README.md](README.md). §4 here (sizing, kernel, host
knobs) applies to **any** peer; §3.1 is the Azure-specific part.

Everything labelled **measured** was measured on Crusoe between
`eu-iceland2-a` and `eu-norway1-a`, 54 ms RTT, on `c` series VMs (AMD EPYC
9655P, Zen 5, BlueField-3 VF). **Derived** is arithmetic on those numbers, not
an observation. **Published** comes from the cloud vendor's own documentation.

---

## 1. The short answer

| Peer | Gbps per VM | VMs for 10 Gbps | With N+1 | Basis |
|---|---|---|---|---|
| **Azure** VpnGw5 | 4.6 | 3 | **4** | published |
| **Crusoe ⇄ Crusoe**, `c` series + kernel 6.11 | 2.4 → 4.1 | 4 | **5** | **measured** |

Two thresholds are worth separating, because the work involved is very
different:

- **4.6 Gbps** — one gateway VM, `ansible-playbook -i inventory.ini site.yml`,
  and **two** non-default settings on the Azure side: active-active mode, for
  the second public IP that becomes the second tunnel, and the cipher policy
  (§3.1 items 2 and 3). This is the easy win.
- **10 Gbps** — three gateway VMs against Azure, and Azure needs **BGP plus
  active-active mode plus a Local Network Gateway per VM**. None of that can
  be automated from this repo. That is what §3 is for.

### The measured Crusoe-to-Crusoe curve

20 client pairs per side, GRE-over-FOU overlay, `gcmaes256`, 54 ms path.
Deployed and measured with the shipped playbook, on both kernels:

| gateways/side | kernel 6.8 | **kernel 6.11** | change | per gateway | peak core |
|---|---|---|---|---|---|
| 1 | 2.05Gbps | **2.37Gbps** | +15.5% | 2.37Gbps | 89% |
| 2 | 4.38Gbps | **5.60Gbps** | +27.8% | 2.80Gbps | 63% |
| 3 | 7.38Gbps | **9.42Gbps** | +27.7% | 3.14Gbps | 93% |
| 4 | 10.78Gbps | **16.16Gbps** | +49.9% | 4.04Gbps | 92% |
| 5 | 14.79Gbps | **20.66Gbps** | +39.7% | 4.13Gbps | 92% |

**Four gateways per side clears 10 Gbps** — three gives 9.42, just short. Lose
one of four and you are left with 9.42, which is 94% of target; deploy five if
you need a hard 10 Gbps floor through a single failure.

Note that **throughput per gateway rises with gateway count** (2.37 → 4.13).
That is not noise. With one gateway per side the same box receives every
client's FOU flow *and* terminates the tunnel, so both directions contend on
one machine. Adding gateways relieves the client-facing side, and the
per-gateway figure converges on the pure per-tunnel limit.

This is also why a *derived* number was not good enough here. Arithmetic on
the single-tunnel figure (2 × 5.75 Gbps, NIC-bounded) predicted roughly 8 Gbps
per VM and 2 VMs for 10 Gbps. The measurement says 2.4–4.1 Gbps per VM and 4
VMs. The GRE leg costs far more than the arithmetic suggested.

---

## 2. What actually limits throughput

In the order they bite. Know which ceiling you are against before tuning
anything.

| Limit | Value | Basis |
|---|---|---|
| Azure, per **tunnel** (GCMAES256) | 2.3 Gbps | published |
| Azure, per **tunnel** (default CBC policy) | 0.7 Gbps | published |
| Azure, per gateway aggregate (VpnGw5) | 10 Gbps | published |
| Tunnels per VM against a cloud peer | 2 | published |
| One tunnel, one core — kernel 6.11 | 5.75 Gbps | measured |
| One tunnel, one core — kernel 6.8 | 4.67 Gbps | measured |
| **One gateway VM, 2 tunnels, GRE overlay** | **8.46 Gbps** | **measured** |
| One **outer flow** to the receiver's NIC | 8.1 Gbps | measured |
| Whole WAN path, 16 separate flows | 9.0 Gbps | measured |

**One tunnel is one outer 4-tuple, so one RX queue, so one core.** Nothing
software-side splits it. More cores per VM does not help; more tunnels does.

**Every user packet crosses a GRE gateway's NIC twice** — inbound as
GRE-over-FOU from the client, outbound as ESP to the peer. A gateway needs
roughly 2 Gbps of NIC for every 1 Gbps of user traffic.

---

## 3. What is NOT a default — the manual work

### 3.1 On the Azure side. None of this can be automated from here.

| # | Do this | Azure default? | Why it matters |
|---|---|---|---|
| 1 | SKU **VpnGw5** (or VpnGw5AZ — zone-redundant, same speed) | no, you pick it | 10 Gbps aggregate. VpnGw4 caps at 5. |
| 2 | Enable **active-active** mode | **NO — off** | Gives the gateway two public IPs. That is what turns one Crusoe VM into two tunnels instead of one. |
| 3 | Custom **IPsec/IKE policy** on **every** Connection | **NO — off** | The single highest-value setting on this page. See below. |
| 4 | One **Local Network Gateway per Crusoe gateway VM**, each carrying that VM's public IP and your Crusoe CIDR | no | Azure matches an on-premises device by its public IP. |
| 5 | **Enable BGP** on the gateway and every LNG — unique ASN and peer address per LNG | **NO — off** | Azure will not spread return traffic across several on-premises devices without it. Needed only above one gateway VM. |
| 6 | Shared key on every Connection = your `vpn_psk` | no | Must be byte-identical. |
| 7 | One **Connection per LNG**, so 3 VMs = 3 Connections = 6 tunnels | no | 6 × 2.3 = 13.8 Gbps of capacity into a 10 Gbps SKU. |

**Item 3 in full, because it is worth 3.3×.** Azure's default policy
negotiates AES-CBC with HMAC-SHA, which its own tables rate at **700 Mbps per
tunnel**. GCMAES256 is rated **2.3 Gbps**. On each Connection set:

| Field | Value |
|---|---|
| IPsec Encryption | **GCMAES256** |
| IPsec Integrity | **GCMAES256** |
| IKE Encryption | AES256 |
| IKE Integrity | SHA384 |
| DH Group | ECP384 |
| PFS Group | ECP384 |
| SA lifetime | 3600 s (matches this role's `rekey_time`) |

Our side already proposes exactly this (`vpn_crypto_profile: "gcmaes256"` is
the default, negotiating `aes256gcm16-ecp384`). If Azure is left on its
default policy, IKE either fails with `NO_PROPOSAL_CHOSEN` or — worse —
succeeds at 700 Mbps and looks fine.

```bash
# Verify what actually got negotiated, on any gateway:
sudo swanctl --list-sas | grep -o 'ESP:[^ ]*'
# want: ESP:AES_GCM_16-256
```

### 3.2 On the Crusoe side

| # | Do this | Why |
|---|---|---|
| 1 | Create **3 gateway VMs** for 10 Gbps, **4** for N+1. 8 vCPU each. | One VM is 4.6 Gbps. Do not make them bigger — see §4.1. |
| 2 | Open the **VPC firewall**: UDP 500 + 4500 between your gateway public IPs and Azure's; UDP 9473 inside the VPC; ICMP inside the VPC | 9473 is the GRE-over-FOU overlay. ICMP is the client health probe that removes a dead gateway from the ECMP set. |
| 3 | List every gateway VM in `inventory.ini` | Clients ECMP across the whole `vpn_gateways` group automatically — no list to maintain. |
| 4 | Set `vpn_bgp_enabled: true` plus `vpn_bgp_local_asn` and `vpn_bgp_peer_addrs` per gateway | Required by Azure item 5, and only above one gateway VM. |
| 5 | Open UDP 500 + 4500 on **both** firewalls before you deploy | The **preflight play** probes UDP 500/4500 both ways between Crusoe gateways you own, but against Azure there is nothing to run a listener on — so the proof is the SA establishing, and an IKE timeout there almost always means one direction is blocked. Preflight still checks MTU, kernel modules, apt reachability, and that every client VM is inside `vpn_client_cidr`. |

### 3.3 What you do NOT need to touch

All of this is already the default. Changing it will most likely make things
worse — the measurements are in §4.3.

`gcmaes256` · one tunnel per peer address (so 2 against active-active) · UDP
encapsulation forced · GRE-over-FOU to your VMs · GRO off on the uplink ·
MSS derived from the real path MTU · RFS off · ECMP L4 hashing on gateways
*and* clients · loose reverse-path filtering · conntrack disabled with both
its interlocks · anti-replay window 1024 · NIC IRQ pinning and XPS ·
performance governor · client TCP buffers and BBR · a VAES-capable kernel
installed and booted if the running one predates 6.11.

---

## 4. Sizing and tuning

### 4.1 Instance size: 8 vCPU, not larger

Against a cloud peer you get two tunnels per VM, each pinning one core for
inbound decrypt. On these VMs 8 vCPU is **four physical cores** with SMT —
`thread_siblings_list` reads `0-1`, `2-3`, `4-5`, `6-7` — so two tunnels use
half the real cores and leave the rest for the GRE leg.

One tunnel at 5.75 Gbps put its decrypt core at **62%**. Growing the instance
does not move that number, because the work cannot leave that core.

### 4.2 Kernel: the largest single host-side win

The kernel binds the highest-priority driver registered for
`rfc4106(gcm(aes))`. Kernels before 6.11 ship only the 2010-era AES-NI
implementation.

| Kernel | Bound AES-GCM driver | Mean | Decrypt core | Crypto share of RX cycles |
|---|---|---|---|---|
| 6.8.0-78 | `rfc4106-gcm-aesni` | 4.67 Gbps | 83% | 22.6% |
| **6.11.0-29** | **`rfc4106-gcm-vaes-avx10_512`** | **5.75 Gbps** | **62%** | **under 3%** |
| 7.0.0-30 | `rfc4106-gcm-vaes-avx512` | 2.16 Gbps | 83% | 1.6% |

**+23% per tunnel**, and the playbook does it for you — install, initramfs,
GRUB, reboot, and a post-reboot assertion that the fast driver is actually
bound. On a first deploy it runs before any VPN config exists, so the reboot
interrupts nothing. On a gateway that already carries tunnels it installs the
kernel and **does not reboot** — it prints a note, and you reboot in a window
one gateway at a time, or pass `-e vpn_kernel_reboot_live=true`. It never
reboots a host that is already running the requested kernel, so it cannot
loop.

**Do not point `vpn_kernel_package` at 7.0.** It carries the same fast crypto
and still measured **2.4× slower** end to end. A `perf` profile explains it:
on 6.8 one symbol dominates at 17% (`key_256_dec_update`, the AES-NI decrypt),
while on 7.0 no symbol exceeds 2.5% and the cycles spread across
`fib_rules_lookup`, `nft_meta_store_ifname`, `xfrm_sk_policy_lookup`,
`pskb_expand_head` and the `srso_safe_ret` speculation mitigation — which 6.11
reports as `Not affected` on the same CPU. The crypto got cheap; everything
else got expensive.

### 4.3 Host knobs, measured

The one that matters is **RFS off**, and it is already the default.

Receive Flow Steering sends a packet to the CPU where the consuming socket
last ran. For a single IPsec tunnel that hands one SA's packets between CPUs,
so they reach `xfrm_input` out of order and the ESP anti-replay window rejects
the stragglers. The tunnel stays `INSTALLED`, ping is clean, and only TCP
suffers.

| `rps_flow_cnt` | Throughput | Retransmits | Anti-replay drops |
|---|---|---|---|
| 4096 | 4.67 Gbps | 18,624 | 46,697 |
| **0** | **4.86 Gbps** | **106** | **3,141** |

+4.2% and **176× fewer retransmits**. Read honestly: those figures are at
4.7 Gbps on kernel 6.8. On 6.11 at 5.7 Gbps the rejections come back to
roughly 1M per 20 s with RFS *already off*, because at that rate the
reordering is the WAN path's, not the host's — the no-tunnel control on the
same path retransmits 2.57M at 9 Gbps. RFS-off removes the reordering *this
host* causes. It cannot fix the network.

Everything else was tested and left alone:

| Change | Effect | Why |
|---|---|---|
| `ethtool -G rx 8192 tx 8192` | **−9.1%** | A deeper ring holds more in flight, widening reordering |
| `rx_cqe_moder` + `rx_cqe_compress` | −0.2% | Nothing. Widely recommended; does not apply here |
| `ethtool -C rx-usecs 128` | −2.0% | Over-batched |
| `ethtool -C rx-usecs 64` | +2.6% | The only positive one, and small |
| `gro_normal_batch 64` | +1.1% | Inside this rig's noise band |
| `esp-hw-offload` | n/a | `off [fixed]` — impossible on a VF; a platform-team ask |
| `replay_window 32768` | breaks | SA never installs, tunnel never comes up |
| More vCPU per gateway | 0% | One tunnel cannot leave one core |

---

## 5. N+1

Deploy `N+1` gateways per side and let ECMP spread flows across all of them.
Lose one and the remaining `N` still carry the target.

This only works if a return packet may arrive on a **different** gateway than
the one that sent it — so no SNAT and no conntrack. That is what
`vpn_disable_conntrack: true` and its two interlocks enforce, and the role
fails the play if you break them.

| Failure injected | Throughput after | Expected (4/5) |
|---|---|---|
| One tunnel killed | 84% | 80% |
| One gateway VM killed | 79% | 80% |

Measured on a 5-gateway deployment. Both land where the arithmetic says.
Expect a brief reconvergence, not a clean step.

---

## 6. Verify it

Preflight is a play, not a script, and it gates every other play. To run just
that part:

```bash
ansible-playbook -i inventory.ini site.yml --tags preflight
```

It checks the five required values, an apt-based OS with reachable mirrors, the
kernel modules the datapath needs, a 1500-byte uplink, that every client VM
falls inside some gateway's `vpn_client_cidr`, and UDP 500 + 4500 in **both**
directions between gateways.

After deploying, the five things worth looking at:

```bash
sudo swanctl --list-sas | grep -o 'ESP:[^ ]*'             # want AES_GCM_16-256
sed -n "/^name .*: rfc4106(gcm(aes))$/,+1p" /proc/crypto  # want a *vaes* driver
cat /sys/class/net/ens3/queues/rx-0/rps_flow_cnt          # want 0
grep XfrmInStateSeqError /proc/net/xfrm_stat              # want flat, not climbing
ethtool -k ens3 | grep generic-receive-offload            # want off
```

`XfrmInStateSeqError` climbing means packets are arriving out of order and
anti-replay is discarding them. Check `rps_flow_cnt` first.

**Measure with one process per flow.** A single `iperf3` server process is
single-threaded and caps out around 4–5 Gbps, which is very easy to mistake
for a network limit. The companion `bandwidth-test` solution collects at the
receiver, one process per flow, so it works through a managed gateway on
either end.

---

## 7. Where the bottleneck sits, before and after

**Before this work, the Crusoe side was the bottleneck.** A gateway delivered
roughly 1.5–2 Gbps per tunnel, against an Azure per-tunnel allowance of 2.3.
Tuning it was not optional — we were the constraint, and no amount of Azure
configuration would have helped.

**After the changes in §4** — kernel 6.11, RFS off, GRO off on the uplink, the
right cipher — one tunnel carries **5.75 Gbps** (measured). That clears
Azure's 2.3 Gbps per-tunnel allowance with room to spare, so the ceiling has
moved off our side and onto Azure's.

The whole-VM figure was measured too, in exactly the shape Azure presents:
**one 8 vCPU gateway VM holding two tunnels to two distinct peer public IPs
carried 8.46 Gbps** of real client traffic over the GRE overlay, with both
tunnels active (the ECMP hash split them 41% / 59% across 24 flows — even
distribution needs more flows than that).

So the same VM that Azure will cap at **4.6 Gbps** is demonstrably good for
**8.46**. That is the gap the sizing in §1 rests on, and it is why adding host
tuning past this point cannot reduce the Azure VM count.

That is what makes the sizing arithmetic in §1 trustworthy:

- Azure caps **2.3 Gbps per tunnel**, and one on-premises device gets **2
  tunnels** (published)
- So **4.6 Gbps per VM**, and `ceil(10 / 4.6)` = **3 VMs**, N+1 = **4**

From here, further host tuning will not reduce that VM count, because the
limit is no longer ours to move. Host tuning buys you fewer VMs only where the
far end has **no per-tunnel cap**: Crusoe to Crusoe, or a peer that terminates
IPsec on general-purpose compute.

One thing would put us back under the cap: **leaving Azure on its default
cipher policy** (§3.1 item 3). At 700 Mbps per tunnel that is 1.4 Gbps per VM,
and 10 Gbps would need **8 VMs** instead of 3.

---

## 8. What was not measured

Stated plainly, so nobody builds on sand.

- **Every Azure number here is published, not measured.** No Azure peer was
  tested.
- **BGP and FRR were never brought up against a real peer.** Since 10 Gbps
  through Azure requires BGP (§3.1 item 5), that path needs validating on
  first use.
- **The `route` transport was never validated end to end.** Crusoe port
  security was on throughout, and a foreign-source packet was confirmed
  dropped by the fabric. `gre_fou` is the tested path and the default.
- The Crusoe-to-Crusoe curve in §1 **is measured**, on the shipped playbook,
  1 through 5 gateways per side. An earlier *derived* estimate in this
  document claimed ~8 Gbps per VM and 2 VMs for 10 Gbps; the measurement
  replaced it with 2.4–4.1 Gbps per VM and 4 VMs. Do not trust arithmetic on
  single-tunnel figures for a GRE deployment.
- Single-tunnel figures are **gateway to gateway**, pure IPsec with no GRE
  leg. Real client traffic through the overlay will be lower.
