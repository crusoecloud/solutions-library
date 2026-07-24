# CLAUDE.md — site-to-site-vpn

Guidance for anyone (human or agent) working on this repo. `README.md` is the
entry point for deploying it.

## What this is

A Crusoe-side, route-based IPsec (IKEv2) + BGP VPN gateway to AWS/GCP, plus an
optional overlay so CMK pods / other Crusoe VMs can reach the peer through the
gateway.

## Layout

- `terraform/crusoe/` — the gateway module (VM(s), firewall, bootstrap). All
  in-guest config (strongSwan/FRR/nftables/XFRM/cluster-egress) is rendered by
  `templates/startup-script.sh.tftpl`, a plain-bash startup script (the Crusoe
  provider takes `startup_script`, not cloud-init).
- `terraform/gcp/`, `terraform/aws/` — optional customer-side modules (dev/test
  and greenfield). Existing AWS Site-to-Site VPN customers follow
  `docs/customer-aws.md` Path A instead.
- `k8s/cluster-egress/` — Helm chart: node-side vxlan overlay DaemonSet.
- `scripts/` — live test suite + shared `lib.sh`.
- `tests/render/` — static template render harness (CI).

## Golden rules

- **No secrets, ever.** PSKs only via `TF_VAR_tunnel_psks`. `*.tfvars` (except
  `params.example.tfvars`), `*.tfstate*`, and `handoff.txt` are gitignored.
- **Templates are the source of truth for in-guest behavior.** Change a
  `.tftpl` and update `tests/render/` so CI still parses it — the harness passes
  the same variables the module passes, so a missing key means an apply-time
  failure.
- **After any Terraform change:** `terraform -chdir=terraform/<mod> fmt &&
  validate`, then `bash tests/render/check.sh` (exit 0). `helm lint
  k8s/cluster-egress` after chart edits.

## Crusoe platform facts

- Provider `registry.terraform.io/crusoecloud/crusoe ~> 0.5.44`.
- Static public IP is inline on the instance:
  `network_interfaces = [{ subnet = ..., public_ipv4 = { type = "static" } }]`.
- `crusoe_vpc_firewall_rule` takes one source CIDR per rule (the module
  product-expands) and normalizes `destination` to `/32` — send it with `/32`
  or the plan drifts.
- The VPC fabric only delivers packets whose destination is the receiving VM;
  there is no VPC route table or source/dest-check toggle. A gateway forwards
  only its own traffic by plain routing — transiting other hosts needs the
  vxlan overlay (`docs/crusoe-cluster-egress.md`).
- First boot: the bootstrap restarts strongSwan/FRR (rather than
  `enable --now`) because apt pre-starts them with stock config, and retries
  `swanctl --load-all` until the vici socket is ready.

## Validation status

See `tests/matrix.md`. GCP single-VM, dual-VM HA, and cluster-egress are
validated live; the AWS path is documented and module-validated.
