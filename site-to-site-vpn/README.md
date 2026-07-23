# Crusoe Site-to-Site VPN (AWS / GCP)

Hardened, redundant, **route-based IPsec (IKEv2)** VPN terminating on Crusoe,
with **BGP dynamic routing** and automatic tunnel failover. Crusoe side: one
or two Ubuntu 24.04 VMs running strongSwan (XFRM interfaces) + FRR,
provisioned entirely by Terraform from a single params file. Customer side:
AWS Site-to-Site VPN or GCP HA VPN.

Full design spec: [SPEC.md](SPEC.md). Architecture and rationale:
[docs/architecture.md](docs/architecture.md).

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
| [docs/customer-aws.md](docs/customer-aws.md) | Customer-side AWS S2S VPN (CGW/TGW, PSK handoff, inside CIDRs) |
| [docs/crypto-profiles.md](docs/crypto-profiles.md) | Default proposals, overrides, provider cipher-doc warning, FIPS hook |
| [docs/ip-planning.md](docs/ip-planning.md) | CIDR overlap guard, /30 convention, isolation, NAT escape hatch |
| [docs/outgrowing-this.md](docs/outgrowing-this.md) | Throughput/SPOF ceilings, interconnect graduation path |
| [params/schema.md](params/schema.md) | Every variable, documented |
| [SPEC.md](SPEC.md) | The full design specification this repo implements |

## Deliberate deviations from SPEC.md

1. **Bash startup script, not cloud-init YAML** — the Crusoe provider takes
   a `startup_script`; templates render into
   `terraform/crusoe/templates/startup-script.sh.tftpl` instead of
   `cloud-init.yaml.tftpl`. Behavior (packages, sysctls, rendered configs,
   services) is as specified.
2. **VPC/subnet consumed, not created** — the module attaches to an existing
   `crusoe_vpc_subnet_id`; there is no VPC-creation resource in scope.
3. **Day-2 config changes replace the VM** — startup-script changes
   (including PSK rotation via Terraform) recreate the instance. The runbook
   documents a zero-drop **in-place** rotation path
   ([runbook §7](docs/runbook.md#7-rotate--rekey)).
4. **Platform-level IP forwarding (SPEC §17) is an open question** — whether
   Crusoe requires an AWS/GCP-style "disable source/dest check" toggle is
   pending validation at the first live deploy; host-level forwarding and
   return-routing are configured, platform behavior will be recorded in
   `tests/matrix.md`.

## License

See [LICENSE](LICENSE).
