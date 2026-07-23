# Site-to-Site VPN (Crusoe ⇄ AWS/GCP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the public, parameterized repo that terminates hardened redundant route-based IPsec (IKEv2) + BGP VPN on the Crusoe side, per `SPEC.md`.

**Architecture:** Standalone Terraform root module `terraform/crusoe/` provisions 1–2 Ubuntu 24.04 VMs with static public IPs and per-peer firewall rules; a `startup_script` renders strongSwan (swanctl, XFRM interfaces) + FRR (bgpd) + nftables from a cloud-agnostic peer list. Optional `terraform/gcp/` (HA VPN, dev/test target) and `terraform/aws/` customer-side modules. Bash test suite + GitHub Actions static CI.

**Tech Stack:** Terraform (crusoecloud/crusoe ~0.5.44, hashicorp/google, hashicorp/aws), strongSwan swanctl + charon-systemd, FRR bgpd, nftables, bash, GitHub Actions (fmt/validate/tflint/tfsec/render-dry-run/secret-scan).

**Provider facts (researched, override spec assumptions):**
- VM: `crusoe_compute_instance` with `name/type/location/project_id/image/ssh_key/startup_script/network_interfaces`. Image string `"ubuntu24.04:latest"`. Public IP inline: `network_interfaces = [{ subnet = ..., public_ipv4 = { type = "static" } }]`; address at `.network_interfaces[0].public_ipv4.address`.
- `startup_script` is a **plain bash script** (`#!/bin/bash`), not cloud-init YAML → template is `templates/startup-script.sh.tftpl` (spec §17 allows this adaptation).
- Firewall: `crusoe_vpc_firewall_rule` — args `action/direction/protocols/source/source_ports/destination/destination_ports/name/network/project_id`. **One CIDR per rule** → `for_each` over (peer × vm) and (ssh_cidr × vm) products.
- No VPC/subnet creation resource in examples → module consumes existing `crusoe_vpc_subnet_id` variable; network ID for firewall rules read from instance attr `.network_interfaces[0].network`.
- No platform-level IP-forwarding/source-dest-check knob found → handled purely in-guest (sysctl); document in README as open platform question.
- `ssh_key` is write-only-ish (single string, set at create). Multiple keys → join with `\n`.
- Auth via `CRUSOE_API_KEY`/`CRUSOE_API_SECRET` env or `~/.crusoe/config`.

**Testing approach:** IaC — "failing test first" = static gates. Each task ends with `terraform fmt -check && terraform validate` (or `bash -n`/`shellcheck` for scripts) and, where templates exist, a render dry-run harness (`tests/render/`) that materializes templates from `params.example.tfvars` values and greps required stanzas. Live phases (1–6) are scripts committed here but executed only against real cloud creds (out of scope for this plan's verification).

---

### Task 1: Repo scaffold

**Files:**
- Create: `.gitignore`, `LICENSE`, `README.md` (skeleton; finalized Task 12), directory tree per SPEC §3.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Terraform
**/.terraform/
*.tfstate
*.tfstate.*
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraform.lock.hcl

# Variable files may contain peer IPs/ASNs but must never contain PSKs.
# Only the example is tracked.
*.tfvars
!params/params.example.tfvars

# Secrets — belt and suspenders
*.secrets
*.pem
*.key
handoff.txt

# Editor/OS
.DS_Store
.idea/
.vscode/
```

- [ ] **Step 2: Create `LICENSE`** — Apache-2.0 full text, copyright `2026 Crusoe Energy Systems LLC`.

- [ ] **Step 3: Create README.md skeleton**

```markdown
# Crusoe Site-to-Site VPN (AWS / GCP)

Hardened, redundant, route-based IPsec (IKEv2) VPN with BGP dynamic routing,
terminating on Crusoe. Customer side: AWS Site-to-Site VPN or GCP HA VPN.

> Status: under construction. See SPEC.md for the full design.

## Quickstart
(see docs/runbook.md)

## Tested against
(see tests/matrix.md)

## Security notes
No secrets in this repo. PSKs are supplied via environment at deploy time.
```

- [ ] **Step 4: Create empty dir tree** — `mkdir -p .github/workflows docs terraform/crusoe/templates terraform/gcp terraform/aws params scripts tests/render`. Add `.gitkeep` only where a task doesn't immediately fill the dir.

- [ ] **Step 5: Verify + commit**

Run: `git -C /Users/seif/DEV/solutions-library/site-to-site-vpn status` (repo root is parent — confirm; if `site-to-site-vpn` shares parent repo `solutions-library`, commit within it).
```bash
git add site-to-site-vpn && git commit -m "site-to-site-vpn: scaffold repo layout, gitignore, license"
```

---

### Task 2: Crusoe module — variables + validations

**Files:**
- Create: `terraform/crusoe/versions.tf`, `terraform/crusoe/variables.tf`

- [ ] **Step 1: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    crusoe = {
      source  = "registry.terraform.io/crusoecloud/crusoe"
      version = "~> 0.5.44"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
```

- [ ] **Step 2: `variables.tf`** — implement SPEC §4 verbatim plus provider-reality additions:

```hcl
variable "deployment_name" {
  description = "Prefix for all resources; DNS-safe."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.deployment_name))
    error_message = "deployment_name must be DNS-safe: lowercase alphanumeric and hyphens, 2-31 chars."
  }
}

variable "cloud" {
  description = "Peer cloud: selects default crypto profile."
  type        = string
  validation {
    condition     = contains(["gcp", "aws"], var.cloud)
    error_message = "cloud must be \"gcp\" or \"aws\"."
  }
}

variable "ha_mode" {
  description = "single = one VM terminates all tunnels; dual = two VMs across fault domains."
  type        = string
  default     = "single"
  validation {
    condition     = contains(["single", "dual"], var.ha_mode)
    error_message = "ha_mode must be \"single\" or \"dual\"."
  }
}

variable "crusoe_project_id" {
  description = "Crusoe project ID."
  type        = string
}

variable "crusoe_location" {
  description = "Crusoe location, e.g. us-east1-a."
  type        = string
}

variable "crusoe_vpc_subnet_id" {
  description = "Existing Crusoe VPC subnet ID the VPN VM(s) attach to."
  type        = string
}

variable "crusoe_vpc_cidrs" {
  description = "CIDRs advertised to the customer via BGP."
  type        = list(string)
  validation {
    condition     = alltrue([for c in var.crusoe_vpc_cidrs : can(cidrhost(c, 0))])
    error_message = "Every crusoe_vpc_cidrs entry must be a valid CIDR."
  }
}

variable "customer_cidrs" {
  description = "Customer CIDRs expected via BGP (used for prefix filters and overlap checks)."
  type        = list(string)
  validation {
    condition     = alltrue([for c in var.customer_cidrs : can(cidrhost(c, 0))])
    error_message = "Every customer_cidrs entry must be a valid CIDR."
  }
}

variable "instance_type" {
  description = "Crusoe instance type for the VPN VM(s)."
  type        = string
  default     = "c1a.4x"
}

variable "image" {
  description = "Crusoe image."
  type        = string
  default     = "ubuntu24.04:latest"
}

variable "local_asn" {
  description = "Crusoe-side private BGP ASN."
  type        = number
  validation {
    condition     = (var.local_asn >= 64512 && var.local_asn <= 65534) || (var.local_asn >= 4200000000 && var.local_asn <= 4294967294)
    error_message = "local_asn must be a private ASN (64512-65534 or 4200000000-4294967294)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "Management SSH allow-list. Never 0.0.0.0/0."
  type        = list(string)
  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs must be non-empty and must not contain 0.0.0.0/0."
  }
}

variable "ssh_public_keys" {
  description = "SSH public keys injected at create time."
  type        = list(string)
  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "At least one SSH public key is required."
  }
}

variable "mss_clamp" {
  description = "TCP MSS clamp for forwarded traffic across the tunnel."
  type        = number
  default     = 1360
}

variable "tunnel_mtu" {
  description = "XFRM interface MTU."
  type        = number
  default     = 1400
}

variable "tunnels" {
  description = "Ordered list of IPsec tunnels; both GCP and AWS map onto this."
  type = list(object({
    name            = string
    peer_public_ip  = string
    psk_var_name    = string
    xfrm_if_id      = number
    bgp_local_ip    = string
    bgp_remote_ip   = string
    bgp_inside_cidr = string
    remote_asn      = number
    vm_index        = number
  }))
  validation {
    condition     = length(var.tunnels) >= 1
    error_message = "At least one tunnel is required; two are recommended."
  }
  validation {
    condition     = length(distinct([for t in var.tunnels : t.xfrm_if_id])) == length(var.tunnels)
    error_message = "xfrm_if_id must be unique per tunnel."
  }
  validation {
    condition     = length(distinct([for t in var.tunnels : t.name])) == length(var.tunnels)
    error_message = "tunnel names must be unique."
  }
  validation {
    condition     = alltrue([for t in var.tunnels : t.vm_index >= 0 && t.vm_index <= 1])
    error_message = "vm_index must be 0 or 1."
  }
}

variable "tunnel_psks" {
  description = "Map from psk_var_name to PSK value. Supply via TF_VAR_tunnel_psks env or a secret store; NEVER commit."
  type        = map(string)
  sensitive   = true
}

variable "crypto_profile" {
  description = "IKE and ESP proposals. Null selects a per-cloud default (see docs/crypto-profiles.md)."
  type = object({
    ike_proposals = list(string)
    esp_proposals = list(string)
    ike_lifetime  = string
    esp_lifetime  = string
    dpd_delay     = string
    dpd_timeout   = string
    rekey_margin  = string
  })
  default = null
}
```

- [ ] **Step 3: Validate**

Run: `terraform -chdir=terraform/crusoe fmt -check && terraform -chdir=terraform/crusoe init -backend=false && terraform -chdir=terraform/crusoe validate`
Expected: FAIL initially only if main.tf absent counts — `validate` passes on variables-only module; expect PASS.

- [ ] **Step 4: Commit** — `git add terraform/crusoe/{versions,variables}.tf && git commit -m "crusoe module: variables, validations, pinned providers"`

---

### Task 3: Crusoe module — locals, CIDR-overlap preconditions, main.tf, outputs, handoff

**Files:**
- Create: `terraform/crusoe/main.tf`, `terraform/crusoe/outputs.tf`

- [ ] **Step 1: `main.tf`**

```hcl
locals {
  vm_count = var.ha_mode == "dual" ? 2 : 1

  # tunnels grouped by terminating VM
  tunnels_by_vm = {
    for idx in range(local.vm_count) :
    idx => [for t in var.tunnels : t if t.vm_index == idx]
  }

  ssh_keys_joined = join("\n", var.ssh_public_keys)

  # cloud-keyed crypto defaults; see docs/crypto-profiles.md before production use
  crypto_defaults = {
    gcp = {
      ike_proposals = ["aes256gcm16-prfsha384-ecp384", "aes256-sha384-modp2048"]
      esp_proposals = ["aes256gcm16-ecp384"]
      ike_lifetime  = "8h"
      esp_lifetime  = "1h"
      dpd_delay     = "30s"
      dpd_timeout   = "120s"
      rekey_margin  = "3m"
    }
    aws = {
      ike_proposals = ["aes256gcm16-prfsha384-ecp384", "aes256-sha384-modp2048"]
      esp_proposals = ["aes256gcm16-ecp384"]
      ike_lifetime  = "8h"
      esp_lifetime  = "1h"
      dpd_delay     = "30s"
      dpd_timeout   = "120s"
      rekey_margin  = "3m"
    }
  }
  crypto = var.crypto_profile != null ? var.crypto_profile : local.crypto_defaults[var.cloud]

  # every (a,b) CIDR pair that must not overlap
  overlap_pairs = concat(
    [for pair in setproduct(var.crusoe_vpc_cidrs, var.customer_cidrs) : pair],
    [for pair in setproduct(var.crusoe_vpc_cidrs, [for t in var.tunnels : t.bgp_inside_cidr]) : pair],
    [for pair in setproduct(var.customer_cidrs, [for t in var.tunnels : t.bgp_inside_cidr]) : pair],
  )
}

# CIDR overlap guard: cidrhost-based containment check both directions.
resource "terraform_data" "cidr_overlap_guard" {
  lifecycle {
    precondition {
      condition = alltrue([
        for pair in local.overlap_pairs :
        !(
          can(cidrhost(pair[0], 0)) && can(cidrhost(pair[1], 0)) &&
          (
            cidrhost(pair[0], 0) == cidrhost(cidrsubnet(pair[1], 0, 0), 0) ||
            # a contains b's network addr or b contains a's network addr
            (tonumber(split("/", pair[0])[1]) <= tonumber(split("/", pair[1])[1]) &&
             cidrhost(pair[0], 0) == cidrhost("${split("/", pair[1])[0]}/${split("/", pair[0])[1]}", 0)) ||
            (tonumber(split("/", pair[1])[1]) <= tonumber(split("/", pair[0])[1]) &&
             cidrhost(pair[1], 0) == cidrhost("${split("/", pair[0])[0]}/${split("/", pair[1])[1]}", 0))
          )
        )
      ])
      error_message = "CIDR overlap detected between crusoe_vpc_cidrs, customer_cidrs, and/or bgp_inside_cidrs. See docs/ip-planning.md."
    }
  }
}

resource "crusoe_compute_instance" "vpn" {
  count      = local.vm_count
  name       = "${var.deployment_name}-vpn-${count.index}"
  type       = var.instance_type
  location   = var.crusoe_location
  project_id = var.crusoe_project_id
  image      = var.image
  ssh_key    = local.ssh_keys_joined

  network_interfaces = [{
    subnet = var.crusoe_vpc_subnet_id
    public_ipv4 = {
      type = "static"
    }
  }]

  startup_script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
    tunnels      = local.tunnels_by_vm[count.index]
    all_tunnels  = var.tunnels
    crypto       = local.crypto
    psks         = { for t in local.tunnels_by_vm[count.index] : t.name => var.tunnel_psks[t.psk_var_name] }
    local_asn    = var.local_asn
    crusoe_cidrs = var.crusoe_vpc_cidrs
    customer_cidrs = var.customer_cidrs
    mss_clamp    = var.mss_clamp
    tunnel_mtu   = var.tunnel_mtu
    ssh_allowed_cidrs = var.ssh_allowed_cidrs
  })

  lifecycle {
    ignore_changes = [ssh_key]
    replace_triggered_by = []
  }

  depends_on = [terraform_data.cidr_overlap_guard]
}

# Crusoe firewall accepts ONE source CIDR per rule -> product expansion.
locals {
  ike_rules = {
    for pair in setproduct(range(local.vm_count), distinct([for t in var.tunnels : t.peer_public_ip])) :
    "vm${pair[0]}-peer-${replace(pair[1], ".", "-")}" => { vm = pair[0], peer = pair[1] }
    if length([for t in var.tunnels : t if t.vm_index == pair[0] && t.peer_public_ip == pair[1]]) > 0
  }
  ssh_rules = {
    for pair in setproduct(range(local.vm_count), var.ssh_allowed_cidrs) :
    "vm${pair[0]}-ssh-${replace(replace(pair[1], ".", "-"), "/", "-")}" => { vm = pair[0], cidr = pair[1] }
  }
}

resource "crusoe_vpc_firewall_rule" "ike" {
  for_each          = local.ike_rules
  action            = "allow"
  direction         = "ingress"
  protocols         = "udp"
  source            = "${each.value.peer}/32"
  source_ports      = "1-65535"
  destination       = crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].private_ipv4.address
  destination_ports = "500,4500"
  name              = "${var.deployment_name}-ike-${each.key}"
  network           = crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].network
  project_id        = var.crusoe_project_id
}

resource "crusoe_vpc_firewall_rule" "ssh" {
  for_each          = local.ssh_rules
  action            = "allow"
  direction         = "ingress"
  protocols         = "tcp"
  source            = each.value.cidr
  source_ports      = "1-65535"
  destination       = crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].private_ipv4.address
  destination_ports = "22"
  name              = "${var.deployment_name}-ssh-${each.key}"
  network           = crusoe_compute_instance.vpn[each.value.vm].network_interfaces[0].network
  project_id        = var.crusoe_project_id
}

# Customer handoff bundle (no secrets)
resource "local_file" "handoff" {
  filename        = "${path.root}/handoff.txt"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/handoff.txt.tftpl", {
    deployment_name = var.deployment_name
    cloud           = var.cloud
    vm_public_ips   = [for vm in crusoe_compute_instance.vpn : vm.network_interfaces[0].public_ipv4.address]
    tunnels         = var.tunnels
    local_asn       = var.local_asn
    crusoe_cidrs    = var.crusoe_vpc_cidrs
  })
}
```

Note: if `destination_ports = "500,4500"` rejects comma lists at apply time, split into two rules per peer (`-ike500-` / `-ike4500-`); keep the for_each key scheme.

- [ ] **Step 2: `outputs.tf`**

```hcl
output "crusoe_public_ips" {
  description = "Public IPs of the Crusoe VPN VM(s); customer points tunnels here."
  value       = [for vm in crusoe_compute_instance.vpn : vm.network_interfaces[0].public_ipv4.address]
}

output "crusoe_private_ips" {
  value = [for vm in crusoe_compute_instance.vpn : vm.network_interfaces[0].private_ipv4.address]
}

output "crusoe_vpc_cidrs" {
  value = var.crusoe_vpc_cidrs
}

output "local_asn" {
  value = var.local_asn
}

output "handoff_file" {
  value = local_file.handoff.filename
}
```

- [ ] **Step 3: `templates/handoff.txt.tftpl`**

```
Site-to-Site VPN handoff — ${deployment_name} (${cloud})
=========================================================
Crusoe VPN endpoint public IP(s):
%{ for ip in vm_public_ips ~}
  - ${ip}
%{ endfor ~}

Crusoe BGP ASN: ${local_asn}
Crusoe advertised CIDRs:
%{ for c in crusoe_cidrs ~}
  - ${c}
%{ endfor ~}

Tunnels (configure your gateway to match):
%{ for t in tunnels ~}
  ${t.name}:
    your endpoint (peer_public_ip): ${t.peer_public_ip}
    inside CIDR: ${t.bgp_inside_cidr}
    your BGP IP: ${t.bgp_remote_ip}   (ASN ${t.remote_asn})
    Crusoe BGP IP: ${t.bgp_local_ip}
%{ endfor ~}

IKEv2 only. NAT-T (UDP 4500). PSKs delivered out-of-band.
```

- [ ] **Step 4: Validate** — `terraform -chdir=terraform/crusoe fmt -check && terraform -chdir=terraform/crusoe validate` (startup-script template must exist first; create a stub `templates/startup-script.sh.tftpl` containing `#!/bin/bash` + `# rendered in Task 4` so validate passes; Task 4 replaces it).
Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "crusoe module: instances, firewall product-expansion, overlap guard, handoff"`

---

### Task 4: Bootstrap template — `startup-script.sh.tftpl` + config sub-templates

**Files:**
- Create: `terraform/crusoe/templates/startup-script.sh.tftpl`
- Create: `terraform/crusoe/templates/swanctl.conf.tftpl`
- Create: `terraform/crusoe/templates/swanctl-secrets.conf.tftpl`
- Create: `terraform/crusoe/templates/frr-daemons.tftpl`
- Create: `terraform/crusoe/templates/frr-bgpd.conf.tftpl`
- Create: `terraform/crusoe/templates/nftables.conf.tftpl`
- Create: `terraform/crusoe/templates/xfrm-interfaces.sh.tftpl`

- [ ] **Step 1: `swanctl.conf.tftpl`**

```
# Rendered by Terraform — do not edit on host.
connections {
%{ for t in tunnels ~}
  ${t.name} {
    version = 2
    mobike = no
    local_addrs = %any
    remote_addrs = ${t.peer_public_ip}
    proposals = ${join(",", crypto.ike_proposals)}
    rekey_time = ${crypto.ike_lifetime}
    dpd_delay = ${crypto.dpd_delay}
    encap = yes
    if_id_in = ${t.xfrm_if_id}
    if_id_out = ${t.xfrm_if_id}
    local {
      auth = psk
      id = %any
    }
    remote {
      auth = psk
      id = ${t.peer_public_ip}
    }
    children {
      ${t.name} {
        local_ts = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        esp_proposals = ${join(",", crypto.esp_proposals)}
        rekey_time = ${crypto.esp_lifetime}
        start_action = trap
        dpd_action = restart
        close_action = trap
      }
    }
  }
%{ endfor ~}
}
```

- [ ] **Step 2: `swanctl-secrets.conf.tftpl`**

```
secrets {
%{ for t in tunnels ~}
  ike-${t.name} {
    id = ${t.peer_public_ip}
    secret = "${psks[t.name]}"
  }
%{ endfor ~}
}
```

- [ ] **Step 3: `frr-daemons.tftpl`**

```
zebra=yes
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
```

- [ ] **Step 4: `frr-bgpd.conf.tftpl`**

```
frr defaults traditional
log syslog informational
!
%{ for c in customer_cidrs ~}
ip prefix-list CUSTOMER-IN seq ${5 + index(customer_cidrs, c) * 5} permit ${c}
%{ endfor ~}
ip prefix-list CUSTOMER-IN seq 1000 deny any
!
%{ for c in crusoe_cidrs ~}
ip prefix-list CRUSOE-OUT seq ${5 + index(crusoe_cidrs, c) * 5} permit ${c}
%{ endfor ~}
ip prefix-list CRUSOE-OUT seq 1000 deny any
!
router bgp ${local_asn}
 bgp router-id ${tunnels[0].bgp_local_ip}
 no bgp ebgp-requires-policy
%{ for t in tunnels ~}
 neighbor ${t.bgp_remote_ip} remote-as ${t.remote_asn}
 neighbor ${t.bgp_remote_ip} timers 10 30
 neighbor ${t.bgp_remote_ip} description ${t.name}
%{ endfor ~}
 !
 address-family ipv4 unicast
%{ for c in crusoe_cidrs ~}
  network ${c}
%{ endfor ~}
  maximum-paths 4
%{ for t in tunnels ~}
  neighbor ${t.bgp_remote_ip} activate
  neighbor ${t.bgp_remote_ip} prefix-list CUSTOMER-IN in
  neighbor ${t.bgp_remote_ip} prefix-list CRUSOE-OUT out
%{ endfor ~}
 exit-address-family
!
```

Note: `no bgp ebgp-requires-policy` is safe because explicit prefix-lists are applied both directions.

- [ ] **Step 5: `nftables.conf.tftpl`**

```
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept
    ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
    # IKE / NAT-T from peers only
%{ for t in tunnels ~}
    ip saddr ${t.peer_public_ip} udp dport { 500, 4500 } accept
%{ endfor ~}
    # SSH from management allow-list
%{ for c in ssh_allowed_cidrs ~}
    ip saddr ${c} tcp dport 22 accept
%{ endfor ~}
    # BGP only over tunnel interfaces
%{ for t in tunnels ~}
    iifname "ipsec${t.xfrm_if_id}" ip saddr ${t.bgp_remote_ip} tcp dport 179 accept
    iifname "ipsec${t.xfrm_if_id}" icmp type echo-request accept
%{ endfor ~}
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    # MSS clamp on tunnel path (both directions)
%{ for t in tunnels ~}
    iifname "ipsec${t.xfrm_if_id}" tcp flags syn tcp option maxseg size set ${mss_clamp}
    oifname "ipsec${t.xfrm_if_id}" tcp flags syn tcp option maxseg size set ${mss_clamp}
    iifname "ipsec${t.xfrm_if_id}" accept
    oifname "ipsec${t.xfrm_if_id}" accept
%{ endfor ~}
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
```

- [ ] **Step 6: `xfrm-interfaces.sh.tftpl`** — idempotent interface bring-up, also installed as a oneshot systemd unit for reboot persistence:

```
#!/bin/bash
set -u
WAN_IF=$(ip -o -4 route show default | awk '{print $5}' | head -1)
%{ for t in tunnels ~}
if ! ip link show "ipsec${t.xfrm_if_id}" &>/dev/null; then
  ip link add "ipsec${t.xfrm_if_id}" type xfrm dev "$WAN_IF" if_id ${t.xfrm_if_id}
fi
ip link set "ipsec${t.xfrm_if_id}" mtu ${tunnel_mtu} up
ip addr replace ${t.bgp_local_ip}/30 dev "ipsec${t.xfrm_if_id}"
%{ endfor ~}
```

- [ ] **Step 7: `startup-script.sh.tftpl`** — orchestrates everything; idempotent; embeds rendered sub-configs via Terraform nested `templatefile` is NOT possible inside a template, so main.tf passes pre-rendered strings. **Adjust main.tf `startup_script`** to:

```hcl
  startup_script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
    swanctl_conf   = templatefile("${path.module}/templates/swanctl.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], crypto = local.crypto })
    swanctl_secrets = templatefile("${path.module}/templates/swanctl-secrets.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], psks = { for t in local.tunnels_by_vm[count.index] : t.name => var.tunnel_psks[t.psk_var_name] } })
    frr_daemons    = file("${path.module}/templates/frr-daemons.tftpl")
    frr_bgpd_conf  = templatefile("${path.module}/templates/frr-bgpd.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], local_asn = var.local_asn, crusoe_cidrs = var.crusoe_vpc_cidrs, customer_cidrs = var.customer_cidrs })
    nftables_conf  = templatefile("${path.module}/templates/nftables.conf.tftpl", { tunnels = local.tunnels_by_vm[count.index], ssh_allowed_cidrs = var.ssh_allowed_cidrs, mss_clamp = var.mss_clamp })
    xfrm_script    = templatefile("${path.module}/templates/xfrm-interfaces.sh.tftpl", { tunnels = local.tunnels_by_vm[count.index], tunnel_mtu = var.tunnel_mtu })
  })
```

Template body:

```
#!/bin/bash
# Crusoe site-to-site VPN bootstrap. Idempotent: safe to re-run.
set -uo pipefail
exec > >(tee -a /var/log/vpn-bootstrap.log) 2>&1
echo "=== vpn bootstrap $(date -Is) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y strongswan strongswan-swanctl charon-systemd frr nftables \
  iperf3 tcpdump traceroute nmap unattended-upgrades

# --- sysctls ---
cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
# loose rp_filter: tolerate asymmetric return paths across two tunnels
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.forwarding = 0
EOF
sysctl --system

# --- SSH hardening ---
cat > /etc/ssh/sshd_config.d/99-vpn-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
systemctl reload ssh || systemctl reload sshd || true

# --- strongSwan (swanctl) ---
mkdir -p /etc/swanctl/conf.d
cat > /etc/swanctl/conf.d/tunnels.conf <<'SWANCTL_EOF'
${swanctl_conf}
SWANCTL_EOF
install -m 0600 /dev/null /etc/swanctl/conf.d/tunnels.secrets.conf
cat > /etc/swanctl/conf.d/tunnels.secrets.conf <<'SECRETS_EOF'
${swanctl_secrets}
SECRETS_EOF
chmod 0600 /etc/swanctl/conf.d/tunnels.secrets.conf

# Ubuntu ships both legacy "strongswan-starter" and "strongswan" (charon-systemd).
systemctl disable --now strongswan-starter 2>/dev/null || true

# --- XFRM interfaces (persist via oneshot unit) ---
cat > /usr/local/sbin/vpn-xfrm-up.sh <<'XFRM_EOF'
${xfrm_script}
XFRM_EOF
chmod 0755 /usr/local/sbin/vpn-xfrm-up.sh
cat > /etc/systemd/system/vpn-xfrm.service <<'EOF'
[Unit]
Description=Create XFRM interfaces for IPsec route-based tunnels
After=network-online.target
Wants=network-online.target
Before=strongswan.service frr.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn-xfrm-up.sh

[Install]
WantedBy=multi-user.target
EOF

# --- FRR ---
cat > /etc/frr/daemons <<'FRR_EOF'
${frr_daemons}
FRR_EOF
cat > /etc/frr/frr.conf <<'BGPD_EOF'
${frr_bgpd_conf}
BGPD_EOF
chown frr:frr /etc/frr/frr.conf
chmod 0640 /etc/frr/frr.conf

# --- nftables ---
cat > /etc/nftables.conf <<'NFT_EOF'
${nftables_conf}
NFT_EOF

# --- unattended security upgrades ---
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl daemon-reload
systemctl enable --now vpn-xfrm.service
systemctl enable --now nftables
systemctl enable --now strongswan
systemctl enable --now frr
swanctl --load-all || true

echo "=== vpn bootstrap complete $(date -Is) ==="
```

- [ ] **Step 8: Validate** — `terraform -chdir=terraform/crusoe fmt -check && terraform -chdir=terraform/crusoe validate`. Expected: PASS.

- [ ] **Step 9: Commit** — `git commit -am "crusoe module: startup-script bootstrap + swanctl/frr/nftables/xfrm templates"`

---

### Task 5: Render dry-run harness (`tests/render/`)

Static test proving templates render correctly from example params — this is CI Phase 0's "template render dry-run".

**Files:**
- Create: `tests/render/main.tf` (tiny root module that calls `templatefile()` on the real templates with fixture values and writes rendered outputs to `tests/render/out/`)
- Create: `tests/render/check.sh`

- [ ] **Step 1: `tests/render/main.tf`**

```hcl
# Renders the real templates with fixture data so CI can grep required stanzas.
locals {
  crypto = {
    ike_proposals = ["aes256gcm16-prfsha384-ecp384"]
    esp_proposals = ["aes256gcm16-ecp384"]
    ike_lifetime  = "8h"
    esp_lifetime  = "1h"
    dpd_delay     = "30s"
    dpd_timeout   = "120s"
    rekey_margin  = "3m"
  }
  tunnels = [
    { name = "tunnel-a", peer_public_ip = "203.0.113.10", psk_var_name = "PSK_A", xfrm_if_id = 101, bgp_local_ip = "169.254.21.2", bgp_remote_ip = "169.254.21.1", bgp_inside_cidr = "169.254.21.0/30", remote_asn = 64514, vm_index = 0 },
    { name = "tunnel-b", peer_public_ip = "203.0.113.11", psk_var_name = "PSK_B", xfrm_if_id = 102, bgp_local_ip = "169.254.22.2", bgp_remote_ip = "169.254.22.1", bgp_inside_cidr = "169.254.22.0/30", remote_asn = 64514, vm_index = 0 },
  ]
  tpl = "${path.module}/../../terraform/crusoe/templates"
}

resource "local_file" "swanctl" {
  filename = "${path.module}/out/swanctl.conf"
  content  = templatefile("${local.tpl}/swanctl.conf.tftpl", { tunnels = local.tunnels, crypto = local.crypto })
}

resource "local_file" "bgpd" {
  filename = "${path.module}/out/frr.conf"
  content = templatefile("${local.tpl}/frr-bgpd.conf.tftpl", {
    tunnels = local.tunnels, local_asn = 65000,
    crusoe_cidrs = ["10.100.0.0/16"], customer_cidrs = ["10.200.0.0/16"]
  })
}

resource "local_file" "nft" {
  filename = "${path.module}/out/nftables.conf"
  content = templatefile("${local.tpl}/nftables.conf.tftpl", {
    tunnels = local.tunnels, ssh_allowed_cidrs = ["198.51.100.0/24"], mss_clamp = 1360
  })
}

terraform {
  required_providers {
    local = { source = "hashicorp/local" }
  }
}
```

- [ ] **Step 2: `tests/render/check.sh`**

```bash
#!/usr/bin/env bash
# Template render dry-run: render via terraform apply (local_file only), grep required stanzas.
set -euo pipefail
cd "$(dirname "$0")"
fail=0
say() { printf '%s\n' "$*"; }
assert_grep() { # file pattern description
  if grep -qE "$2" "out/$1"; then say "PASS: $3"; else say "FAIL: $3 (pattern '$2' missing in out/$1)"; fail=1; fi
}
assert_not_grep() {
  if ! grep -qE "$2" "out/$1"; then say "PASS: $3"; else say "FAIL: $3 (pattern '$2' present in out/$1)"; fail=1; fi
}

terraform init -backend=false -input=false >/dev/null
terraform apply -auto-approve -input=false >/dev/null

# swanctl assertions
assert_grep swanctl.conf 'tunnel-a \{'                 "connection block per tunnel (a)"
assert_grep swanctl.conf 'tunnel-b \{'                 "connection block per tunnel (b)"
assert_grep swanctl.conf 'version = 2'                 "IKEv2 only"
assert_grep swanctl.conf 'aes256gcm16-prfsha384-ecp384' "expected IKE proposal"
assert_grep swanctl.conf 'if_id_in = 101'              "xfrm if_id wired"
assert_grep swanctl.conf 'start_action = trap'         "trap start action"
assert_not_grep swanctl.conf 'version = 1'             "no IKEv1"

# bgpd assertions
assert_grep frr.conf 'router bgp 65000'                       "local ASN"
assert_grep frr.conf 'neighbor 169.254.21.1 remote-as 64514'  "BGP neighbor per tunnel (a)"
assert_grep frr.conf 'neighbor 169.254.22.1 remote-as 64514'  "BGP neighbor per tunnel (b)"
assert_grep frr.conf 'network 10.100.0.0/16'                  "advertised CIDR"
assert_grep frr.conf 'prefix-list CUSTOMER-IN in'             "inbound prefix filter"
assert_grep frr.conf 'prefix-list CRUSOE-OUT out'             "outbound prefix filter"
assert_grep frr.conf 'maximum-paths'                          "ECMP enabled"

# nftables assertions
assert_grep nftables.conf 'policy drop'                          "default-deny input"
assert_grep nftables.conf 'ip saddr 203.0.113.10 udp dport \{ 500, 4500 \}' "IKE allowed from peer only"
assert_grep nftables.conf 'maxseg size set 1360'                 "MSS clamp"
assert_grep nftables.conf 'tcp dport 179'                        "BGP restricted to tunnel ifaces"
assert_not_grep nftables.conf '0\.0\.0\.0/0 tcp dport 22'        "no world-open SSH"

exit $fail
```

- [ ] **Step 3: Run it** — `bash tests/render/check.sh`. Expected: all PASS, exit 0. Fix templates until green.

- [ ] **Step 4: Add `tests/render/out/` and `tests/render/.terraform*` to `.gitignore`**; commit — `git commit -am "tests: template render dry-run harness with stanza assertions"`

---

### Task 6: GCP customer-side module (`terraform/gcp/`)

**Files:**
- Create: `terraform/gcp/versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

- [ ] **Step 1: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
```

- [ ] **Step 2: `variables.tf`**

```hcl
variable "project_id" { type = string }
variable "region" { type = string }
variable "network_name" {
  description = "Existing VPC network name (or set create_network=true)."
  type        = string
  default     = "vpn-test"
}
variable "create_network" {
  type    = bool
  default = true
}
variable "subnet_cidr" {
  description = "GCP-side test subnet CIDR (the 'customer CIDR')."
  type        = string
  default     = "10.200.0.0/16"
}
variable "gcp_asn" {
  type    = number
  default = 64514
}
variable "crusoe_asn" { type = number }
variable "crusoe_public_ips" {
  description = "Crusoe VPN VM public IP(s). One IP => single-interface external gateway; two => two-interface."
  type        = list(string)
}
variable "tunnel_psks" {
  description = "PSK per tunnel index (0,1). Same values fed to the Crusoe side."
  type        = list(string)
  sensitive   = true
}
variable "bgp_inside_cidrs" {
  description = "Link-local /30 per tunnel, e.g. [\"169.254.21.0/30\", \"169.254.22.0/30\"]. GCP takes .1, Crusoe .2."
  type        = list(string)
}
variable "deployment_name" {
  type    = string
  default = "crusoe-vpn"
}
```

- [ ] **Step 3: `main.tf`**

```hcl
locals {
  # GCP gets host 1 of each /30, Crusoe host 2
  gcp_bgp_ips    = [for c in var.bgp_inside_cidrs : cidrhost(c, 1)]
  crusoe_bgp_ips = [for c in var.bgp_inside_cidrs : cidrhost(c, 2)]
  redundancy     = length(var.crusoe_public_ips) == 1 ? "SINGLE_IP_INTERNALLY_REDUNDANT" : "TWO_IPS_REDUNDANCY"
}

resource "google_compute_network" "vpn" {
  count                   = var.create_network ? 1 : 0
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
}

data "google_compute_network" "existing" {
  count   = var.create_network ? 0 : 1
  name    = var.network_name
  project = var.project_id
}

locals {
  network_id = var.create_network ? google_compute_network.vpn[0].id : data.google_compute_network.existing[0].id
}

resource "google_compute_subnetwork" "vpn" {
  count         = var.create_network ? 1 : 0
  name          = "${var.deployment_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = local.network_id
  ip_cidr_range = var.subnet_cidr
}

resource "google_compute_ha_vpn_gateway" "gw" {
  name    = "${var.deployment_name}-ha-gw"
  project = var.project_id
  region  = var.region
  network = local.network_id
}

resource "google_compute_external_vpn_gateway" "crusoe" {
  name            = "${var.deployment_name}-crusoe-gw"
  project         = var.project_id
  redundancy_type = local.redundancy
  dynamic "interface" {
    for_each = var.crusoe_public_ips
    content {
      id         = interface.key
      ip_address = interface.value
    }
  }
}

resource "google_compute_router" "router" {
  name    = "${var.deployment_name}-router"
  project = var.project_id
  region  = var.region
  network = local.network_id
  bgp {
    asn = var.gcp_asn
  }
}

resource "google_compute_vpn_tunnel" "tunnel" {
  count                           = 2
  name                            = "${var.deployment_name}-tunnel-${count.index}"
  project                         = var.project_id
  region                          = var.region
  vpn_gateway                     = google_compute_ha_vpn_gateway.gw.id
  vpn_gateway_interface           = count.index
  peer_external_gateway           = google_compute_external_vpn_gateway.crusoe.id
  peer_external_gateway_interface = length(var.crusoe_public_ips) == 1 ? 0 : count.index
  shared_secret                   = var.tunnel_psks[count.index]
  router                          = google_compute_router.router.id
  ike_version                     = 2
}

resource "google_compute_router_interface" "iface" {
  count      = 2
  name       = "${var.deployment_name}-iface-${count.index}"
  project    = var.project_id
  region     = var.region
  router     = google_compute_router.router.name
  ip_range   = "${local.gcp_bgp_ips[count.index]}/30"
  vpn_tunnel = google_compute_vpn_tunnel.tunnel[count.index].name
}

resource "google_compute_router_peer" "peer" {
  count                     = 2
  name                      = "${var.deployment_name}-peer-${count.index}"
  project                   = var.project_id
  region                    = var.region
  router                    = google_compute_router.router.name
  peer_ip_address           = local.crusoe_bgp_ips[count.index]
  peer_asn                  = var.crusoe_asn
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.iface[count.index].name
}

resource "google_compute_firewall" "allow_crusoe" {
  name      = "${var.deployment_name}-allow-crusoe"
  project   = var.project_id
  network   = local.network_id
  direction = "INGRESS"
  allow { protocol = "icmp" }
  allow {
    protocol = "tcp"
    ports    = ["22", "5201"]
  }
  allow {
    protocol = "udp"
    ports    = ["5201"]
  }
  source_ranges = ["10.0.0.0/8"] # tighten to crusoe_vpc_cidrs in tfvars-driven setups
}
```

- [ ] **Step 4: `outputs.tf`**

```hcl
output "gcp_vpn_public_ips" {
  description = "Feed these into params.tfvars as tunnels[*].peer_public_ip."
  value = [
    google_compute_ha_vpn_gateway.gw.vpn_interfaces[0].ip_address,
    google_compute_ha_vpn_gateway.gw.vpn_interfaces[1].ip_address,
  ]
}
output "gcp_asn" { value = var.gcp_asn }
output "gcp_bgp_ips" { value = local.gcp_bgp_ips }
output "crusoe_bgp_ips" { value = local.crusoe_bgp_ips }
output "subnet_cidr" { value = var.subnet_cidr }
```

- [ ] **Step 5: Validate** — `terraform -chdir=terraform/gcp fmt -check && terraform -chdir=terraform/gcp init -backend=false && terraform -chdir=terraform/gcp validate`. Expected: PASS.

- [ ] **Step 6: Commit** — `git commit -am "gcp module: HA VPN + Cloud Router customer side (dev/test target)"`

---

### Task 7: AWS customer-side module (`terraform/aws/`)

**Files:**
- Create: `terraform/aws/versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`

- [ ] **Step 1: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

- [ ] **Step 2: `variables.tf`**

```hcl
variable "region" { type = string }
variable "deployment_name" {
  type    = string
  default = "crusoe-vpn"
}
variable "vpc_id" {
  description = "Existing customer VPC to attach the TGW to."
  type        = string
}
variable "subnet_ids" {
  description = "Subnets for the TGW VPC attachment."
  type        = list(string)
}
variable "aws_asn" {
  type    = number
  default = 64512
}
variable "crusoe_asn" { type = number }
variable "crusoe_public_ip" {
  description = "Crusoe VPN VM public IP (one CGW per Crusoe VM; add a second module instance for ha_mode=dual)."
  type        = string
}
variable "bgp_inside_cidrs" {
  description = "Optional: pin the two tunnel inside CIDRs (169.254.x.x/30, AWS-reserved ranges excluded). Empty = AWS auto-assigns."
  type        = list(string)
  default     = []
}
```

- [ ] **Step 3: `main.tf`**

```hcl
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = "${var.deployment_name} TGW"
  amazon_side_asn                 = var.aws_asn
  vpn_ecmp_support                = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  tags                            = { Name = var.deployment_name }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "vpc" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  tags               = { Name = "${var.deployment_name}-vpc" }
}

resource "aws_customer_gateway" "crusoe" {
  bgp_asn    = var.crusoe_asn
  ip_address = var.crusoe_public_ip
  type       = "ipsec.1"
  tags       = { Name = "${var.deployment_name}-crusoe" }
}

resource "aws_vpn_connection" "vpn" {
  customer_gateway_id = aws_customer_gateway.crusoe.id
  transit_gateway_id  = aws_ec2_transit_gateway.tgw.id
  type                = "ipsec.1"

  tunnel1_inside_cidr = length(var.bgp_inside_cidrs) > 0 ? var.bgp_inside_cidrs[0] : null
  tunnel2_inside_cidr = length(var.bgp_inside_cidrs) > 1 ? var.bgp_inside_cidrs[1] : null

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256-GCM-16"]
  tunnel2_phase1_encryption_algorithms = ["AES256-GCM-16"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-384"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-384"]
  tunnel1_phase1_dh_group_numbers      = [20]
  tunnel2_phase1_dh_group_numbers      = [20]
  tunnel1_phase2_encryption_algorithms = ["AES256-GCM-16"]
  tunnel2_phase2_encryption_algorithms = ["AES256-GCM-16"]
  tunnel1_phase2_dh_group_numbers      = [20]
  tunnel2_phase2_dh_group_numbers      = [20]

  tags = { Name = var.deployment_name }
}
```

- [ ] **Step 4: `outputs.tf`**

```hcl
output "aws_tunnel_public_ips" {
  description = "Feed into params.tfvars as tunnels[*].peer_public_ip."
  value       = [aws_vpn_connection.vpn.tunnel1_address, aws_vpn_connection.vpn.tunnel2_address]
}
output "aws_tunnel_inside_cidrs" {
  value = [aws_vpn_connection.vpn.tunnel1_inside_cidr, aws_vpn_connection.vpn.tunnel2_inside_cidr]
}
output "aws_asn" { value = var.aws_asn }
output "aws_tunnel_psks" {
  description = "AWS-generated PSKs. Export into TF_VAR_tunnel_psks for the Crusoe apply. Sensitive."
  value       = [aws_vpn_connection.vpn.tunnel1_preshared_key, aws_vpn_connection.vpn.tunnel2_preshared_key]
  sensitive   = true
}
```

- [ ] **Step 5: Validate + commit** — `terraform -chdir=terraform/aws fmt -check && terraform -chdir=terraform/aws init -backend=false && terraform -chdir=terraform/aws validate`; `git commit -am "aws module: S2S VPN on TGW with pinned IKEv2 crypto"`

---

### Task 8: Params (`params/`)

**Files:**
- Create: `params/params.example.tfvars`, `params/schema.md`

- [ ] **Step 1: `params.example.tfvars`** — complete GCP-shaped example, placeholder IPs from TEST-NET:

```hcl
deployment_name      = "acme-gcp"
cloud                = "gcp"
ha_mode              = "single"
crusoe_project_id    = "REPLACE-crusoe-project-uuid"
crusoe_location      = "us-east1-a"
crusoe_vpc_subnet_id = "REPLACE-subnet-uuid"
crusoe_vpc_cidrs     = ["10.100.0.0/16"]
customer_cidrs       = ["10.200.0.0/16"]
local_asn            = 65000
ssh_allowed_cidrs    = ["198.51.100.0/24"] # your office/VPN egress, never 0.0.0.0/0
ssh_public_keys      = ["ssh-ed25519 AAAA... you@example.com"]

tunnels = [
  {
    name            = "tunnel-a"
    peer_public_ip  = "203.0.113.10" # GCP HA VPN interface 0 IP
    psk_var_name    = "PSK_TUNNEL_A"
    xfrm_if_id      = 101
    bgp_local_ip    = "169.254.21.2"
    bgp_remote_ip   = "169.254.21.1"
    bgp_inside_cidr = "169.254.21.0/30"
    remote_asn      = 64514
    vm_index        = 0
  },
  {
    name            = "tunnel-b"
    peer_public_ip  = "203.0.113.11" # GCP HA VPN interface 1 IP
    psk_var_name    = "PSK_TUNNEL_B"
    xfrm_if_id      = 102
    bgp_local_ip    = "169.254.22.2"
    bgp_remote_ip   = "169.254.22.1"
    bgp_inside_cidr = "169.254.22.0/30"
    remote_asn      = 64514
    vm_index        = 0
  },
]

# PSKs: NEVER put real values in any tfvars file. Supply at apply time:
#   export TF_VAR_tunnel_psks='{"PSK_TUNNEL_A":"...","PSK_TUNNEL_B":"..."}'
```

- [ ] **Step 2: `params/schema.md`** — table per SPEC §4 documenting every variable: name, type, required, default, semantics, validation rules, AWS-vs-GCP mapping notes (AWS: 2 tunnels per VPN connection, PSKs pulled from AWS outputs; GCP: 2 HA VPN interfaces, PSKs chosen by us). Document `tunnel_psks` env-only convention and `customer_cidrs` role in prefix filters + overlap guard.

- [ ] **Step 3: Commit** — `git add params && git commit -m "params: example tfvars + full variable schema docs"`

---

### Task 9: Test scripts (`scripts/`)

**Files:**
- Create: `scripts/lib.sh`, `scripts/verify.sh`, `scripts/verify-security.sh`, `scripts/failover-test.sh`, `scripts/rekey-test.sh`, `scripts/mtu-test.sh`

All scripts: `#!/usr/bin/env bash`, `set -euo pipefail` (except where a probe must be allowed to fail), PASS/FAIL summary, non-zero exit on any failure. Config via env: `VPN_HOST` (Crusoe VM public IP), `VPN_SSH_USER` (default `ubuntu`), `VPN_SSH_KEY`, `REMOTE_TEST_IP` (customer-side test VM private IP), `LOCAL_TEST_IP`.

- [ ] **Step 1: `scripts/lib.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for VPN test scripts. Source, don't execute.

: "${VPN_SSH_USER:=ubuntu}"
: "${VPN_SSH_OPTS:=-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes}"

PASS_COUNT=0
FAIL_COUNT=0

vssh() { # vssh <host> <cmd...>
  local host=$1; shift
  # shellcheck disable=SC2086
  ssh $VPN_SSH_OPTS ${VPN_SSH_KEY:+-i "$VPN_SSH_KEY"} "${VPN_SSH_USER}@${host}" "$@"
}

assert() { # assert <description> <cmd...>
  local desc=$1; shift
  if "$@"; then
    echo "PASS: $desc"; PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "FAIL: $desc"; FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

retry() { # retry <attempts> <sleep_s> <cmd...>
  local n=$1 s=$2; shift 2
  local i
  for ((i=1; i<=n; i++)); do
    if "$@"; then return 0; fi
    sleep "$s"
  done
  return 1
}

summary() {
  echo "----------------------------------------"
  echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}

require_env() {
  local missing=0 v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then echo "ERROR: env $v is required" >&2; missing=1; fi
  done
  [ "$missing" -eq 0 ] || exit 2
}
```

- [ ] **Step 2: `scripts/verify.sh`** (Phases 2–3 quick check)

```bash
#!/usr/bin/env bash
# End-to-end control+data plane verification. Exits non-zero on any failure.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST REMOTE_TEST_IP

echo "== Control plane =="
assert "IKE SAs ESTABLISHED for all tunnels" \
  bash -c "vssh \$VPN_HOST sudo swanctl --list-sas | grep -c ESTABLISHED | grep -qvw 0"
assert "CHILD_SAs INSTALLED" \
  bash -c "vssh \$VPN_HOST sudo swanctl --list-sas | grep -q INSTALLED"
assert "all BGP sessions Established" \
  bash -c "vssh \$VPN_HOST sudo vtysh -c 'show bgp summary json' | python3 -c '
import json,sys
d=json.load(sys.stdin)
peers=d.get(\"ipv4Unicast\",{}).get(\"peers\",{})
sys.exit(0 if peers and all(p[\"state\"]==\"Established\" for p in peers.values()) else 1)'"
assert "customer prefixes present in RIB via BGP" \
  bash -c "vssh \$VPN_HOST 'ip route show proto bgp | grep -q .'"

echo "== Data plane =="
assert "ICMP to remote test host" \
  bash -c "vssh \$VPN_HOST ping -c 4 -W 2 \$REMOTE_TEST_IP > /dev/null"
assert "TCP path works (ssh port probe or iperf3)" \
  bash -c "vssh \$VPN_HOST timeout 10 bash -c \"true &>/dev/tcp/\$REMOTE_TEST_IP/22 || iperf3 -c \$REMOTE_TEST_IP -t 3 &>/dev/null\""

summary
```

- [ ] **Step 3: `scripts/mtu-test.sh`**

```bash
#!/usr/bin/env bash
# MTU/MSS validation: DF-bit boundary probes + large transfer must not stall.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST REMOTE_TEST_IP
: "${TUNNEL_MTU:=1400}"

# ICMP payload = MTU - 28 (IP+ICMP headers)
FIT=$((TUNNEL_MTU - 28))
TOOBIG=$((TUNNEL_MTU + 100 - 28))

assert "DF ping at tunnel MTU (${FIT}B payload) succeeds" \
  bash -c "vssh \$VPN_HOST ping -M do -s $FIT -c 3 -W 2 \$REMOTE_TEST_IP > /dev/null"
assert "DF ping above tunnel MTU (${TOOBIG}B payload) is rejected locally (no blackhole)" \
  bash -c "vssh \$VPN_HOST ping -M do -s $TOOBIG -c 2 -W 2 \$REMOTE_TEST_IP 2>&1 | grep -qiE 'message too long|frag needed'"
# Large transfer proves MSS clamp end-to-end (10MB over TCP must complete)
assert "10MB TCP transfer completes without stalling" \
  bash -c "vssh \$VPN_HOST 'timeout 60 iperf3 -c \$REMOTE_TEST_IP -n 10M' > /dev/null"

summary
```

- [ ] **Step 4: `scripts/failover-test.sh`**

```bash
#!/usr/bin/env bash
# Bring tunnel A down, assert traffic continues over tunnel B, restore, assert re-establishment.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST REMOTE_TEST_IP TUNNEL_A_NAME
: "${MAX_LOSS_PCT:=25}"       # documented bound: reconverge within ~30s of a 120s ping window
: "${RECONVERGE_TIMEOUT:=90}"

echo "Starting background ping (120s window)..."
vssh "$VPN_HOST" "nohup ping -i 0.5 -w 120 $REMOTE_TEST_IP > /tmp/failover-ping.log 2>&1 &"
sleep 5

echo "Terminating IKE SA for $TUNNEL_A_NAME..."
vssh "$VPN_HOST" "sudo swanctl --terminate --ike $TUNNEL_A_NAME --timeout 10 || true"
# prevent immediate trap re-establishment during the window
vssh "$VPN_HOST" "sudo ip link set ipsec\$(sudo swanctl --list-conns | grep -A2 $TUNNEL_A_NAME | grep -o 'if_id_in = [0-9]*' | grep -o '[0-9]*' | head -1) down 2>/dev/null || true"

echo "Waiting for BGP reconvergence..."
assert "BGP reconverges within ${RECONVERGE_TIMEOUT}s (route still present)" \
  retry $((RECONVERGE_TIMEOUT / 5)) 5 bash -c "vssh \$VPN_HOST 'ip route show proto bgp | grep -q .'"
assert "traffic continues during failover" \
  bash -c "vssh \$VPN_HOST ping -c 5 -W 2 \$REMOTE_TEST_IP > /dev/null"

echo "Restoring tunnel A..."
vssh "$VPN_HOST" "sudo /usr/local/sbin/vpn-xfrm-up.sh && sudo swanctl --initiate --ike $TUNNEL_A_NAME --timeout 30 || true"
assert "tunnel A re-established" \
  retry 12 10 bash -c "vssh \$VPN_HOST sudo swanctl --list-sas | grep -q \"$TUNNEL_A_NAME.*ESTABLISHED\""

echo "Analyzing ping loss over failover window..."
sleep 120 & wait $! 2>/dev/null || true
LOSS=$(vssh "$VPN_HOST" "grep -o '[0-9.]*% packet loss' /tmp/failover-ping.log | grep -o '^[0-9.]*'" || echo 100)
assert "packet loss ${LOSS}% <= ${MAX_LOSS_PCT}%" \
  bash -c "awk -v l=$LOSS -v m=$MAX_LOSS_PCT 'BEGIN{exit !(l<=m)}'"

summary
```

- [ ] **Step 5: `scripts/rekey-test.sh`**

```bash
#!/usr/bin/env bash
# Force IKE and CHILD rekey; assert a concurrent ping sees no drop.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST REMOTE_TEST_IP TUNNEL_A_NAME

vssh "$VPN_HOST" "nohup ping -i 0.2 -w 60 $REMOTE_TEST_IP > /tmp/rekey-ping.log 2>&1 &"
sleep 3
assert "CHILD_SA rekey succeeds" \
  bash -c "vssh \$VPN_HOST sudo swanctl --rekey --child \$TUNNEL_A_NAME --timeout 30"
sleep 5
assert "IKE_SA rekey succeeds" \
  bash -c "vssh \$VPN_HOST sudo swanctl --rekey --ike \$TUNNEL_A_NAME --timeout 30"
sleep 55
LOSS=$(vssh "$VPN_HOST" "grep -o '[0-9.]*% packet loss' /tmp/rekey-ping.log | grep -o '^[0-9.]*'" || echo 100)
assert "zero packet loss across rekeys (got ${LOSS}%)" \
  bash -c "awk -v l=$LOSS 'BEGIN{exit !(l==0)}'"
assert "SAs still ESTABLISHED post-rekey" \
  bash -c "vssh \$VPN_HOST sudo swanctl --list-sas | grep -q ESTABLISHED"

summary
```

- [ ] **Step 6: `scripts/verify-security.sh`**

```bash
#!/usr/bin/env bash
# Security posture checks. Run from a NON-allow-listed source unless noted.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST

echo "== External surface (from this machine; expected NOT allow-listed) =="
assert "SSH (22/tcp) filtered from non-allow-listed source" \
  bash -c "! nc -z -w 5 \$VPN_HOST 22"
assert "no unexpected TCP ports open (top 1000)" \
  bash -c "nmap -Pn --open -T4 \$VPN_HOST -oG - | grep -q '0 hosts up\\|Ports:' && ! nmap -Pn --open -T4 \$VPN_HOST -oG - | grep -oE '[0-9]+/open/tcp' | grep -q ."

echo "== On-box config assertions (needs allow-listed SSH; set VPN_SSH_VIA=1 to run) =="
if [ "${VPN_SSH_VIA:-0}" = "1" ]; then
  assert "IKEv2 only in swanctl config" \
    bash -c "vssh \$VPN_HOST 'sudo grep -q \"version = 2\" /etc/swanctl/conf.d/tunnels.conf && ! sudo grep -q \"version = 1\" /etc/swanctl/conf.d/tunnels.conf'"
  assert "secrets file is 0600" \
    bash -c "vssh \$VPN_HOST 'stat -c %a /etc/swanctl/conf.d/tunnels.secrets.conf | grep -q 600'"
  assert "PFS: CHILD_SA negotiated a DH group" \
    bash -c "vssh \$VPN_HOST sudo swanctl --list-sas | grep -qE 'ECP_384|MODP_2048|CURVE_'"
  assert "password auth disabled" \
    bash -c "vssh \$VPN_HOST 'sudo sshd -T | grep -q \"passwordauthentication no\"'"
  assert "nftables default-deny active" \
    bash -c "vssh \$VPN_HOST 'sudo nft list chain inet filter input | grep -q \"policy drop\"'"
fi

echo "== Negative IKE probes (requires ike-scan installed locally) =="
if command -v ike-scan >/dev/null; then
  assert "IKEv1 rejected (no handshake returned)" \
    bash -c "! sudo ike-scan -M \$VPN_HOST 2>/dev/null | grep -q 'Handshake returned'"
  assert "weak IKEv1 aggressive-mode DH1 proposal rejected" \
    bash -c "! sudo ike-scan -A --trans=1,1,1,1 \$VPN_HOST 2>/dev/null | grep -q 'Handshake returned'"
else
  echo "SKIP: ike-scan not installed (IKEv1/weak-proposal probes)"
fi

summary
```

- [ ] **Step 7: `scripts/healthcheck.sh`** — SPEC §12 pollable health signal; exit 0 only if every IKE SA ESTABLISHED, every CHILD_SA INSTALLED, every BGP peer Established, every `ipsec*` interface up:

```bash
#!/usr/bin/env bash
# Monitoring-pollable health check. Run ON the VPN VM (or via: ssh vm sudo healthcheck.sh).
set -uo pipefail
rc=0
sas=$(swanctl --list-sas 2>/dev/null)
conns=$(swanctl --list-conns 2>/dev/null | grep -cE '^[a-z0-9-]+:' || echo 0)
est=$(grep -c ESTABLISHED <<<"$sas" || true)
inst=$(grep -c INSTALLED <<<"$sas" || true)
[ "$est" -ge "$conns" ] && [ "$conns" -gt 0 ] || { echo "CRIT: IKE SAs $est/$conns established"; rc=1; }
[ "$inst" -ge "$conns" ] || { echo "CRIT: CHILD_SAs $inst/$conns installed"; rc=1; }
vtysh -c 'show bgp summary json' 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
peers=d.get("ipv4Unicast",{}).get("peers",{})
bad=[ip for ip,p in peers.items() if p["state"]!="Established"]
if not peers: print("CRIT: no BGP peers configured"); sys.exit(1)
if bad: print("CRIT: BGP not Established:", ",".join(bad)); sys.exit(1)' || rc=1
for ifc in $(ip -o link show type xfrm | awk -F': ' '{print $2}'); do
  ip link show "$ifc" | grep -q 'state UP\|UNKNOWN' || { echo "CRIT: $ifc down"; rc=1; }
done
[ $rc -eq 0 ] && echo "OK: all tunnels, SAs, BGP sessions healthy"
exit $rc
```

Install it from the startup script (Task 4: add a heredoc writing `/usr/local/sbin/vpn-healthcheck.sh`, mode 0755). Journald retention: startup script sets `SystemMaxUse=500M` in `/etc/systemd/journald.conf.d/vpn.conf` (charon + FRR log to syslog/journald by default) — covers SPEC §12 log retention. Document alert signals + metrics list in `docs/runbook.md` §Observability (Task 11).

- [ ] **Step 8: Lint** — `shellcheck scripts/*.sh` (accept SC2086 where deliberately unquoted, annotate). `bash -n scripts/*.sh`. Expected: clean.

- [ ] **Step 9: `chmod +x scripts/*.sh`; commit** — `git commit -am "scripts: verify, security, failover, rekey, MTU test suite with shared lib"`

---

### Task 10: CI workflow (`.github/workflows/ci.yml`)

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write workflow**

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]

jobs:
  static:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.5"

      - name: terraform fmt
        run: terraform fmt -check -recursive site-to-site-vpn/terraform

      - name: terraform validate (all modules)
        run: |
          for d in site-to-site-vpn/terraform/crusoe site-to-site-vpn/terraform/gcp site-to-site-vpn/terraform/aws; do
            terraform -chdir="$d" init -backend=false -input=false
            terraform -chdir="$d" validate
          done

      - name: tflint
        uses: terraform-linters/setup-tflint@v4
      - run: |
          cd site-to-site-vpn && tflint --init && tflint --recursive

      - name: tfsec
        uses: aquasecurity/tfsec-action@v1.0.3
        with:
          working_directory: site-to-site-vpn/terraform
          soft_fail: false

      - name: template render dry-run
        run: bash site-to-site-vpn/tests/render/check.sh

      - name: secret-leak scan
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: no real tfvars or state tracked
        run: |
          bad=$(git ls-files | grep -E '\.(tfstate|tfvars)$' | grep -v 'params\.example\.tfvars' || true)
          if [ -n "$bad" ]; then echo "Tracked secret-bearing files: $bad"; exit 1; fi
```

Adjust paths if this dir is its own repo root (drop `site-to-site-vpn/` prefixes).

- [ ] **Step 2: Negative-test overlap precondition locally** — `terraform -chdir=terraform/crusoe plan -var-file=../../params/params.example.tfvars -var 'customer_cidrs=["10.100.0.0/16"]' -var 'tunnel_psks={PSK_TUNNEL_A="x",PSK_TUNNEL_B="x"}'` → Expected: FAIL with "CIDR overlap detected". Record command in `tests/README.md`.

- [ ] **Step 3: Commit** — `git commit -am "ci: static phase 0 — fmt, validate, tflint, tfsec, render dry-run, secret scan"`

---

### Task 11: Docs

**Files:**
- Create: `docs/architecture.md`, `docs/runbook.md`, `docs/customer-gcp.md`, `docs/customer-aws.md`, `docs/crypto-profiles.md`, `docs/ip-planning.md`, `docs/outgrowing-this.md`, `tests/README.md`, `tests/matrix.md`

Content requirements per file (write full prose; each ~1-3 pages):

- [ ] **Step 1: `architecture.md`** — SPEC §2 ASCII diagram verbatim; design rationale: why route-based XFRM over policy-based (routing decides, BGP failover, no TS churn), why NAT-T assumed (UDP 4500 only through Crusoe firewall), single vs dual HA trade-offs, VTI fallback note for pre-4.19 kernels, tunnel model object walk-through.

- [ ] **Step 2: `runbook.md`** — SPEC §13's 8 sections. Troubleshoot section is a decision tree exactly per §13.6 with concrete commands per branch (`swanctl --list-sas`, `swanctl --log`, `journalctl -u strongswan`, `vtysh -c 'show bgp summary'`, `ip route show proto bgp`, `nft list ruleset`, tcpdump on udp 500/4500). Rotate section: update `TF_VAR_tunnel_psks`, `terraform apply` (startup_script change ⇒ VM replace — document alternative: SSH in, edit secrets file, `swanctl --load-creds`, `swanctl --rekey`, no drop). Deploy section: exact commands with `-var-file`.

- [ ] **Step 3: `customer-gcp.md`** — how a real customer (not our test module) provisions HA VPN: gateway, external VPN gateway (1-interface for `ha_mode=single`, 2-interface for dual), Cloud Router with their ASN, two tunnels with IKEv2 + our PSK convention, BGP sessions on the /30s, advertised routes; what values to read from our `handoff.txt`; console + gcloud command paths.

- [ ] **Step 4: `customer-aws.md`** — CGW per Crusoe public IP, S2S VPN on TGW (ECMP) or VGW, the 2-tunnels-2-PSKs model, how to hand AWS-generated PSKs to the Crusoe operator securely (secret manager / one-time link, never email), inside-CIDR constraints (169.254.0.0/16 minus AWS-reserved blocks), route table propagation.

- [ ] **Step 5: `crypto-profiles.md`** — SPEC §7: default profile table, per-cloud override examples (HCL snippets), the "check the provider's live cipher docs" warning as the #1 IKE-failure cause, links to AWS/GCP cipher doc pages, FIPS hook paragraph.

- [ ] **Step 6: `ip-planning.md`** — SPEC §9: overlap hazards, the Terraform precondition behavior (what the failure looks like), /30 allocation convention (169.254.21.0/30 upward, avoiding AWS-reserved 169.254.169.252/30 etc.), per-customer isolation model, non-transitive peering warning, NAT escape hatch.

- [ ] **Step 7: `outgrowing-this.md`** — throughput ceiling of software IPsec on a VM, single-VM SPOF, when to graduate to physical/partner interconnect, migration outline (parallel-run, BGP local-pref cutover).

- [ ] **Step 8: `tests/README.md`** — how to run each phase (0 locally + CI; 1–6 against GCP dev: required env vars per script, order, expected output). `tests/matrix.md` — table: date, terraform version, crusoe provider 0.5.44, google provider, ubuntu 24.04, strongswan/frr package versions, result. Seed with "not yet run" row.

- [ ] **Step 9: Finalize `README.md`** — quickstart (5 commands), architecture summary + diagram link, tested-against link, security notes (no secrets, PSK env convention), HA modes, link map to all docs. Note open platform question: Crusoe-level IP-forwarding/source-dest-check (SPEC §17) — validated during first live deploy.

- [ ] **Step 10: Commit** — `git commit -am "docs: architecture, runbook, customer guides, crypto/ip-planning, test docs"`

---

### Task 12: Final self-review + static gate

- [ ] **Step 1: Full static pass** — run every Phase 0 check locally:

```bash
terraform fmt -check -recursive terraform
for d in terraform/crusoe terraform/gcp terraform/aws; do terraform -chdir=$d init -backend=false && terraform -chdir=$d validate; done
bash tests/render/check.sh
shellcheck scripts/*.sh
git ls-files | grep -E '\.(tfstate|tfvars)$' | grep -v example && echo LEAK || echo clean
```
Expected: all PASS/clean.

- [ ] **Step 2: Spec coverage check** — walk SPEC §16 Definition of Done; confirm each checkbox maps to a delivered file. Known deliberate deviations to record in README: (a) `startup-script.sh.tftpl` instead of cloud-init YAML (provider reality); (b) VPC/subnet consumed not created (no provider resource); (c) `.terraform.lock.hcl` ignored vs committed — decide: commit lock files (reproducibility) → remove from .gitignore if so.

- [ ] **Step 3: Commit + done** — `git commit -am "final: static gates green, spec coverage review"`

---

## Deferred to live-deploy session (not in this plan)
- Phase 1–6 execution against real Crusoe + GCP projects (needs credentials).
- Baseline throughput floor / failover-loss bounds for `tests/matrix.md` (SPEC §17).
- Confirming Crusoe platform-level forwarding behavior (SPEC §17).
- `destination_ports = "500,4500"` comma-list acceptance (fallback documented in Task 3).
