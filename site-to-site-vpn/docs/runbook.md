# Runbook

Deploy → verify → troubleshoot → rotate → teardown for the Crusoe side, plus
observability. Customer-side steps live in [customer-gcp.md](customer-gcp.md)
and [customer-aws.md](customer-aws.md).

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| Terraform | >= 1.9 (see `terraform/crusoe/versions.tf`) |
| Crusoe provider | `crusoecloud/crusoe ~> 0.5.44` |
| Crusoe credentials | Configure the provider per Crusoe docs (API token / config file). Never in the repo. |
| Existing Crusoe VPC subnet | The module **consumes** a subnet (`crusoe_vpc_subnet_id`); it does not create VPCs. |
| SSH key pair | Public key(s) go in `ssh_public_keys`; keep the private key for verification scripts. |
| Customer-side access | GCP project or AWS account where the peer gateway will be built. |
| Local tools (tests) | `bash`, `ssh`, `python3`; optionally `tflint`, `trivy` (or `tfsec`), `shellcheck` for Phase 0. |

## 2. Configure

```bash
cp params/params.example.tfvars params/params.tfvars
$EDITOR params/params.tfvars     # tunnels, ASNs, CIDRs, subnet ID, SSH allow-list
```

Fill in: `deployment_name`, `cloud`, `ha_mode`, `crusoe_project_id`,
`crusoe_location`, `crusoe_vpc_subnet_id`, `crusoe_vpc_cidrs`,
`customer_cidrs`, `local_asn`, `ssh_allowed_cidrs`, `ssh_public_keys`, and the
`tunnels` list. See `params/schema.md` for every field.

Supply PSKs **via environment only** — never in a tfvars file:

```bash
export TF_VAR_tunnel_psks='{"PSK_TUNNEL_A":"<psk>","PSK_TUNNEL_B":"<psk>"}'
```

PSKs must be >= 16 chars from `[A-Za-z0-9+/=_.-]`. Generate with, e.g.,
`openssl rand -base64 24 | tr '+/' '_-'`.

> **State warning:** PSKs end up in the rendered startup script, which is
> stored in Terraform state and in Crusoe instance metadata. Encrypt state at
> rest, restrict state access, rotate on suspected exposure.

`params.tfvars` is gitignored; only `params.example.tfvars` is tracked.

## 3. Deploy the Crusoe side

```bash
terraform -chdir=terraform/crusoe init
terraform -chdir=terraform/crusoe plan  -var-file=../../params/params.tfvars
terraform -chdir=terraform/crusoe apply -var-file=../../params/params.tfvars
```

Outputs: `crusoe_public_ips` (customer points tunnels here) and
`handoff_file` — a rendered `handoff.txt` in `terraform/crusoe/` containing
every value the customer needs (endpoint IPs, inside /30s, ASNs, advertised
CIDRs; **no secrets**).

Bootstrap runs on first boot (`/var/log/vpn-bootstrap.log` on the VM);
expect a few minutes before tunnels can establish.

## 4. Customer side

Hand over `handoff.txt` plus the PSKs (out-of-band — see the customer docs),
then follow:

- GCP HA VPN: [docs/customer-gcp.md](customer-gcp.md)
- AWS Site-to-Site VPN: [docs/customer-aws.md](customer-aws.md)

For AWS the PSKs flow the other way (AWS generates them); export them into
`TF_VAR_tunnel_psks` **before** the Crusoe apply.

## 5. Verify

```bash
export VPN_HOST=<crusoe_public_ip>       # from terraform output
export REMOTE_TEST_IP=<customer-side test host private IP>
export VPN_SSH_USER=ubuntu               # default
export VPN_SSH_KEY=~/.ssh/<key>          # optional; else ssh-agent
bash scripts/verify.sh
```

`verify.sh` checks, over SSH: IKE SAs `ESTABLISHED` for every configured
connection, CHILD_SAs `INSTALLED`, all BGP sessions `Established`, BGP routes
in the RIB, ICMP and TCP end-to-end. It prints `PASS`/`FAIL` per check and a
summary; exit code is non-zero on any failure. See `tests/README.md` for the
full phase suite (failover, rekey, MTU, security).

## 6. Troubleshoot (decision tree)

Run everything below **on the VPN VM** (via SSH) with sudo.

### 6.1 IKE won't come up (no `ESTABLISHED` SA)

```bash
sudo swanctl --list-sas          # empty or CONNECTING?
sudo swanctl --list-conns        # config loaded at all?
sudo journalctl -u strongswan -e --no-pager | tail -50
sudo swanctl --log &             # live log, then in another shell:
sudo swanctl --initiate --child tunnel-a
```

Check, in order:

1. **Proposal mismatch** — journal shows `NO_PROPOSAL_CHOSEN`. Compare
   `docs/crypto-profiles.md` against the provider's *current* cipher list;
   override `crypto_profile` if needed. This is the #1 cause.
2. **Wrong PSK** — journal shows `AUTHENTICATION_FAILED`. Confirm
   `TF_VAR_tunnel_psks` keys match `tunnels[*].psk_var_name` and values match
   what the customer gateway holds.
3. **Firewall / no packets arriving** —
   `sudo tcpdump -ni any 'udp port 500 or udp port 4500'`. No inbound
   packets? Check the Crusoe firewall rules (module creates one per
   VM×peer-IP) and that the customer gateway targets the right public IP.
4. **Wrong peer IP / identity** — `remote_addrs` and `remote.id` in
   `/etc/swanctl/conf.d/tunnels.conf` must equal the customer endpoint IP
   from their console (AWS outside IP / GCP interface IP).

### 6.2 CHILD_SA up but no ping across

```bash
sudo swanctl --list-sas | grep -A3 INSTALLED
ip -d link show type xfrm                 # ipsec101/102 UP, correct if_id?
ip addr show ipsec101                     # bgp_local_ip present?
ip route show proto bgp                   # learned customer routes?
sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter
sudo nft list ruleset | less
```

1. **No BGP routes** → go to 6.4; without them, traffic has nowhere to go.
2. **XFRM interface down/missing** →
   `sudo systemctl status vpn-xfrm.service`; re-run
   `sudo /usr/local/sbin/vpn-xfrm-up.sh`.
3. **rp_filter** — must be `2` (loose); strict (`1`) drops asymmetric
   returns across two tunnels.
4. **nftables forward chain** — tunnel interfaces must be accepted both
   directions; `sudo nft list chain inet filter forward`.
5. **Crusoe VPC return route** — workloads in the Crusoe subnet must route
   customer CIDRs via the VPN VM's private IP (platform routing — verify on
   first deploy, see SPEC §17).

### 6.3 Ping works but transfers hang (SSH stalls, TLS times out)

Classic MTU/MSS. The clamp exists precisely for this.

```bash
ping -M do -s 1352 <remote>    # 1352 + 28 = 1380 < 1400: should pass
ping -M do -s 1450 <remote>    # should FAIL (frag needed) — that's correct
sudo nft list ruleset | grep maxseg      # clamp present, both directions?
ip link show ipsec101 | grep mtu         # = tunnel_mtu (1400)
```

Fix: ensure `mss_clamp <= tunnel_mtu - 40` (validated by Terraform), reload
nftables (`sudo systemctl restart nftables`). `bash scripts/mtu-test.sh`
automates the boundary probe.

### 6.4 BGP not Established

```bash
sudo vtysh -c 'show bgp summary'
sudo vtysh -c 'show bgp neighbors <bgp_remote_ip>'
ping -c3 <bgp_remote_ip>                          # inside /30 reachable?
sudo tcpdump -ni ipsec101 tcp port 179
sudo journalctl -u frr -e --no-pager | tail -30
```

1. **/30 unreachable** — CHILD_SA must be INSTALLED first (6.1/6.2); confirm
   `bgp_local_ip` is on the XFRM interface and the customer used the matching
   inside addresses from `handoff.txt`.
2. **ASN mismatch** — `remote_asn` must equal the customer's Cloud Router /
   TGW ASN; `local_asn` must equal what they configured for us.
3. **TCP 179 blocked** — nftables only allows BGP from `bgp_remote_ip` on
   the tunnel interface; a wrong remote IP in params silently blocks it.
4. **Session up, no prefixes** — prefix lists `CUSTOMER-IN` / `CRUSOE-OUT`
   only pass the configured CIDRs. `sudo vtysh -c 'show ip prefix-list'` and
   check `customer_cidrs` / `crusoe_vpc_cidrs` cover what's actually
   advertised.

### 6.5 Only one tunnel carries traffic

```bash
sudo vtysh -c 'show bgp summary'            # both neighbors Established?
ip route show proto bgp                     # two nexthops per prefix (ECMP)?
sudo swanctl --list-sas                     # two ESTABLISHED?
```

- Only one SA → treat the down tunnel as 6.1.
- Both Established but single nexthop → check `maximum-paths` in
  `/etc/frr/frr.conf`, and on GCP that both Cloud Router BGP sessions
  advertise with equal priority (module uses 100 for both); on AWS that the
  TGW has ECMP enabled.
- `ha_mode=dual`: confirm each VM terminates its assigned tunnel
  (`vm_index`) and both VMs are running.

## 7. Rotate / rekey

**Important:** any change to module inputs that alters the rendered startup
script — including `tunnel_psks` — **replaces the VM** (the startup script is
instance metadata). Plan rotations accordingly.

**In-place rotation (zero drop, recommended):**

```bash
ssh ubuntu@<crusoe_public_ip>
sudo vi /etc/swanctl/conf.d/tunnels.secrets.conf   # update the secret= values
sudo swanctl --load-creds                          # load new PSKs
sudo swanctl --rekey --ike <tunnel-name>           # per tunnel; re-auths with new PSK
sudo swanctl --list-sas                            # still ESTABLISHED
```

Update the customer gateway's PSK first (GCP: tunnel shared secret; AWS: modify
VPN tunnel options), then rotate our side. IKEv2 rekey is make-before-break;
`scripts/rekey-test.sh` asserts no data-plane drop.

Then **also** update `TF_VAR_tunnel_psks` so Terraform state matches reality —
but apply that change at the next planned maintenance window, because that
apply replaces the VM. Alternative: schedule the rotation as a VM replacement
(dual-HA absorbs it; single mode takes an outage of roughly boot+bootstrap
time).

Routine IKE/ESP rekeys need no action: lifetimes 8h/1h with 3m margin, DPD
30s, `dpd_action = restart`.

## 8. Teardown

```bash
terraform -chdir=terraform/crusoe destroy -var-file=../../params/params.tfvars
```

Then destroy the customer side (their module/console). Confirm clean:

```bash
terraform -chdir=terraform/crusoe plan -var-file=../../params/params.tfvars
# expect: full re-create plan (nothing dangling), no errors
```

Delete `terraform/crusoe/handoff.txt` if it was copied anywhere, and retire
the PSKs.

## Observability

### Logs

strongSwan (charon) and FRR log to **journald**. The bootstrap caps journal
disk usage at `SystemMaxUse=500M`
(`/etc/systemd/journald.conf.d/vpn.conf`) so logs survive restarts with
bounded retention. Ship them off-host with your log forwarder of choice if
you need longer retention.

```bash
sudo journalctl -u strongswan -f
sudo journalctl -u frr -f
```

### Health endpoint for monitoring

The bootstrap installs `/usr/local/sbin/vpn-healthcheck.sh`. It exits 0 with
`OK: ...` when healthy, non-zero with `CRIT: ...` lines otherwise. Poll it
from your monitoring:

```bash
ssh ubuntu@<vpn_host> sudo /usr/local/sbin/vpn-healthcheck.sh
```

It checks: IKE SAs established >= configured connections, CHILD_SAs
installed, every FRR BGP peer `Established`, every XFRM interface up.

### Alert on

| Signal | Source |
|---|---|
| IKE SA down | healthcheck / `swanctl --list-sas` |
| CHILD_SA missing | healthcheck / `swanctl --list-sas` |
| BGP session not `Established` | healthcheck / `vtysh -c 'show bgp summary json'` |
| Tunnel (XFRM) interface down | healthcheck / `ip link show type xfrm` |
| Packet loss / latency over threshold | your ping/iperf3 probe across the tunnel |

### Metrics worth capturing

- Tunnel up/down (per tunnel), BGP session state (per neighbor)
- Throughput per XFRM interface (`/sys/class/net/ipsecN/statistics/*`)
- Rekey events and DPD events (count of journald matches on
  `rekeying`/`DPD`)
- End-to-end latency and loss from a periodic probe
