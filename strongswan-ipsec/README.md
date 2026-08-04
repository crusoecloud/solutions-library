# StrongSwan Site-to-Site VPN for Crusoe Cloud

## Overview

Encrypted IPsec VPN between a Crusoe Cloud region and a remote site. The
remote site can be **another Crusoe region**, or **Azure**, **GCP**, or **AWS**.
VMs on both sides communicate using their **real IP addresses** — fully
transparent, no NAT. Managed entirely via Ansible.

## Deployment Scenarios

| Scenario | Crusoe side | Remote side |
|----------|-----------|-------------|
| Crusoe ↔ Azure/GCP/AWS | FOU mode, VMs in Ansible inventory | Direct forwarding, no VM config |
| Crusoe ↔ Crusoe | FOU mode on both sides, all VMs in inventory | FOU mode on both sides |

## Architecture

### Crusoe ↔ External Cloud (Azure / GCP / AWS)

```
      Crusoe Cloud                               Azure / GCP / AWS
  ========================                   ========================

  +--------------------+                     +--------------------+
  | VMs in             | GRE-over-FOU        | VMs in             |
  | <src-subnet>     |----+                | <cloud-vpc-cidr>        |
  | (Ansible-managed)  |    |  (UDP 9473)    | (no config needed) |
  +--------------------+    |                +--------+-----------+
                            v                         |
                  +------------+    IPsec    +------------+
                  |   gw-src   |============|   gw-rmt   |
                  | FOU mode   |  encrypted | direct fwd |
                  | (Crusoe)   | (UDP 4500) | (cloud NIC |
                  +------------+            |  toggle)   |
                                            +------------+
```

- **Crusoe side**: FOU tunnels between gateway and VMs (port_security workaround)
- **Remote side**: Standard IP forwarding — cloud NIC-level flag handles it
- **IPsec between gateways**: Encrypted tunnel carrying the private subnet traffic
- **FOU is only needed on the Crusoe side**

### Crusoe ↔ Crusoe

```
      Crusoe Region A                           Crusoe Region B
  ========================                   ========================

  +--------------------+                     +--------------------+
  | VMs in             | GRE-over-FOU        | VMs in             |
  | <src-subnet>     |----+         +------| <rmt-subnet>     |
  | (Ansible-managed)  |    |         |      | (Ansible-managed)  |
  +--------------------+    v         v      +--------------------+
                  +------------+  IPsec   +------------+
                  |   gw-src   |==========|   gw-rmt   |
                  | FOU mode   | encrypted| FOU mode   |
                  +------------+          +------------+
```

Both sides use FOU. Both sides have client VMs in the Ansible inventory.

### How GRE-over-FOU works with port_security

Crusoe's SDN fabric port_security blocks any packet whose source IP doesn't match
the VM's assigned address. **GRE-over-FOU** (Foo-over-UDP) solves this by
wrapping GRE inside UDP:

1. The gateway wraps decrypted packets in GRE+UDP with its own IP as
   outer source — port_security allows it.
2. The client VM receives the UDP packet, strips the FOU/GRE headers,
   and sees the original packet with the real remote source IP.

We use FOU (UDP port 9473) instead of raw GRE because Crusoe's firewall
rules support only TCP and UDP but not raw IP protocol 47 (GRE). FOU wraps GRE inside
a standard UDP packet, passing cleanly through any firewall.

The gateway uses a **single multipoint GRE-over-FOU tunnel** for the
entire client subnet, with a pre-populated neighbor table.

Azure, GCP, and AWS provide per-NIC IP-forwarding toggles that bypass the
source IP check entirely, so FOU is not needed on those platforms. Only
the Crusoe side needs FOU.

### Packet flow: Crusoe ↔ Azure/GCP/AWS

```
Crusoe VM (src-private-ip)
  → FOU encap (UDP 9473 to Crusoe GW)
    → Crusoe GW decaps FOU, encrypts with IPsec
      → ESP (UDP 4500 NAT-T to remote GW)
        → Remote GW decrypts, forwards directly to local subnet
          → Remote VM (rmt-private-ip) sees real src=src-private-ip

Remote VM (rmt-private-ip)
  → Routed to remote GW via cloud UDR/route table
    → Remote GW encrypts with IPsec
      → ESP to Crusoe GW
        → Crusoe GW decrypts, FOU encap to Crusoe VM
          → Crusoe VM sees real src=rmt-private-ip
```

No FOU on the remote side — the cloud NIC IP-forwarding flag allows the
gateway to forward packets with any source IP directly to the local subnet.

---

## Quick Start

```bash
cd ansible

# 1. Edit inventory — gateway public IPs and Crusoe client VM public IPs
vim inventory.ini

# 2. Set gateway config — remote peer IP, private subnet CIDRs, FOU mode
vim host_vars/gw-src.yml        # vpn_remote_gw_ip, vpn_local_subnet,
                                # vpn_remote_subnet, vpn_client_cidr
vim host_vars/gw-rmt.yml        # Same, plus vpn_use_gre (false for cloud,
                                # true for Crusoe)

# 3. Set client VM config — which gateway and which remote subnet to route
vim group_vars/source_clients.yml   # vpn_gateway_host, vpn_remote_subnet

# 4. Set PSK (generate with: openssl rand -base64 48)
#    For production, encrypt with: ansible-vault encrypt group_vars/vpn_gateways.yml
vim group_vars/vpn_gateways.yml     # vpn_psk (only setting required here)

# 5. Crusoe↔Crusoe only: edit remote client VM config
#    Skip this step if the remote side is Azure/GCP/AWS.
# vim group_vars/remote_clients.yml  # vpn_gateway_host, vpn_remote_subnet

# 6. For Azure/GCP/AWS: complete cloud prerequisites first (see below)

# 7. Deploy everything — gateways + client VMs
ansible-playbook -i inventory.ini site.yml

# 8. Test
ssh <crusoe-vm> ping <remote-vm-private-ip>
ssh <remote-vm> ping <crusoe-vm-private-ip>
```

### Adding a new Crusoe VM

```ini
# Add one line to inventory.ini:
[source_clients]
vm-s1  ansible_host=<vm-s1-public-ip>
vm-s2  ansible_host=<vm-s2-public-ip>    # new
```

```bash
# Re-run — Ansible configures the new VM
ansible-playbook -i inventory.ini site.yml
```

The gateway already handles the entire CIDR (multipoint FOU tunnel), so
only the new client VM needs configuring.

---

## Cloud Prerequisites (Remote Side)

When the remote side is Azure, GCP, or AWS, configure these **before**
running the playbook. When both sides are Crusoe, skip to the Crusoe section.

### Azure

```bash
# 1. Enable IP forwarding on the gateway NIC
az network nic update \
    --resource-group <rg> --name <gw-nic> --ip-forwarding true

# 2. Create route table + route for Crusoe private subnet
az network route-table create --resource-group <rg> --name vpn-to-crusoe --location <loc>

az network route-table route create \
    --resource-group <rg> --route-table-name vpn-to-crusoe --name to-crusoe \
    --address-prefix <crusoe-private-subnet> \
    --next-hop-type VirtualAppliance --next-hop-ip-address <gw-private-ip>

az network vnet subnet update \
    --resource-group <rg> --vnet-name <vnet> --name <subnet> \
    --route-table vpn-to-crusoe

# 3. NSG rules — allow IKE + ESP from Crusoe gateway public IP
az network nsg rule create --resource-group <rg> --nsg-name <nsg> \
    --name Allow-IKE --priority 100 --direction Inbound --access Allow \
    --protocol Udp --source-address-prefixes <crusoe-gw-public-ip>/32 \
    --destination-port-ranges 500

az network nsg rule create --resource-group <rg> --nsg-name <nsg> \
    --name Allow-IKE-NAT --priority 110 --direction Inbound --access Allow \
    --protocol Udp --source-address-prefixes <crusoe-gw-public-ip>/32 \
    --destination-port-ranges 4500

az network nsg rule create --resource-group <rg> --nsg-name <nsg> \
    --name Allow-ESP --priority 120 --direction Inbound --access Allow \
    --protocol Esp --source-address-prefixes <crusoe-gw-public-ip>/32 \
    --destination-port-ranges '*'
```

> **Gotchas**: Both NIC IP-forwarding AND OS-level `ip_forward` (set by
> Ansible) are required. NSGs are evaluated on both subnet and NIC. Associate
> the route table with every subnet that needs VPN access.

### GCP

```bash
# 1. Enable IP forwarding (must be set at VM creation — immutable)
gcloud compute instances create <gw-vm> --zone=<zone> --can-ip-forward \
    --machine-type=<type> --image-family=<family> --image-project=<project> \
    --network=<vpc> --subnet=<subnet>

# 2. VPC route
gcloud compute routes create vpn-to-crusoe \
    --network=<vpc> --destination-range=<crusoe-private-subnet> \
    --next-hop-instance=<gw-vm> --next-hop-instance-zone=<zone> --priority=1000

# 3. Firewall rule — allow IKE + ESP from Crusoe gateway public IP
gcloud compute firewall-rules create allow-ipsec-from-crusoe \
    --network=<vpc> --direction=INGRESS --action=ALLOW \
    --rules=udp:500,udp:4500,esp \
    --source-ranges=<crusoe-gw-public-ip>/32 --target-tags=<gw-tag>
```

> **Gotchas**: `canIpForward` is immutable — VM must be recreated if not set
> at creation. Routes are VPC-wide by default; use `--tags` to scope. Zone
> is required in the route command.

### AWS

```bash
# 1. Disable source/dest check on gateway ENI
ENI_ID=$(aws ec2 describe-instances --instance-ids <id> \
    --query "Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId" \
    --output text)
aws ec2 modify-network-interface-attribute \
    --network-interface-id $ENI_ID --no-source-dest-check

# 2. VPC route table entry
RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=<subnet-id>" \
    --query "RouteTables[0].RouteTableId" --output text)
aws ec2 create-route --route-table-id $RT_ID \
    --destination-cidr-block <crusoe-private-subnet> --network-interface-id $ENI_ID

# 3. Security group rules — allow IKE + ESP from Crusoe gateway public IP
aws ec2 authorize-security-group-ingress --group-id <sg-id> --ip-permissions \
    "IpProtocol=udp,FromPort=500,ToPort=500,IpRanges=[{CidrIp=<crusoe-gw-public-ip>/32}]" \
    "IpProtocol=udp,FromPort=4500,ToPort=4500,IpRanges=[{CidrIp=<crusoe-gw-public-ip>/32}]" \
    "IpProtocol=50,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=<crusoe-gw-public-ip>/32}]"
```

> **Gotchas**: Use ENI ID (not instance ID) as route target. ESP is protocol
> `50` (numeric only). `FromPort=-1,ToPort=-1` required for ESP. Add routes
> to every subnet's route table.

### Crusoe ↔ Crusoe

No cloud-level IP-forwarding or route tables needed. Configure the following
firewall rules on the Crusoe VPC. These rules apply to **both** regions
(source and destination gateways should both be in the VPC).

**Ingress Rules:**

| Name | Protocol | Src Ports | Source | Dst Ports | Destination | Purpose |
|------|----------|-----------|--------|-----------|-------------|---------|
| allow-500-strongswan | UDP | * | \<gw-src-public-ip\>/32, \<gw-rmt-public-ip\>/32 | 500 | crusoe-vpc | IKE initial handshake |
| allow-4500-strongswan | UDP | * | \<gw-src-public-ip\>/32, \<gw-rmt-public-ip\>/32 | 4500 | crusoe-vpc | IKE NAT-T (all ongoing traffic) |
| allow-9473 | UDP | * | crusoe-vpc | * | crusoe-vpc | GRE-over-FOU between gateways and client VMs |

**Egress Rules:**

| Name | Protocol | Src Ports | Source | Dst Ports | Destination | Purpose |
|------|----------|-----------|--------|-----------|-------------|---------|
| allow-all-external | TCP, UDP | * | crusoe-vpc | * | 0.0.0.0/0 | All outbound TCP/UDP |
| allow-icmp-external | ICMP | | crusoe-vpc | | 0.0.0.0/0 | Outbound ICMP |

> **Why ports 500 and 4500?** Port 500 is used for the initial IKE handshake,
> which includes NAT detection. Once both gateways detect they are behind NAT
> (Crusoe maps private IPs to public IPs), all subsequent IKE and ESP traffic
> automatically switches to port 4500 (NAT-Traversal). Both ports must be open
> because the initial discovery on 500 must succeed before the switch to 4500.

> **Why port 9473?** This is the FOU (Foo-over-UDP) port used to wrap GRE
> packets in UDP between each gateway and its local client VMs. It is local
> traffic within each region, not cross-region.

### Crusoe ↔ Azure/GCP/AWS

On the **Crusoe side**, configure the same firewall rules as above.

On the **remote cloud side**: configure firewall/NSG/SG as shown in the
provider sections above (UDP 500/4500 + ESP from Crusoe GW public IP/32).
No FOU rules needed on the remote side — only the Crusoe side uses FOU.

---

## Provider Comparison

| | Crusoe | Azure | GCP | AWS |
|-|--------|-------|-----|-----|
| IP forwarding | N/A (use FOU) | Per-NIC (mutable) | Per-VM at creation (**immutable**) | Per-ENI src/dst check (mutable) |
| Route scope | N/A (use FOU) | Subnet | VPC-wide (tag-scoped) | Subnet |
| ESP in firewall | N/A (NAT-T) | `Esp` | `esp` | `50` (numeric) |
| VM config needed | Ansible (FOU) | None | None | None |
| Firewall for VPN | UDP 500/4500 + 9473 | UDP 500/4500 + ESP | UDP 500/4500 + ESP | UDP 500/4500 + ESP |

---

## File Structure

```
.
├── README.md
└── ansible/
    ├── inventory.ini                        # Gateways + Crusoe client VMs
    ├── site.yml
    ├── group_vars/
    │   ├── vpn_gateways.yml                # PSK, crypto settings
    │   ├── source_clients.yml              # Source VMs → gw-src
    │   └── remote_clients.yml              # Remote VMs → gw-rmt (Crusoe↔Crusoe)
    ├── host_vars/
    │   ├── gw-src.yml                      # vpn_use_gre=true, vpn_client_cidr
    │   └── gw-rmt.yml                      # vpn_use_gre=false or true
    └── roles/
        ├── vpn_gateway/                    # IPsec + conditional FOU
        │   ├── defaults/main.yml
        │   ├── tasks/main.yml
        │   ├── templates/
        │   │   ├── swanctl-vpn.conf.j2
        │   │   ├── sysctl-vpn.conf.j2
        │   │   └── vpn-network.service.j2
        │   └── handlers/main.yml
        └── vpn_client/                     # FOU tunnel + route (Crusoe VMs)
            ├── defaults/main.yml
            ├── tasks/main.yml
            ├── templates/vpn-client.service.j2
            └── handlers/main.yml
```

## Key Variables

| Variable | Where | Purpose |
|----------|-------|---------|
| `vpn_psk` | `group_vars/vpn_gateways.yml` | IKE pre-shared key |
| `vpn_use_gre` | `host_vars/gw-*.yml` | `true` for Crusoe, `false` for Azure/GCP/AWS |
| `vpn_client_cidr` | `host_vars/gw-*.yml` | Subnet CIDR of local VMs (Crusoe/FOU mode only) |
| `vpn_local_subnet` | `host_vars/gw-*.yml` | IPsec traffic selector (local) |
| `vpn_remote_subnet` | `host_vars/gw-*.yml` | IPsec traffic selector (remote) |
| `vpn_remote_gw_ip` | `host_vars/gw-*.yml` | Remote gateway public IP/32 |
| `vpn_gre_key` | `defaults/main.yml` | GRE key — must match between gateway and VMs |
| `vpn_fou_port` | `defaults/main.yml` | FOU UDP port — default 9473 |

## Adding VMs

**Crusoe**: Add to inventory, re-run playbook. Gateway already covers the CIDR.

**Azure/GCP/AWS**: Nothing to do. Cloud route table covers the subnet.

## Operations

```bash
ansible-playbook -i inventory.ini site.yml                  # Deploy all
ansible-playbook -i inventory.ini site.yml --limit gw-src   # One gateway
ansible-playbook -i inventory.ini site.yml --limit vm-s1    # One client VM
ansible-playbook -i inventory.ini site.yml --tags verify     # Check only
ansible-playbook -i inventory.ini site.yml --tags teardown   # Remove all
```

## Troubleshooting

```bash
# Either gateway
sudo swanctl --list-sas
sudo swanctl --initiate --child site-tunnel
sudo journalctl -u strongswan -f
ip route show dev xfrm0

# FOU-mode gateway (Crusoe)
ip tunnel show gre-vpn                  # Tunnel status
ip neigh show dev gre-vpn | head       # Neighbor table
ip route show table 100                # Policy route (xfrm0 → GRE)
ip rule show | grep xfrm0

# Direct-mode gateway (Azure/GCP/AWS)
sysctl net.ipv4.ip_forward             # Must be 1

# Crusoe client VM
ip tunnel show gre-vpn                  # FOU tunnel to gateway
ip route show dev gre-vpn              # Remote subnet route
systemctl status vpn-client
```

| Symptom | Check |
|---------|-------|
| IKE timeout | Firewall allows UDP 500+4500 from peer public IP/32? |
| Tunnel up, Crusoe→remote works, reverse fails | Cloud route table? NIC IP-forwarding? |
| Tunnel up, remote→Crusoe works, reverse fails | Crusoe VM in inventory? `ip tunnel show`? |
| New Crusoe VM can't connect | Added to inventory + re-ran playbook? |
| New cloud VM can't connect | Cloud route covers the VM's subnet? |
| Crusoe↔Crusoe one direction fails | Both gateways `vpn_use_gre=true`? UDP 9473 allowed? |
| FOU packets not arriving | Crusoe firewall allows UDP 9473 within region? |
