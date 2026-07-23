# Site-to-Site VPN Solution — Crusoe ⇄ Cloud (AWS / GCP)

**Claude Code implementation specification**

> **What you are building:** a public, parameterized, reproducible recipe that terminates a hardened, redundant, route-based IPsec (IKEv2) VPN with dynamic BGP routing on the **Crusoe side**, connecting a Crusoe VPC to a customer's **AWS** or **GCP** VPC. The customer provisions their own cloud side; this repo fully owns and automates the Crusoe side and ships the customer side as *optional* Terraform plus documented runbooks. Dev/test validation targets **GCP HA VPN**.

---

## 0. How to use this spec

This document is the single source of truth for the build. Implement in the order of the sections. Each module has an explicit **contract** (inputs/outputs), **acceptance criteria**, and **tests**. Do not invent secrets, cloud accounts, or credentials — everything sensitive is a variable resolved at deploy time. When a value depends on the live cloud provider's current supported-cipher list, treat it as a variable with a documented default, never a hardcoded assumption.

**Guiding constraints (do not violate):**

1. No secrets committed to the repo — ever. PSKs, keys, and account IDs are variables or come from a secret store.
2. The Crusoe-side Terraform and the strongSwan/FRR config templates are **cloud-agnostic**. They consume an abstract *peer list*. Cloud-specific differences live in (a) a per-cloud crypto proposal profile and (b) the customer-side runbook — nowhere else.
3. Route-based + BGP is the default and only fully-supported path. Static/policy-based is documented as a fallback, not implemented as a first-class module.
4. Everything is idempotent. `terraform apply` twice = zero changes. Re-running provisioning scripts converges, never duplicates.
5. Everything is verifiable by a script that exits non-zero on failure.

---

## 1. Goals and non-goals

### Goals
- Reproducible site-to-site VPN from Crusoe to AWS **or** GCP by editing one variables file.
- Route-based IPsec (IKEv2) with BGP dynamic routing and automatic tunnel failover.
- Hardened by default: strong crypto floor, default-deny firewalling, least-privilege reachability, OS hardening.
- Two HA postures selectable by variable: **single-VM quickstart** and **dual-VM HA**.
- A complete test suite: pre-flight, control-plane, data-plane, resilience, security, idempotency, teardown.
- Public-repo quality: pinned versions, a "tested against" matrix, clean docs, no secrets.

### Non-goals (v1)
- No SLA, no managed service, no commercial support.
- No physical/partner interconnect (documented only as the graduation path).
- No provisioning of the customer's intra-cloud topology beyond the single landing VPC (peering / Transit Gateway / NCC are the customer's responsibility; documented, not automated).
- No WireGuard path (AWS/GCP managed VPN gateways cannot terminate it). Note it as a possible future for self-managed-both-ends cases.
- No IKEv1, ever.

---

## 2. Reference architecture

### 2.1 Backbone
- **Crusoe side:** a hardened Ubuntu 24.04 LTS VM (or two, for HA) running:
  - **strongSwan** (charon-systemd + `swanctl`) for IKEv2, route-based via **XFRM interfaces** (`if_id_in` / `if_id_out`). VTI is a documented fallback for older kernels.
  - **FRR** (`bgpd`) for eBGP over the tunnel link-local `/30`s.
  - IP forwarding + host firewall (`nftables`) + kernel hardening sysctls.
- **Tunnel model:** each logical tunnel is `{ peer_public_ip, psk_ref, bgp_inside_cidr /30, local_bgp_ip, remote_bgp_ip, remote_asn, xfrm_if_id }`. The Crusoe side loops over a **list** of these. AWS and GCP both collapse to "a list of length 2" (or a multiple of 2 for scaled HA).
- **Routing:** BGP advertises the Crusoe VPC CIDR(s) and learns the customer CIDR(s). No static route maintenance. ECMP across tunnels where both are up.

### 2.2 Topology (logical)

```
                 Internet (encrypted IKEv2/ESP, NAT-T UDP 4500)
Crusoe VPC                                                   Customer Cloud VPC
+-------------------+         tunnel A (peer IP #1)          +----------------------+
|  workloads        |  <====================================>  |  GCP HA VPN if0 /    |
|  10.CRU.0.0/16    |         tunnel B (peer IP #2)          |  AWS tunnel #1       |
|        |          |  <====================================>  |                      |
|   [strongSwan+FRR]|                                         |  Cloud Router / TGW  |
|   VM(s) w/ pub IP |----BGP over 169.254.x.x/30 per tunnel---|  (BGP, ECMP)         |
+-------------------+                                         +----------------------+
```

Include an ASCII diagram like the above in `docs/architecture.md`, plus a rendered PNG/SVG if a diagram tool is available.

### 2.3 HA postures
- **`ha_mode = "single"` (quickstart):** one Crusoe VM terminating both tunnels. Satisfies the cloud's "two tunnels up" requirement but the VM is a single point of failure. Default for dev/test.
- **`ha_mode = "dual"`:** two Crusoe VMs across fault domains, each terminating one (or half) of the tunnels; maps naturally to GCP's two-interface gateway and to AWS dual-CGW-behind-TGW with ECMP. Default recommendation for production.

The peer-list abstraction and templates MUST support both without structural change — only the count and VM-to-tunnel assignment differ.

---

## 3. Repository layout

```
.
├── README.md                       # what it is, quickstart, tested-against matrix, security notes
├── SPEC.md                         # this file
├── LICENSE                         # permissive (Apache-2.0 or MIT)
├── .gitignore                      # *.tfvars (except *.example), *.tfstate*, .terraform/, secrets
├── .github/
│   └── workflows/
│       └── ci.yml                  # fmt, validate, tflint, tfsec/checkov, template-render dry run
├── docs/
│   ├── architecture.md             # diagrams + design rationale
│   ├── runbook.md                  # deploy → verify → troubleshoot → rotate → teardown
│   ├── customer-gcp.md             # customer-side GCP instructions (their gateway/router)
│   ├── customer-aws.md             # customer-side AWS instructions (TGW/VGW)
│   ├── crypto-profiles.md          # per-cloud proposal profiles + how to update them
│   ├── ip-planning.md              # CIDR allocation, overlap, isolation, multi-tenancy
│   └── outgrowing-this.md          # when to move to interconnect
├── terraform/
│   ├── crusoe/                     # OWNED: the Crusoe side (VM(s), pub IP, firewall, forwarding)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── versions.tf             # pinned provider versions
│   │   ├── cloud-init.yaml.tftpl   # bootstrap: install + render + load
│   │   └── templates/
│   │       ├── swanctl.conf.tftpl
│   │       ├── swanctl-secrets.conf.tftpl
│   │       ├── frr-daemons.tftpl
│   │       └── frr-bgpd.conf.tftpl
│   ├── gcp/                        # OPTIONAL: dev/test customer side (HA VPN + Cloud Router)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── aws/                        # OPTIONAL: customer side (S2S VPN + TGW/VGW)
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
├── params/
│   ├── params.example.tfvars       # the ONE file a new env edits (peer list, ASNs, CIDRs)
│   └── schema.md                   # documented schema for every variable
├── scripts/
│   ├── verify.sh                   # end-to-end control+data plane check, exits non-zero on fail
│   ├── verify-security.sh          # port scan, IKEv1-reject, weak-proposal-reject, PFS check
│   ├── failover-test.sh            # bring a tunnel down, assert traffic continues + reconverge
│   ├── rekey-test.sh               # force IKE/CHILD rekey, assert no data-plane drop
│   ├── mtu-test.sh                 # DF-bit large-packet probe, MSS clamp validation
│   └── lib.sh                      # shared helpers (ssh wrappers, retries, assertions)
└── tests/
    ├── README.md                   # how to run each phase locally and in CI
    └── matrix.md                   # tested-against combinations
```

---

## 4. Variable schema (single source of truth)

Define in `terraform/crusoe/variables.tf` and document in `params/schema.md`. `params/params.example.tfvars` is the copy-and-edit starting point.

### 4.1 Top-level
| Variable | Type | Required | Default | Notes |
|---|---|---|---|---|
| `deployment_name` | string | yes | — | Prefix for all resources; DNS-safe. |
| `cloud` | string | yes | — | `"gcp"` or `"aws"`. Selects the crypto proposal profile default. |
| `ha_mode` | string | no | `"single"` | `"single"` or `"dual"`. |
| `crusoe_vpc_cidrs` | list(string) | yes | — | CIDRs to advertise to the customer via BGP. |
| `crusoe_region` | string | yes | — | Crusoe placement. |
| `local_asn` | number | yes | — | Crusoe-side BGP ASN (private, e.g. 65000). |
| `ssh_allowed_cidrs` | list(string) | yes | — | Management access allow-list. Never `0.0.0.0/0`. |
| `ssh_public_keys` | list(string) | yes | — | Injected via cloud-init. |
| `mss_clamp` | number | no | `1360` | TCP MSS clamp for tunnel path (see §8). |
| `tunnel_mtu` | number | no | `1400` | XFRM interface MTU. |

### 4.2 Peer list (the core abstraction)
```hcl
variable "tunnels" {
  description = "Ordered list of IPsec tunnels; both GCP and AWS map onto this."
  type = list(object({
    name           = string        # e.g. "tunnel-a"
    peer_public_ip = string        # customer VPN endpoint public IP
    psk_var_name   = string        # NAME of the env/secret var holding the PSK (never the PSK itself)
    xfrm_if_id     = number        # unique per tunnel, e.g. 101, 102
    bgp_local_ip   = string        # link-local /30 addr on Crusoe side, e.g. 169.254.21.2
    bgp_remote_ip  = string        # customer BGP peer addr, e.g. 169.254.21.1
    bgp_inside_cidr= string        # the /30, e.g. 169.254.21.0/30
    remote_asn     = number        # customer-side ASN
    vm_index       = number        # which Crusoe VM terminates it (0 for single, 0/1 for dual)
  }))
  validation {
    condition     = length(var.tunnels) >= 1
    error_message = "At least one tunnel is required; two are recommended."
  }
}
```

### 4.3 Crypto proposal profile
```hcl
variable "crypto_profile" {
  description = "IKE and ESP proposals. Default is chosen per-cloud; override to match the provider's current supported list."
  type = object({
    ike_proposals = list(string)   # e.g. ["aes256gcm16-prfsha384-ecp384"]
    esp_proposals = list(string)   # e.g. ["aes256gcm16-ecp384"]
    ike_lifetime  = string         # e.g. "8h"
    esp_lifetime  = string         # e.g. "1h"
    dpd_delay     = string         # e.g. "30s"
    dpd_timeout   = string         # e.g. "120s"
    rekey_margin  = string         # e.g. "3m"
  })
  default = null   # module fills a per-cloud default when null; see §7
}
```

**PSKs are never variables that hold the secret value.** The tunnel object references a *variable name*; the actual PSK is supplied at deploy time via environment (`TF_VAR_...`) or a secret manager data source and written to `/etc/swanctl/conf.d/*.secrets` with mode `0600` by cloud-init. `.gitignore` must exclude any file that could contain a real PSK.

---

## 5. Crusoe Terraform module (`terraform/crusoe/`)

### Contract
**Inputs:** the variables in §4.
**Provisions:**
- 1 VM (`ha_mode=single`) or 2 VMs (`ha_mode=dual`), Ubuntu 24.04 LTS, with a static public IP each.
- Crusoe firewall / security rules: inbound **UDP 500** and **UDP 4500** from each `peer_public_ip/32` only; **SSH (22/tcp)** from `ssh_allowed_cidrs` only; ESP (proto 50) only if NAT-T is disabled (default assumes NAT-T on 4500). Default-deny everything else.
- IP forwarding enabled at the platform level where required.
- Bootstrap via `cloud-init.yaml.tftpl`.

**Outputs:** `crusoe_public_ips` (list), `crusoe_vpc_cidrs`, `local_asn`, and a rendered **customer handoff bundle** (peer IPs to point at, expected inside `/30`s, ASNs, advertised CIDRs) written to a local file `handoff.txt` (no secrets).

### cloud-init bootstrap must:
1. `apt-get` install pinned versions of `strongswan`, `strongswan-swanctl`, `charon-systemd`, `frr`, `nftables`, and test tools (`iperf3`, `tcpdump`, `traceroute`).
2. Apply sysctls (persisted in `/etc/sysctl.d/99-vpn.conf`):
   - `net.ipv4.ip_forward = 1`
   - `net.ipv6.conf.all.forwarding` as appropriate
   - `net.ipv4.conf.all.rp_filter = 2` (loose) to tolerate asymmetric routing across two tunnels; document why.
   - Disable ICMP redirects (`accept_redirects=0`, `send_redirects=0`).
3. Render `swanctl.conf` (connections loop over `var.tunnels`) and secrets file (mode `0600`).
4. Render FRR `daemons` (enable `bgpd`) and `bgpd.conf`.
5. Bring up XFRM interfaces per tunnel (`ip link add ipsec<if_id> type xfrm dev <wan> if_id <if_id>`; set MTU `tunnel_mtu`; `up`), or systemd-networkd equivalents so they persist across reboot.
6. Configure `nftables`: default-deny input, allow established/related, allow SSH from allow-list, allow UDP 500/4500 from peers, allow BGP (TCP 179) only over the tunnel interfaces, and **MSS clamp** on forwarded TCP SYN across the tunnel (`tcp option maxseg size set <mss_clamp>`).
7. `systemctl enable --now strongswan frr nftables`; `swanctl --load-all`.
8. Set strongSwan `start_action = trap` (or `start`) so tunnels re-establish automatically after reboot / on traffic.

### Idempotency
All bootstrap steps converge on re-run. Re-applying Terraform with unchanged inputs produces no resource changes.

---

## 6. Config templates (rendered from variables)

### 6.1 `swanctl.conf.tftpl`
- One `connections.<name>` block per tunnel.
- `version = 2` (IKEv2 only).
- `proposals` / `esp_proposals` from `crypto_profile`.
- `local_ts = 0.0.0.0/0`, `remote_ts = 0.0.0.0/0` (route-based; routing decides, not traffic selectors).
- `if_id_in` / `if_id_out` = `xfrm_if_id`.
- `local.auth = psk`, `remote.auth = psk`; identities = the respective public IPs.
- `dpd_delay`, `rekey_time`, `over_time`/`rand_time` from profile.
- `start_action = trap`.
- `mobike = no` (fixed endpoints).

### 6.2 `swanctl-secrets.conf.tftpl`
- `secrets.ike-<name> { id-... ; secret = <injected PSK> }`. Rendered to a `0600` file, referenced by variable name, sourced at deploy time. Never committed.

### 6.3 `frr-daemons.tftpl`
- `bgpd=yes`; others as needed (`zebra=yes`).

### 6.4 `frr-bgpd.conf.tftpl`
- `router bgp <local_asn>`
- For each tunnel: `neighbor <bgp_remote_ip> remote-as <remote_asn>`, `neighbor <bgp_remote_ip> timers 10 30` (tune), and under `address-family ipv4 unicast`: `neighbor <bgp_remote_ip> activate`.
- Advertise Crusoe CIDRs via `network <cidr>` statements (preferred over blanket `redistribute connected`).
- `maximum-paths` for ECMP across tunnels.
- Inbound/outbound prefix filtering: only accept the customer's expected CIDRs; only advertise `crusoe_vpc_cidrs`. Document as a hardening default (prevents route leaks).

---

## 7. Crypto profiles (`docs/crypto-profiles.md`)

- Ship a **recommended default** that lives in the intersection of AWS and GCP support, and a **per-cloud override**. Recommended starting point (validate against each provider's current published cipher list before trusting in production):
  - IKE: `aes256gcm16-prfsha384-ecp384` (fallback `aes256-sha384-modp2048` for interop).
  - ESP: `aes256gcm16-ecp384` (PFS on).
  - DPD enabled; PFS enabled; IKEv2 only; IKEv1 disabled.
- The module selects a per-cloud default when `crypto_profile == null`, keyed on `var.cloud`.
- Document explicitly: **this list must be checked against the provider's live "supported IKE ciphers" documentation**, because both clouds revise their sets. Treat mismatches as the #1 cause of "IKE won't come up."
- FIPS note: if a customer needs FIPS, document the FIPS-validated strongSwan build path and constrain proposals accordingly (no GCM-only if their policy forbids, etc.). Not implemented in v1, but leave the hook.

---

## 8. MTU / MSS (the classic failure mode)

IPsec + NAT-T overhead breaks large packets silently (ping works, TLS/SSH/large transfers hang). The spec **requires**:
- XFRM interface MTU set to `tunnel_mtu` (default 1400).
- TCP MSS clamping on forwarded traffic to `mss_clamp` (default 1360) via nftables.
- A dedicated MTU test (`scripts/mtu-test.sh`) that sends DF-bit packets at boundary sizes and asserts the clamp works.

---

## 9. IP planning, multi-tenancy, isolation (`docs/ip-planning.md`)

- **CIDR overlap** between the customer VPC, Crusoe VPC, and the BGP link-local `/30`s is the top day-one hazard. Document a required non-overlap check and provide a Terraform `precondition` that fails the plan if `crusoe_vpc_cidrs` overlaps any advertised customer CIDR or any `bgp_inside_cidr`.
- **Per-customer isolation:** each customer deployment is its own state / its own VM(s) / its own routing domain. No shared BGP fabric across customers. Document that plain **VPC peering is non-transitive** on both AWS and GCP: the tunnel reaches only the landing VPC; multi-VPC reach on the customer side requires **AWS Transit Gateway** or **GCP Network Connectivity Center**, which is the customer's responsibility.
- Recommend (don't enforce) a customer CIDR allocation convention; document per-customer NAT as the escape hatch when overlap is unavoidable.

---

## 10. Customer-side modules and docs

### 10.1 GCP (dev/test target) — `terraform/gcp/` + `docs/customer-gcp.md`
Provisions (optional, used for our own testing):
- HA VPN gateway (2 interfaces → 2 external IPs).
- External VPN gateway resource representing Crusoe. For a single Crusoe public IP use a single-interface external gateway (both GCP tunnels may target the same Crusoe IP in dev); for dual-VM HA use a two-interface external gateway.
- Cloud Router with a private ASN.
- Two VPN tunnels (PSK **set by us** per tunnel), each with a BGP session over its `/30`.
- Firewall rules and route advertisement for the GCP VPC CIDR.
Outputs feed straight into `params.tfvars` (`peer_public_ip`, `remote_asn`, inside `/30`s).

### 10.2 AWS — `terraform/aws/` + `docs/customer-aws.md`
Documented primary; module optional. Key deltas to encode:
- One Site-to-Site VPN connection = **2 tunnels, 2 AWS outside IPs, 2 AWS-generated PSKs** (pulled from the connection, injected into our secrets at deploy — never committed).
- BGP inside `/30`s auto-assigned by AWS (or specified).
- Terminate on **Transit Gateway** (preferred, enables ECMP + transitive routing) or VGW.
- The runbook's "your side" section differs from GCP; everything on the Crusoe side is unchanged.

---

## 11. Security hardening checklist (must all be true)

- IKEv2 only; IKEv1 refused. Verified by test.
- Strong proposals only; weak DH/cipher offers rejected. Verified by test.
- PFS on; DPD on; sane rekey.
- Host firewall default-deny; only UDP 500/4500 from peer IPs, SSH from allow-list, BGP only over tunnel interfaces.
- No secrets in repo; secrets files `0600`; PSK handoff out-of-band or via secret manager.
- SSH: key-only, no password auth, no root login; management CIDR allow-list.
- OS auto-security-updates enabled; provider/tool versions pinned and recorded in `tests/matrix.md`.
- Prefix filtering on BGP in both directions (no route leaks).
- Least-privilege reachability documented (which subnets may talk, not "whole VPC ↔ whole VPC").
- Optional upgrade path documented: **certificate-based auth** instead of PSK (run a PKI); FIPS build.

---

## 12. Observability

- strongSwan/charon logs and FRR logs shipped to the platform's logging (or at minimum journald with retention).
- Health signals to alert on: IKE SA down, CHILD_SA missing, BGP session not `Established`, tunnel interface down, packet-loss/latency threshold breach.
- Expose a simple health endpoint or scriptable check (`swanctl --list-sas`, `vtysh -c "show bgp summary"`) that monitoring can poll.
- Metrics to capture: tunnel up/down, BGP state, throughput, rekey events, DPD events.

---

## 13. Runbook (`docs/runbook.md`) — required sections

1. **Prerequisites** — accounts, credentials via env, tools, version pins.
2. **Configure** — copy `params.example.tfvars` → `params.tfvars`, fill peer list/ASNs/CIDRs; supply PSKs via env/secret store.
3. **Deploy Crusoe side** — `terraform apply` in `terraform/crusoe/`; read `handoff.txt`.
4. **Customer side** — point their gateway at the handoff values (GCP/AWS specific pages).
5. **Verify** — run `scripts/verify.sh`; interpret output.
6. **Troubleshoot** — decision tree: IKE won't come up (→ proposal mismatch, PSK, firewall, peer IP), CHILD_SA up but no ping (→ routing/BGP, rp_filter, firewall), ping works but transfers hang (→ MTU/MSS), BGP not established (→ ASN, inside `/30`, TCP 179 over tunnel), one tunnel only (→ HA/ECMP config).
7. **Rotate / rekey** — rotate PSK (or cert), reload `swanctl`, confirm no drop.
8. **Teardown** — `terraform destroy`; confirm clean.

---

## 14. Test specification (the part to get right)

All tests are scripted, exit non-zero on failure, and runnable individually and as a suite. CI runs the static phases on every PR; the live phases run against the GCP dev/test environment.

### Phase 0 — Static / pre-flight (CI, no cloud)
- `terraform fmt -check` and `terraform validate` for all three modules.
- `tflint` clean.
- `tfsec` or `checkov` — no high-severity findings (e.g., `0.0.0.0/0` on SSH must fail).
- Template render dry-run: render `swanctl.conf` and `bgpd.conf` from `params.example.tfvars` and assert required stanzas exist (one connection per tunnel, IKEv2, expected proposals, one BGP neighbor per tunnel).
- Secret-leak scan: assert no PSK-shaped strings and no `*.tfstate`/real `*.tfvars` are tracked by git.
- CIDR-overlap precondition triggers a plan failure when fed overlapping CIDRs (negative test).

### Phase 1 — Provision (GCP dev/test)
- `terraform apply` Crusoe + GCP modules succeeds.
- Assert expected resources exist (VM(s), public IP(s), firewall rules, HA VPN gateway, Cloud Router, 2 tunnels).
- **Idempotency:** immediate second `apply` shows **0 changes** (hard requirement).

### Phase 2 — Control plane
- IKE SA established for every tunnel (`swanctl --list-sas` shows `ESTABLISHED` × N).
- CHILD_SA installed for every tunnel.
- BGP session `Established` on every tunnel (`show bgp summary` on FRR **and** on the Cloud Router side).
- Route propagation both directions: Crusoe learns customer CIDRs; customer learns `crusoe_vpc_cidrs`. Assert prefixes present in each RIB.
- Prefix-filter check: an unexpected prefix is **not** accepted (negative test).

### Phase 3 — Data plane
- ICMP end-to-end (Crusoe workload ↔ customer workload) both directions.
- `iperf3` TCP throughput ≥ a documented floor; UDP loss under a documented ceiling.
- Latency baseline captured and recorded.
- **MTU/MSS:** `ping -M do -s <boundary>` behaves correctly; a large TCP transfer (e.g., ≥10 MB) completes without stalling, proving the MSS clamp. This test must fail if the clamp is removed.

### Phase 4 — Resilience
- **Tunnel failover:** administratively down tunnel A (or drop its peer via firewall). Assert continuous ping loses at most a small, documented number of packets and traffic continues over tunnel B; BGP reconverges within a documented bound. Restore and confirm re-establishment.
- **Rekey survival:** force IKE and CHILD rekey; assert a concurrent transfer/ping sees no drop.
- **Reboot recovery:** reboot the Crusoe VM; assert tunnels and BGP re-establish automatically (validates `start_action`, persisted XFRM interfaces, enabled services).
- (`ha_mode=dual` only) **VM failure:** stop one Crusoe VM; assert the surviving VM/tunnel keeps the connection up.

### Phase 5 — Security
- Port scan the Crusoe public IP: only UDP 500/4500 reachable from a peer source; everything else (incl. SSH from a non-allow-listed source) filtered. Verified with `nmap`/`nc`.
- **IKEv1 rejected:** an IKEv1 initiation fails.
- **Weak proposal rejected:** an initiation offering only weak DH/cipher fails to establish.
- **Wrong PSK rejected:** a peer with the wrong PSK fails authentication.
- **PFS in use:** confirm the negotiated CHILD_SA used the expected DH group.

### Phase 6 — Teardown
- `terraform destroy` on both modules leaves no residual resources.
- Re-`plan` after destroy shows nothing to create against live state (clean).

### Test artifacts
- `scripts/verify.sh` chains Phases 2–3 for a quick "is it working" check.
- Dedicated scripts for Phases 4 and 5 (`failover-test.sh`, `rekey-test.sh`, `mtu-test.sh`, `verify-security.sh`).
- Every script uses `scripts/lib.sh` for SSH, retries with backoff, and assertion helpers; prints a clear PASS/FAIL summary and sets the exit code accordingly.

---

## 15. CI (`.github/workflows/ci.yml`)
- On PR: Phase 0 (fmt, validate, tflint, tfsec/checkov, template render dry-run, secret-leak scan).
- Optional/gated job for live phases against the GCP dev project (requires credentials as CI secrets; skipped on forks).
- Fail the build on any high-severity security finding or any committed secret.

---

## 16. Definition of done
- [ ] A brand-new environment stands up by editing only `params/params.tfvars` + supplying PSKs out-of-band.
- [ ] GCP dev/test path passes Phases 0–6.
- [ ] AWS path documented; `terraform/aws/` renders and validates; crypto profile and PSK-handoff deltas captured.
- [ ] `ha_mode` `single` and `dual` both deploy and pass control/data-plane + relevant resilience tests.
- [ ] Hardening checklist (§11) fully satisfied and verified by Phase 5.
- [ ] No secrets in repo; CI enforces it.
- [ ] `README.md` has quickstart + `tests/matrix.md` "tested against" table with pinned versions.
- [ ] Runbook covers deploy/verify/troubleshoot/rotate/teardown with a working troubleshooting decision tree.

---

## 17. Open parameters to confirm at implementation time
- Crusoe Terraform provider name/resource names and firewall primitives (fill `terraform/crusoe/` against the actual provider; keep the abstraction above intact).
- Whether Crusoe requires explicit "IP forwarding / disable source-dest check" at the platform level (mirror the AWS/GCP concept).
- Exact throughput floor and failover packet-loss/reconvergence bounds to assert (set realistic, documented values from a first baseline run).
- Provider-current supported cipher lists for AWS and GCP (pin `crypto_profile` defaults from live docs at build time).
