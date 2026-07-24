# Crusoe Site-to-Site VPN (AWS / GCP)

Hardened, redundant, **route-based IPsec (IKEv2)** VPN terminating on Crusoe,
with **BGP dynamic routing** and automatic tunnel failover. Crusoe side: one
or two Ubuntu 24.04 VMs running strongSwan (XFRM interfaces) + FRR,
provisioned entirely by Terraform from a single params file. Customer side:
AWS Site-to-Site VPN or GCP HA VPN.

Architecture and rationale: [docs/architecture.md](docs/architecture.md).

## Validation status

| Path | Status |
|---|---|
| **GCP peer, `ha_mode=single`** | ✅ Validated end-to-end (control + data plane, MTU/MSS, failover, rekey, reboot recovery, security) — see [tests/matrix.md](tests/matrix.md) |
| **Cluster egress (CMK) → GCP** | ✅ Validated end-to-end incl. multi-node + node-churn self-heal |
| **AWS peer** | 📄 Documented (existing-VPN Path A + greenfield Path B), module validates; **first live deployment should be guided** — no validated live run yet |
| **`ha_mode=dual`** | ✅ Validated — 2 VMs split the tunnels; stopping one VM keeps the connection up via the survivor (bounded BGP-reconvergence loss) |
| **WireGuard overlay transport, per-pod source identity** | 🗺️ Roadmap ([docs/crusoe-cluster-egress.md](docs/crusoe-cluster-egress.md)) |

"Validated" = run live against real Crusoe + cloud and passing. Everything else
is static-validated (fmt/validate/tflint/tfsec/render) via CI.

## Quickstart

```bash
# 1. configure
cp params/params.example.tfvars params/params.tfvars && $EDITOR params/params.tfvars

# 2. PSKs via env only — never in files
export TF_VAR_tunnel_psks='{"PSK_TUNNEL_A":"<psk>","PSK_TUNNEL_B":"<psk>"}'

# 3. deploy the Crusoe side
terraform -chdir=terraform/crusoe init && \
terraform -chdir=terraform/crusoe apply -var-file=../../params/params.tfvars

# 4. configure the customer side from the generated handoff bundle
cat terraform/crusoe/handoff.txt   # then: docs/customer-gcp.md or docs/customer-aws.md

# 5. verify end-to-end
VPN_HOST=<crusoe_public_ip> REMOTE_TEST_IP=<customer_test_ip> bash scripts/verify.sh
```

Detailed walk-through: [docs/runbook.md](docs/runbook.md).

## How it works (summary)

Each tunnel is one object in a list: peer IP, PSK reference, inside /30,
ASN, XFRM if_id, terminating VM. Terraform renders strongSwan (`swanctl`),
FRR, nftables, and XFRM interface config into the VM startup script. Traffic
selectors are 0/0 — **routing decides**: BGP over per-tunnel 169.254.x.x/30
sessions advertises `crusoe_vpc_cidrs`, learns `customer_cidrs`, ECMPs across
tunnels, and reconverges on failure. Diagram and full rationale in
[docs/architecture.md](docs/architecture.md).

## HA modes

| `ha_mode` | Topology | Use |
|---|---|---|
| `single` (default) | 1 VM terminates both tunnels — tunnel redundancy, VM is a SPOF | dev/test, quickstart |
| `dual` | 2 VMs, tunnels split by `vm_index` — survives VM loss | production |

## Cluster / multi-VM egress through the gateway

By default the gateway carries only its own traffic — Crusoe's VPC fabric drops
packets whose destination isn't the receiving VM, so a plain next-hop route
can't make a VM a transit router. Setting `cluster_egress.enabled = true` plus
deploying the `k8s/cluster-egress` Helm chart lets **CMK pods / nodes and other
Crusoe VMs egress through the gateway** to the peer, via a lightweight vxlan
overlay (the only packets crossing the fabric are real VM-to-VM frames).

Validated live: `terraform apply` (gateway) + `helm install` (nodes) only →
CMK pod → node → overlay → gateway → IPsec tunnel → GCP, 0% loss + 20 MB
transfer.

**Resilient to node churn and node IP changes by design** — nodes are cattle,
the gateway is the fixed anchor:

- New/removed/re-IP'd nodes self-heal with **zero manual action** — the
  DaemonSet auto-covers new nodes and each derives its overlay IP + MAC from its
  own node IP.
- **No per-node gateway config, ever.** Nodes use a deterministic MAC encoding
  their overlay IP; a gateway reconcile loop turns learned forwarding entries
  into neighbor entries, so return traffic resolves without ARP flooding (which
  a learning vxlan hub can't do on Crusoe — no multicast).
- The one non-transparent event is the **gateway** changing IP (only a gateway
  config change does that); mitigate with its static IP and `ha_mode=dual`.

Flags, trade-offs (throughput funnel, per-pod identity, WireGuard roadmap),
and the comparison with the in-cluster `ipsec-tunnel-cmk` chart:
[docs/crusoe-cluster-egress.md](docs/crusoe-cluster-egress.md).

## Security notes

- **No secrets in this repo.** Real `*.tfvars` and state files are
  gitignored; CI includes a secret-leak scan. PSKs are supplied only via
  `TF_VAR_tunnel_psks` at apply time.
- **PSK exposure warning:** PSKs are embedded in the rendered startup
  script, so they are visible in **Terraform state** and in **Crusoe instance
  metadata** to anyone with instance-describe access. Encrypt state at rest,
  restrict access, rotate on suspected exposure
  ([runbook §7](docs/runbook.md#7-rotate--rekey)).
- **PSK handoff is out-of-band** — secret manager or one-time link, never
  email/chat ([customer-aws.md](docs/customer-aws.md)).
- Hardened by default: IKEv2 only, strong crypto floor
  ([docs/crypto-profiles.md](docs/crypto-profiles.md)), default-deny
  firewalls on both the Crusoe network and the host (UDP 500/4500 from peer
  IPs only, SSH allow-listed, BGP only over tunnel interfaces), SSH key-only
  + no root login, BGP prefix filters both directions, unattended security
  upgrades.

## Tested against

See [tests/matrix.md](tests/matrix.md) for pinned versions and run history,
and [tests/README.md](tests/README.md) for how to run all test phases.

## Documentation map

| Doc | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Topology, route-based vs policy-based rationale, HA trade-offs, tunnel model |
| [docs/runbook.md](docs/runbook.md) | Deploy → verify → troubleshoot (decision tree) → rotate → teardown; observability |
| [docs/customer-gcp.md](docs/customer-gcp.md) | Customer-side GCP HA VPN (console + gcloud) |
| [docs/customer-aws.md](docs/customer-aws.md) | Customer-side AWS S2S VPN (CGW/TGW, PSK handoff, inside CIDRs); existing AWS S2S VPN deployments are supported via Path A |
| [docs/crypto-profiles.md](docs/crypto-profiles.md) | Default proposals, overrides, provider cipher-doc warning, FIPS hook |
| [docs/ip-planning.md](docs/ip-planning.md) | CIDR overlap guard, /30 convention, isolation, NAT escape hatch |
| [docs/crusoe-cluster-egress.md](docs/crusoe-cluster-egress.md) | Routing CMK cluster / multi-VM traffic through the gateway; flags, resilience, ipsec-tunnel-cmk comparison |
| [docs/outgrowing-this.md](docs/outgrowing-this.md) | Throughput/SPOF ceilings, interconnect graduation path |
| [params/schema.md](params/schema.md) | Every variable, documented |

## Platform notes

1. **Bash startup script, not cloud-init YAML** — the Crusoe provider takes
   a `startup_script`; templates render into
   `terraform/crusoe/templates/startup-script.sh.tftpl`. Behavior (packages,
   sysctls, rendered configs, services) is equivalent to a cloud-init
   deployment.
2. **VPC/subnet consumed, not created** — the module attaches to an existing
   `crusoe_vpc_subnet_id`; there is no VPC-creation resource in scope.
3. **Day-2 config changes replace the VM** — startup-script changes
   (including PSK rotation via Terraform) recreate the instance. The runbook
   documents a zero-drop **in-place** rotation path
   ([runbook §7](docs/runbook.md#7-rotate--rekey)).
4. **Crusoe VPC fabric forwards only own-destination frames.** Crusoe's VPC
   fabric drops packets whose destination IP is not the receiving VM's own IP.
   There is no "disable source/dest check" or user-managed VPC route primitive
   in the Crusoe CLI or Terraform provider. A gateway VM therefore forwards
   only its **own** traffic by plain routing; routing other hosts' traffic
   through the gateway requires the vxlan overlay described in
   [docs/crusoe-cluster-egress.md](docs/crusoe-cluster-egress.md)
   (`cluster_egress`). This is a Crusoe platform property, not a
   configuration gap.

## License

See [LICENSE](LICENSE).
