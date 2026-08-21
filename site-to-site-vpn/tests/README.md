# Test suite

Six phases: Phase 0 is static (local + CI, no cloud). Phases 1–6
run against a live deployment — the reference target is the `terraform/gcp/`
dev/test module. Every script exits non-zero on failure and prints a
PASS/FAIL summary.

## Phase 0 — static / pre-flight (no cloud, run from repo root)

```bash
# format + validate all three modules
terraform fmt -check -recursive terraform
for d in terraform/crusoe terraform/gcp terraform/aws; do
  terraform -chdir=$d init -backend=false -input=false
  terraform -chdir=$d validate
done

# linters / security scanners (install separately)
tflint --chdir=terraform/crusoe && tflint --chdir=terraform/gcp && tflint --chdir=terraform/aws
trivy config terraform/   # CI runs this (HIGH,CRITICAL fail the build); tfsec works too

# template render dry-run: renders swanctl/frr/nftables from
# params.example.tfvars values and asserts required stanzas
bash tests/render/check.sh

# shell lint
shellcheck scripts/*.sh

# secret-leak scan: no tfstate or real tfvars tracked
git ls-files | grep -E '\.(tfstate|tfvars)$' | grep -v example && echo LEAK || echo clean
```

### Negative test: CIDR-overlap guard

Feed the Crusoe module a `customer_cidrs` that collides with
`crusoe_vpc_cidrs` from the example params and confirm the plan **fails**:

```bash
terraform -chdir=terraform/crusoe plan -var-file=../../params/params.example.tfvars \
  -var 'customer_cidrs=["10.100.0.0/16"]' \
  -var 'tunnel_psks={PSK_TUNNEL_A="xxxxxxxxxxxxxxxx",PSK_TUNNEL_B="xxxxxxxxxxxxxxxx"}'
# EXPECTED: plan fails with "CIDR overlap detected..."
```

A plan that succeeds here is a test failure.

> Note: Terraform configures the Crusoe provider before evaluating
> preconditions, so this test requires valid Crusoe credentials (env or
> `~/.crusoe/config`) even though it never creates resources.

## Environment for live phases (1–6)

All live-phase scripts source `scripts/lib.sh` and use these env vars:

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `VPN_HOST` | yes | — | Crusoe VPN VM public IP (from `terraform output crusoe_public_ips`) |
| `REMOTE_TEST_IP` | yes (2–4) | — | Private IP of a test host on the customer side (e.g., a VM in the GCP test subnet) |
| `VPN_SSH_USER` | no | `ubuntu` | SSH user on the VPN VM |
| `VPN_SSH_KEY` | no | ssh-agent | Private key path for SSH |
| `VPN_SSH_VIA` | no | `0` | Set to `1` to run the on-box SSH assertions in `verify-security.sh` (requires allow-listed SSH access to `VPN_HOST`) |
| `TUNNEL_A_NAME` | no | `tunnel-a` | Tunnel targeted by the failover and rekey tests |
| `TUNNEL_A_IF_ID` | yes (failover) | — | XFRM interface ID of tunnel A (e.g. `101`); must match `xfrm_if_id` in Terraform config |
| `MAX_LOSS_PCT` | no | script default | Max acceptable ping loss during failover |
| `RECONVERGE_TIMEOUT` | no | script default | Seconds allowed for BGP reconvergence |
| `TUNNEL_MTU` | no | `1400` | Expected tunnel MTU for boundary probes |
| `TRANSFER_URL` | no | — | HTTP URL through the tunnel for the large-transfer proof (e.g. `http://<remote>:5201/blob` from `python3 -m http.server`); used when no iperf3 server runs remotely |
| `CALLER_ALLOWLISTED` | no | `0` | Set to `1` when running `verify-security.sh` from an IP in `ssh_allowed_cidrs`: skips the SSH-filtered probe and instead asserts nothing but :22 is open |

Note: probes originated **on** the VPN VM are source-bound (`-I <vpc-ip>`) by
the scripts — VM-originated traffic otherwise sources from the 169.254 tunnel
address, which the peer side rightly filters. Forwarded workload traffic is
unaffected.

## Phase 1 — provision (GCP dev/test)

Order matters (GCP gateway IPs feed the Crusoe params; PSKs feed both):

```bash
# 1. GCP side first (creates HA VPN gateway -> two public IPs)
terraform -chdir=terraform/gcp init
terraform -chdir=terraform/gcp apply   # supply project_id, crusoe_asn, PSKs, /30s

# 2. Feed outputs into params/params.tfvars:
terraform -chdir=terraform/gcp output gcp_vpn_public_ips   # -> tunnels[*].peer_public_ip
terraform -chdir=terraform/gcp output gcp_asn              # -> tunnels[*].remote_asn

# 3. Crusoe side (same PSKs via env)
export TF_VAR_tunnel_psks='{"PSK_TUNNEL_A":"...","PSK_TUNNEL_B":"..."}'
terraform -chdir=terraform/crusoe init
terraform -chdir=terraform/crusoe apply -var-file=../../params/params.tfvars

# 4. Idempotency (hard requirement): second apply = 0 changes
terraform -chdir=terraform/crusoe plan -var-file=../../params/params.tfvars -detailed-exitcode
# EXPECTED: exit 0 ("No changes")
```

Expected: VM(s) + static public IP(s) + firewall rules on Crusoe; HA VPN
gateway, external gateway, Cloud Router, 2 tunnels on GCP.

## Phases 2–3 — control plane + data plane

```bash
export VPN_HOST=... REMOTE_TEST_IP=...
bash scripts/verify.sh
```

Covers: IKE SAs `ESTABLISHED` (all tunnels), CHILD_SAs `INSTALLED`, all BGP
sessions `Established`, BGP routes in the RIB, ICMP end-to-end, TCP path.
Expected output: `PASS:` per check, summary line, exit 0. Also verify the
GCP side: `gcloud compute routers get-status` shows `Established`, and
tunnels report `ESTABLISHED`. Throughput/latency baseline: run `iperf3`
between test hosts and record in `tests/matrix.md`.

## Phase 4 — resilience

```bash
bash scripts/failover-test.sh   # downs $TUNNEL_A_NAME, asserts loss <= $MAX_LOSS_PCT,
                                # BGP reconverges within $RECONVERGE_TIMEOUT, restores
bash scripts/rekey-test.sh      # forces IKE+CHILD rekey under traffic, asserts no drop
```

Reboot recovery: reboot the VPN VM, wait, re-run `scripts/verify.sh`
(validates `start_action = trap`, persisted XFRM unit, enabled services).
For `ha_mode=dual`, additionally stop one VM and re-run `verify.sh` against
the survivor.

## Phase 5 — security

```bash
bash scripts/verify-security.sh # port posture, IKEv1 reject, weak-proposal reject,
                                # wrong-PSK reject, PFS group check
bash scripts/mtu-test.sh        # DF-bit probes around $TUNNEL_MTU, MSS clamp proof
```

Expected: from a non-peer, non-allow-listed source only UDP 500/4500
filtered/closed behavior consistent with default-deny; IKEv1 and weak
proposals refuse to establish; large TCP transfer completes (clamp works).

## Phase 6 — teardown

```bash
terraform -chdir=terraform/crusoe destroy -var-file=../../params/params.tfvars
terraform -chdir=terraform/gcp destroy
# clean check: nothing left behind
terraform -chdir=terraform/crusoe plan -var-file=../../params/params.tfvars
```

## Script ↔ phase map

| Script | Phases |
|---|---|
| `tests/render/check.sh` | 0 |
| `scripts/verify.sh` | 2–3 (quick "is it working") |
| `scripts/failover-test.sh` | 4 |
| `scripts/rekey-test.sh` | 4 |
| `scripts/mtu-test.sh` | 3/5 (MSS clamp) |
| `scripts/verify-security.sh` | 5 |

Record every full run (pass or fail) in [`tests/matrix.md`](matrix.md).
