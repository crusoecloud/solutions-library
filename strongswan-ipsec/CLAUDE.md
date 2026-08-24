# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Ansible-managed StrongSwan site-to-site IPsec VPN for Crusoe Cloud. Connects
Crusoe VMs and managed K8s clusters to a remote site (datacenter, another Crusoe
region, or public cloud). GRE-over-FOU tunnels handle subnet routing on Crusoe
(bypassing port_security). Supports full tunnel mode where all internet traffic
exits via the remote site's firewall.

## Commands

Ansible (from `ansible/`):
```bash
ansible-playbook -i inventory.ini site.yml                  # Deploy all
ansible-playbook -i inventory.ini site.yml --limit gw-src   # One gateway
ansible-playbook -i inventory.ini site.yml --tags verify     # Verify only
ansible-playbook -i inventory.ini site.yml --tags teardown   # Remove all
```

K8s DaemonSet:
```bash
kubectl apply -f k8s/vpn-client.yaml
```

No build step, no tests, no linting — Ansible + Jinja2 templates + K8s manifest.

## Architecture

Two roles + one DaemonSet:

- **`vpn_gateway`** — Installs StrongSwan, creates XFRM interface for IPsec,
  conditionally sets up multipoint GRE-over-FOU tunnel with neighbor table,
  configures mark-based routing (GRE → xfrm0 via fwmark + table 200),
  iptables forwarding, SNAT for internet egress, and persistence via systemd.

- **`vpn_client`** — Sets up point-to-point GRE-over-FOU tunnel from a Crusoe
  VM to its local gateway, routes configured subnets through it, persistence
  via systemd. Supports multi-CIDR via `vpn_remote_subnets` list.

- **`k8s/vpn-client.yaml`** — DaemonSet that does the same as `vpn_client` but
  for managed K8s nodes. Uses `nicolaka/netshoot` image (public, pullable before
  tunnel is up). Self-heals every 30s.

### The `vpn_use_gre` flag

Controls whether a gateway uses GRE-over-FOU mode (Crusoe, `true`) or direct
IP forwarding (non-Crusoe, `false`). Affects: GRE tunnel creation, neighbor
table, mark-based routing, iptables FORWARD rules, SNAT.

### Mark-based routing (GRE → xfrm0)

For full tunnel (`vpn_remote_subnet: 0.0.0.0/0`), we can't add a `0.0.0.0/0`
route through xfrm0 (would hijack the gateway's default route). Instead:
1. `iptables -t mangle` marks all packets arriving on `gre-vpn` with `0x64`
2. `ip rule fwmark 0x64 lookup 200` routes marked traffic via table 200
3. Table 200 has `default dev xfrm0`
4. The gateway's own default route is unaffected

### SNAT for internet egress

When the remote gateway forwards decrypted VPN traffic to the internet, it
must SNAT to its own IP (port_security on Crusoe, or just standard NAT).
Uses `iptables -t nat POSTROUTING -o <iface> -s <remote-subnet> -j SNAT`.

### Full tunnel (`0.0.0.0/1` + `128.0.0.0/1`)

Client VMs and K8s nodes route `0.0.0.0/1` + `128.0.0.0/1` through the GRE
tunnel instead of `0.0.0.0/0`. This is more specific than the default route,
so it catches all traffic, but the original default route remains as a fallback.
Intra-VPC routes (`/20`, `/24`) are even more specific and still work.

With full tunnel, VMs are only reachable via jump host (SSH through the remote
gateway using private IPs). The inventory uses `ProxyJump` for this.

### Variable hierarchy

1. **`host_vars/gw-*.yml`** — Per-gateway: peer IP, subnets, GRE mode, client CIDR
2. **`group_vars/vpn_gateways.yml`** — Shared: PSK
3. **`group_vars/*_clients.yml`** — Client VMs: gateway host, remote subnets
4. **`roles/vpn_gateway/defaults/main.yml`** — Defaults: GRE key, FOU port, MTU, crypto
5. **`k8s/vpn-client.yaml` ConfigMap** — K8s DaemonSet: gateway IP, remote CIDRs

### Tags

Tasks are tagged `setup`, `verify`, or `teardown`. Teardown tasks also have the
`never` tag — must be explicitly invoked with `--tags teardown`.

### strongswan-starter conflict

Ubuntu installs both `strongswan-starter` (runs `charon`) and `strongswan.service`
(runs `charon-systemd`). They conflict on UDP 500/4500. The playbook disables
`strongswan-starter` before starting `strongswan.service`.
