# CLAUDE.md — site-to-site-vpn

Working notes for this repo. Read before making changes.

## What this is

Crusoe-side, route-based IPsec (IKEv2) + BGP VPN gateway to AWS/GCP, plus an
optional cluster-egress overlay so CMK pods/VMs can reach the peer through the
gateway. `SPEC.md` is the design spec; `README.md` is the entry point.

## Layout

- `terraform/crusoe/` — the owned gateway module (VM(s), firewall, bootstrap).
  All in-guest config (strongSwan/FRR/nftables/XFRM/cluster-egress) is rendered
  by `templates/startup-script.sh.tftpl`, which is a **plain bash** startup
  script (not cloud-init — the Crusoe provider takes `startup_script`).
- `terraform/gcp/`, `terraform/aws/` — optional customer-side modules (dev/test
  + greenfield). Existing AWS S2S VPN customers use `docs/customer-aws.md` Path A.
- `k8s/cluster-egress/` — Helm chart: node-side vxlan overlay DaemonSet.
- `scripts/` — live test suite (`verify`, `mtu-test`, `failover-test`,
  `rekey-test`, `verify-security`, `healthcheck`, shared `lib.sh`).
- `tests/render/` — static template render harness (CI phase 0).

## Golden rules

- **No secrets, ever.** PSKs only via `TF_VAR_tunnel_psks` env. `*.tfvars`
  (except `params.example.tfvars`), `*.tfstate*`, `handoff.txt` are gitignored.
  Never commit a real tfvars or a PSK.
- **Templates are the source of truth for in-guest behavior.** If you change a
  `.tftpl`, update the render harness (`tests/render/`) so CI still parses it —
  the harness passes the *same* variable set the real module passes; a missing
  key there means the module would fail at apply.
- **After any TF change:** `terraform -chdir=terraform/<mod> fmt && validate`,
  and `bash tests/render/check.sh` (exit 0). `helm lint k8s/cluster-egress`
  after chart edits.
- **Commits are SSH-signed.** Do NOT add a `Co-Authored-By` / model-attribution
  trailer to commits, PRs, or comments.

## Environment quirks (learned the hard way)

- **Terraform provider plugins can't run inside the sandbox** — `validate`,
  `init`, `apply`, `plan` need `dangerouslyDisableSandbox: true`. So do live
  `crusoe`/`gcloud`/`ssh` calls (TLS + sockets).
- **Commit signing** uses the 1Password SSH agent:
  `SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"`.
  It fails with "failed to fill whole buffer" if the 1Password prompt is
  unanswered — retry when the user is active.
- **Any gateway config change replaces the VM** (new public + private IP). That
  means: update the GCP/AWS peer's endpoint, and the cluster-egress Helm
  `gateways` value, after every rebuild. PSK rotation has a zero-drop in-place
  path (runbook §7) that avoids the rebuild.
- **SSH allow-list is a `/32`** — if your egress IP changes you lock yourself
  out of the gateway (host nftables bakes the allowed IP at boot); fixing it
  needs a rebuild (or a temporary Crusoe firewall rule won't help — the host
  firewall is the gate).

## Crusoe platform facts

- Provider: `registry.terraform.io/crusoecloud/crusoe ~> 0.5.44`.
- `crusoe_compute_instance` inline static public IP:
  `network_interfaces = [{ subnet = ..., public_ipv4 = { type = "static" } }]`.
- `crusoe_vpc_firewall_rule` takes **one source CIDR per rule** (module does
  product-expansion) and normalizes `destination` to `/32` (send it with `/32`
  or the plan perpetually drifts).
- **The VPC fabric drops foreign-destination frames** — a VM only receives
  packets addressed to itself. No VPC route table, no source/dest-check toggle.
  This is why cluster egress needs the vxlan overlay
  (`docs/crusoe-cluster-egress.md`), and why a plain gateway forwards only its
  own traffic.
- `apt` / `systemd` on first boot: the bootstrap **restarts** strongswan/frr
  (not `enable --now`) because apt pre-starts them with stock config, and it
  retries `swanctl --load-all` (the vici socket comes up async).

## Live E2E status

GCP path validated through phases 0–5 (see `tests/matrix.md`). Cluster-egress
single-node validated end to end; multi-node uses the deterministic-neighbor
mechanism (see `docs/crusoe-cluster-egress.md` "Resilience"). AWS path is
documented (Path A / Path B), not yet run live.
