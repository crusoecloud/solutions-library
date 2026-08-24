# StrongSwan Site-to-Site VPN for Crusoe Cloud

## Overview

Encrypted IPsec VPN between a Crusoe Cloud region and a remote site. The
remote site can be a **customer datacenter**, **another Crusoe region**, or
**Azure**, **GCP**, or **AWS**. Supports both standalone VMs (Ansible) and
managed Kubernetes clusters (DaemonSet).

**Key capabilities:**
- Subnet-to-subnet routing over encrypted IPsec tunnel
- Full tunnel mode — all internet traffic exits via the remote site's firewall
- Managed K8s support — DaemonSet configures nodes automatically, no SSH needed
- GRE-over-FOU overlay bypasses Crusoe's port_security and firewall restrictions

## Architecture

```
      Crusoe Cloud                               Remote Site
  ========================                   ========================

  +--------------------+                     +--------------------+
  | K8s Nodes          | GRE-over-FOU        | VMs / services     |
  | (DaemonSet)        |----+                | (datacenter)       |
  | Standalone VMs     |    |  (UDP 9473)    |                    |
  | (Ansible)          |    |                +--------+-----------+
  +--------------------+    |                         |
                            v                         |
                  +------------+    IPsec    +------------+
                  |   gw-src   |============|   gw-rmt   |
                  | GRE + FOU  |  encrypted | direct fwd |
                  | (Crusoe)   | (UDP 4500) | + SNAT     |
                  +------------+            +------------+
                                                  |
                                            Firewall / Internet
```

### How it works

1. **GRE-over-FOU** wraps GRE inside UDP (port 9473). This bypasses Crusoe's
   SDN port_security (which blocks packets with non-matching source IPs) and
   works through firewalls that only allow TCP/UDP.

2. **Gateway (gw-src)** runs a multipoint GRE-over-FOU tunnel with a
   pre-populated neighbor table covering the entire client CIDR. New VMs
   and K8s nodes are covered automatically.

3. **Standalone VMs** are configured by the `vpn_client` Ansible role —
   point-to-point GRE-over-FOU tunnel to the gateway.

4. **K8s nodes** are configured by the `vpn-client` DaemonSet (`k8s/vpn-client.yaml`) —
   same GRE-over-FOU tunnel, runs as a privileged pod with hostNetwork.

5. **Mark-based routing** on the gateway ensures all GRE-inbound traffic
   is forwarded through xfrm0 into IPsec — even for destinations outside the
   datacenter CIDR (needed for full tunnel mode).

6. **Full tunnel** routes `0.0.0.0/1` + `128.0.0.0/1` through the GRE tunnel.
   These are more specific than the default route (`/0`), so they catch all
   internet traffic while leaving intra-VPC routes (`/20`, `/24`) unaffected.
   The remote gateway SNATs and forwards to the internet.

### Packet flow

```
Crusoe VM / K8s node
  → GRE-over-FOU encap (UDP 9473 to Crusoe gateway)
    → Crusoe gateway marks packet, routes through xfrm0
      → StrongSwan encrypts via IPsec (ESP, UDP 4500)
        → Remote gateway decrypts
          → Datacenter traffic: forwards to LAN
          → Internet traffic: SNATs to gateway IP, forwards to internet
```

---

## Prerequisites

**Crusoe VPC firewall:**

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 500 | UDP | Between gateways (public IPs) | IKE handshake |
| 4500 | UDP | Between gateways (public IPs) | IKE NAT-T (all IPsec traffic) |
| 9473 | UDP | Within VPC (gateway ↔ VMs/nodes) | GRE-over-FOU |

**Remote side firewall:**
- UDP 500 + 4500 inbound from Crusoe gateway public IP
- If non-Crusoe: enable NIC-level IP forwarding (Azure/GCP/AWS)

---

## Quick Start

### 1. Configure gateways and client VMs

```bash
cd ansible

# Gateway IPs and client VMs
vim inventory.ini

# Source gateway (Crusoe) — GRE mode + client CIDR
vim host_vars/gw-src.yml

# Remote gateway — direct mode (or GRE for Crusoe↔Crusoe)
vim host_vars/gw-rmt.yml

# Client VM config — which gateway and which subnets to route
vim group_vars/source_clients.yml

# PSK (generate with: openssl rand -base64 48)
vim group_vars/vpn_gateways.yml
```

### 2. Deploy with Ansible

```bash
ansible-playbook -i inventory.ini site.yml
```

### 3. Deploy K8s DaemonSet (for managed K8s nodes)

```bash
# Edit ConfigMap — set gateway private IP and remote CIDRs
vim k8s/vpn-client.yaml

# Deploy
kubectl apply -f k8s/vpn-client.yaml
```

### 4. Test

```bash
# From a standalone VM
ssh <crusoe-vm> ping <remote-vm-private-ip>

# From a K8s node
kubectl exec -n kube-system ds/vpn-client -- ping -c 3 <remote-vm-private-ip>

# Full tunnel — internet via remote gateway
kubectl exec -n kube-system ds/vpn-client -- ping -c 3 8.8.8.8
```

### Adding a new Crusoe VM

```ini
# Add to inventory.ini:
[source_clients]
vm-s1  ansible_host=<vm-s1-public-ip>
vm-s2  ansible_host=<vm-s2-public-ip>    # new
```

```bash
# Re-run — gateway already covers the CIDR, only the new VM needs config
ansible-playbook -i inventory.ini site.yml
```

K8s nodes need no changes — the DaemonSet auto-configures new nodes.

---

## Full Tunnel Mode

Route all internet traffic through the remote site's firewall.

**Standalone VMs** — set in `group_vars/source_clients.yml`:
```yaml
vpn_remote_subnets:
  - "0.0.0.0/1"
  - "128.0.0.0/1"
```

**K8s nodes** — set in `k8s/vpn-client.yaml` ConfigMap:
```yaml
REMOTE_CIDRS: "0.0.0.0/1 128.0.0.0/1"
```

**Gateway (gw-src)** — `vpn_remote_subnet: "0.0.0.0/0"` in `host_vars/gw-src.yml`

**Remote gateway (gw-rmt)** — `vpn_local_subnet: "0.0.0.0/0"` in `host_vars/gw-rmt.yml`
(must also have internet access and a default route for internet egress)

> **Note**: With full tunnel, VMs are only reachable via jump host (SSH through
> the remote gateway using private IPs). Set `ansible_ssh_common_args` with
> `ProxyJump` in the inventory for ongoing Ansible management. See inventory.ini
> for an example.

---

## Cloud Prerequisites (Remote Side)

When the remote side is Azure, GCP, or AWS, configure these **before**
running the playbook. When both sides are Crusoe, only VPC firewall rules
are needed (see Prerequisites above).

### Azure

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

### GCP

```bash
gcloud compute instances create <gw-vm> --can-ip-forward ...
gcloud compute routes create vpn-to-crusoe \
    --destination-range=<crusoe-private-subnet> \
    --next-hop-instance=<gw-vm> --next-hop-instance-zone=<zone>
```

### AWS

```bash
aws ec2 modify-network-interface-attribute --network-interface-id <eni> --no-source-dest-check
aws ec2 create-route --route-table-id <rt> \
    --destination-cidr-block <crusoe-private-subnet> --network-interface-id <eni>
```

---

## File Structure

```
.
├── README.md
├── CLAUDE.md
├── k8s/
│   └── vpn-client.yaml                     # DaemonSet for K8s nodes (GRE-over-FOU)
└── ansible/
    ├── inventory.ini                        # Gateways + client VMs
    ├── site.yml
    ├── group_vars/
    │   ├── vpn_gateways.yml                # PSK
    │   ├── source_clients.yml              # Source VMs → gw-src
    │   └── remote_clients.yml              # Remote VMs → gw-rmt (Crusoe↔Crusoe)
    ├── host_vars/
    │   ├── gw-src.yml                      # GRE mode, client CIDR
    │   └── gw-rmt.yml                      # Direct or GRE mode
    └── roles/
        ├── vpn_gateway/                    # IPsec + GRE-over-FOU + mark routing
        │   ├── defaults/main.yml
        │   ├── tasks/main.yml
        │   ├── templates/
        │   │   ├── swanctl-vpn.conf.j2
        │   │   ├── sysctl-vpn.conf.j2
        │   │   └── vpn-network.service.j2
        │   └── handlers/main.yml
        └── vpn_client/                     # GRE-over-FOU client (standalone VMs)
            ├── defaults/main.yml
            ├── tasks/main.yml
            ├── templates/vpn-client.service.j2
            └── handlers/main.yml
```

## Key Variables

| Variable | Where | Purpose |
|----------|-------|---------|
| `vpn_psk` | `group_vars/vpn_gateways.yml` | IKE pre-shared key |
| `vpn_use_gre` | `host_vars/gw-*.yml` | `true` for Crusoe (GRE-over-FOU), `false` for direct |
| `vpn_client_cidr` | `host_vars/gw-*.yml` | Subnet of VMs/nodes behind this gateway (GRE mode) |
| `vpn_local_subnet` | `host_vars/gw-*.yml` | IPsec traffic selector (local) |
| `vpn_remote_subnet` | `host_vars/gw-*.yml` | IPsec traffic selector (remote, `0.0.0.0/0` for full tunnel) |
| `vpn_remote_gw_ip` | `host_vars/gw-*.yml` | Remote gateway public IP |
| `vpn_gre_key` | `defaults/main.yml` | GRE key (default: 100) |
| `vpn_fou_port` | `defaults/main.yml` | FOU UDP port (default: 9473) |
| `vpn_gateway_host` | `group_vars/*_clients.yml` | Which gateway the VMs connect to |
| `vpn_remote_subnets` | `group_vars/*_clients.yml` | CIDRs to route through VPN (list, for full tunnel) |
| `GATEWAY_IP` | `k8s/vpn-client.yaml` | Gateway private IP (DaemonSet ConfigMap) |
| `REMOTE_CIDRS` | `k8s/vpn-client.yaml` | CIDRs to route through VPN (DaemonSet ConfigMap) |

## Operations

```bash
ansible-playbook -i inventory.ini site.yml                  # Deploy all
ansible-playbook -i inventory.ini site.yml --limit gw-src   # One gateway
ansible-playbook -i inventory.ini site.yml --tags verify     # Check only
ansible-playbook -i inventory.ini site.yml --tags teardown   # Remove all

kubectl apply -f k8s/vpn-client.yaml                        # Deploy K8s DaemonSet
kubectl rollout restart ds/vpn-client -n kube-system         # Restart DaemonSet
kubectl logs -n kube-system ds/vpn-client                    # Check logs
```

## Troubleshooting

```bash
# --- Gateway ---
sudo swanctl --list-sas                     # IPsec SA status
sudo swanctl --initiate --child site-tunnel # Manually initiate
sudo journalctl -u strongswan -f           # StrongSwan logs
ip tunnel show gre-vpn                     # GRE tunnel status
ip neigh show dev gre-vpn | head           # Neighbor table
ip route show table 100                    # Policy routes (xfrm0 → GRE)
ip route show table 200                    # Mark routes (GRE → xfrm0)
ip rule show                               # Routing rules
sudo iptables -t mangle -L PREROUTING -v -n  # Mark rules
sudo iptables -t nat -L POSTROUTING -v -n    # SNAT rules

# --- Client VM ---
ip tunnel show gre-vpn
ip route show dev gre-vpn
systemctl status vpn-client

# --- K8s DaemonSet ---
kubectl logs -n kube-system ds/vpn-client
kubectl exec -n kube-system ds/vpn-client -- ip tunnel show gre-vpn
kubectl exec -n kube-system ds/vpn-client -- ip route show dev gre-vpn
```

| Symptom | Check |
|---------|-------|
| IKE timeout | Firewall allows UDP 500+4500 between gateway public IPs? |
| Tunnel up, no traffic | Routes through xfrm0? Mark rules in place? (`ip rule show`) |
| FOU packets not arriving | Firewall allows UDP 9473 within VPC? |
| Full tunnel: no internet | Remote gateway has internet access? SNAT rule in place? |
| Full tunnel: SSH lost | Use jump host: `ssh -J user@gw-rmt user@<private-ip>` |
| New VM can't connect | Added to inventory + re-ran playbook? |
| K8s node can't connect | DaemonSet running? `kubectl get ds -n kube-system` |
| strongswan-starter conflict | Ansible disables it; if manual, run `systemctl stop strongswan-starter` |
