# Variable Schema — `terraform/crusoe/`

Source of truth: `terraform/crusoe/variables.tf`. All variables are for the
Crusoe-side root module. Customer-side module variables (`terraform/gcp/`,
`terraform/aws/`) are documented in the GCP and AWS mapping sections below.

---

## Top-level variables

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `deployment_name` | `string` | yes | — | Prefix for all resources. Must be DNS-safe. |
| `cloud` | `string` | yes | — | Peer cloud. Controls default crypto profile. |
| `ha_mode` | `string` | no | `"single"` | HA topology. |
| `crusoe_project_id` | `string` | yes | — | Crusoe project UUID. |
| `crusoe_location` | `string` | yes | — | Crusoe location, e.g. `us-east1-a`. |
| `crusoe_vpc_subnet_id` | `string` | yes | — | Existing Crusoe VPC subnet UUID. |
| `crusoe_vpc_cidrs` | `list(string)` | yes | — | CIDRs Crusoe side advertises via BGP. |
| `customer_cidrs` | `list(string)` | yes | — | CIDRs expected from the customer peer via BGP. |
| `instance_type` | `string` | no | `"c1a.4x"` | Crusoe instance type for VPN VM(s). |
| `image` | `string` | no | `"ubuntu24.04:latest"` | Crusoe image string. |
| `local_asn` | `number` | yes | — | Crusoe-side private BGP ASN. |
| `ssh_allowed_cidrs` | `list(string)` | yes | — | Management SSH allow-list. |
| `ssh_public_keys` | `list(string)` | yes | — | SSH public keys injected at VM create time. |
| `mss_clamp` | `number` | no | `1360` | TCP MSS clamp applied in nftables forward chain. |
| `tunnel_mtu` | `number` | no | `1400` | XFRM interface MTU set by `ip link set ... mtu`. |
| `tunnels` | `list(object)` | yes | — | Ordered tunnel definitions. See sub-table below. |
| `tunnel_psks` | `map(string)` | yes | — | PSK map. **Env-only — never in tfvars.** |
| `crypto_profile` | `object` | no | `null` | Override IKE/ESP proposals. `null` = cloud default. |

### Validations

| Variable | Rule |
|---|---|
| `deployment_name` | `^[a-z][a-z0-9-]{1,30}$` — lowercase alphanumeric + hyphens, 2–31 chars. |
| `cloud` | Must be `"gcp"` or `"aws"`. |
| `ha_mode` | Must be `"single"` or `"dual"`. |
| `crusoe_vpc_cidrs` | Every entry must be a valid CIDR (`cidrhost` parseable). |
| `customer_cidrs` | Every entry must be a valid CIDR. |
| `local_asn` | Private ASN: 64512–65534 or 4200000000–4294967294. |
| `ssh_allowed_cidrs` | Non-empty; must not contain `0.0.0.0/0`. |
| `ssh_public_keys` | At least one key required. |
| `mss_clamp` | `mss_clamp <= tunnel_mtu - 40` (prevents negative effective payload). |
| `tunnel_psks` | Every value: length ≥ 16, charset `[A-Za-z0-9+/=_.-]` (no quotes, backslashes, spaces, or newlines). |
| CIDR overlap guard | `crusoe_vpc_cidrs`, `customer_cidrs`, and each tunnel's `bgp_inside_cidr` must not overlap each other. Enforced via `terraform_data.cidr_overlap_guard` precondition. |

---

## `tunnels` object fields

Each element of the `tunnels` list is an object with these fields:

| Field | Type | Description |
|---|---|---|
| `name` | `string` | Tunnel identifier. Used as the strongSwan connection name, CHILD SA name, and FRR neighbor description. |
| `peer_public_ip` | `string` | Public IP of the remote gateway (GCP HA VPN interface or AWS outside IP). |
| `psk_var_name` | `string` | Key into `tunnel_psks` map. e.g. `"PSK_TUNNEL_A"`. |
| `xfrm_if_id` | `number` | XFRM interface ID. Maps to `ipsec<N>` interface name and strongSwan `if_id_in`/`if_id_out`. Must be unique across all tunnels. |
| `bgp_local_ip` | `string` | Crusoe's BGP IP on the tunnel link (the `/30` host .2 for GCP, .2 for AWS by convention). |
| `bgp_remote_ip` | `string` | Remote peer's BGP IP on the tunnel link (host .1). Used as FRR neighbor address. |
| `bgp_inside_cidr` | `string` | The /30 link-local CIDR encompassing both `bgp_local_ip` and `bgp_remote_ip`. Must be unique across tunnels and must not overlap `crusoe_vpc_cidrs` or `customer_cidrs`. |
| `remote_asn` | `number` | BGP ASN of the remote peer (GCP Cloud Router ASN or AWS Transit Gateway ASN). |
| `vm_index` | `number` | Index (0 or 1) of the Crusoe VM this tunnel terminates on. With `ha_mode = "single"` all tunnels must use `vm_index = 0`. With `ha_mode = "dual"` distribute tunnels across 0 and 1. |

### Tunnel name validation

`name` must match `^[a-z][a-z0-9-]{0,30}$` — lowercase alphanumeric + hyphens, starts with a letter, max 31 chars. All names must be unique within the list.

---

## `tunnel_psks` — env-only convention

`tunnel_psks` is `sensitive = true`. Its values are embedded in the VM startup
script and are visible in Terraform state and in Crusoe instance metadata to
anyone with instance-describe access. From the variable description:

> "WARNING: PSKs are embedded in the instance startup script — they are visible
> in Terraform state and in Crusoe instance metadata to anyone with
> instance-describe access. Encrypt state at rest, restrict state access, and
> rotate PSKs if exposure is suspected."

**Never put PSKs in any `.tfvars` file.** Supply them at apply time via
environment:

```bash
export TF_VAR_tunnel_psks='{"PSK_TUNNEL_A":"your-32-char-random-here","PSK_TUNNEL_B":"another-32-char-random-here"}'
terraform apply -var-file=params/params.example.tfvars
```

PSK requirements (enforced by validation):
- Minimum 16 characters.
- Charset: `[A-Za-z0-9+/=_.-]` — no quotes, backslashes, spaces, or newlines.
- Recommended: 32+ chars of random base64 (`openssl rand -base64 32 | tr -d '='`).

---

## GCP mapping

GCP HA VPN creates **one gateway with two interfaces**, each with its own public
IP. Each interface maps to one tunnel.

| Concept | GCP side | Crusoe `tunnels[*]` field |
|---|---|---|
| HA VPN interface 0 public IP | `gw.vpn_interfaces[0].ip_address` | `tunnels[0].peer_public_ip` |
| HA VPN interface 1 public IP | `gw.vpn_interfaces[1].ip_address` | `tunnels[1].peer_public_ip` |
| Cloud Router ASN | `var.gcp_asn` (default 64514) | `tunnels[*].remote_asn` |
| BGP inside /30 for tunnel 0 | GCP takes host `.1`, Crusoe takes `.2` | `bgp_inside_cidr`, `bgp_local_ip = cidrhost(cidr, 2)`, `bgp_remote_ip = cidrhost(cidr, 1)` |
| BGP inside /30 for tunnel 1 | same convention | same |
| PSKs | Chosen by the operator | `tunnel_psks["PSK_TUNNEL_A"]`, `["PSK_TUNNEL_B"]` — **same values configured on both sides** |

Workflow: run `terraform apply` in `terraform/gcp/` first → capture
`gcp_vpn_public_ips` output → fill `peer_public_ip` in params → export PSKs
and apply `terraform/crusoe/`. The same PSK values are passed to both the
`crusoe` and `gcp` modules.

### `terraform/gcp/` variables

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `project_id` | `string` | yes | — | GCP project ID. |
| `region` | `string` | yes | — | GCP region for all resources. |
| `network_name` | `string` | no | `"vpn-test"` | Existing VPC network name (or set `create_network=true`). |
| `create_network` | `bool` | no | `true` | Create a new VPC + subnet when `true`. |
| `subnet_cidr` | `string` | no | `"10.200.0.0/16"` | GCP-side subnet CIDR (the customer CIDR). |
| `gcp_asn` | `number` | no | `64514` | Cloud Router ASN. |
| `crusoe_asn` | `number` | yes | — | Crusoe-side BGP ASN. |
| `crusoe_public_ips` | `list(string)` | yes | — | One or two Crusoe VPN VM public IPs. |
| `tunnel_psks` | `list(string)` | yes | — | Two PSKs (index 0/1). Sensitive. |
| `bgp_inside_cidrs` | `list(string)` | yes | — | Two link-local /30 CIDRs; GCP takes `.1`, Crusoe `.2`. |
| `crusoe_source_ranges` | `list(string)` | no | `["10.0.0.0/8"]` | Source ranges for the test firewall; tighten to `crusoe_vpc_cidrs`. |
| `deployment_name` | `string` | no | `"crusoe-vpn"` | Resource name prefix. |

---

## AWS mapping

AWS Site-to-Site VPN creates **one VPN connection with two tunnels**, each with
its own outside IP and its own AWS-generated PSK.

| Concept | AWS side | Crusoe `tunnels[*]` field |
|---|---|---|
| Tunnel 1 outside IP | `aws_vpn_connection.vpn.tunnel1_address` | `tunnels[0].peer_public_ip` |
| Tunnel 2 outside IP | `aws_vpn_connection.vpn.tunnel2_address` | `tunnels[1].peer_public_ip` |
| Transit Gateway ASN | `var.aws_asn` (default 64512) | `tunnels[*].remote_asn` |
| BGP inside /30 — tunnel 1 | Pin via `bgp_inside_cidrs[0]` or AWS auto-assigns | `tunnels[0].bgp_inside_cidr` — must use the value AWS actually assigned |
| BGP inside /30 — tunnel 2 | Pin via `bgp_inside_cidrs[1]` or AWS auto-assigns | `tunnels[1].bgp_inside_cidr` |
| PSKs | AWS-generated; pulled from `aws_tunnel_psks` output (sensitive) | Loaded into `TF_VAR_tunnel_psks` from module output |

**AWS-reserved inside ranges** — AWS excludes the following from the
169.254.0.0/16 space for customer tunnel CIDRs:
`169.254.0.0/30`, `169.254.1.0/30`, `169.254.2.0/30`, `169.254.3.0/30`,
`169.254.4.0/30`, `169.254.5.0/30`, `169.254.169.252/30` (and a few others).
When pinning, use ranges like `169.254.21.0/30` and `169.254.22.0/30`
(as in the example).

Workflow: run `terraform apply` in `terraform/aws/` first → capture
`aws_tunnel_public_ips` and `aws_tunnel_inside_cidrs` outputs → fill
`peer_public_ip` and `bgp_inside_cidr` fields in params → retrieve the
AWS-generated PSKs from the `aws_tunnel_psks` output and export them:

```bash
# Extract PSKs from AWS module output (sensitive — avoid logging)
PSK_A=$(terraform -chdir=terraform/aws output -json aws_tunnel_psks | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
PSK_B=$(terraform -chdir=terraform/aws output -json aws_tunnel_psks | python3 -c "import sys,json; print(json.load(sys.stdin)[1])")
export TF_VAR_tunnel_psks="{\"PSK_TUNNEL_A\":\"$PSK_A\",\"PSK_TUNNEL_B\":\"$PSK_B\"}"
terraform apply -chdir=terraform/crusoe -var-file=params/params.example.tfvars
```

Note: PSK validation (`length >= 16`, charset `[A-Za-z0-9+/=_.-]`) applies to
AWS-generated PSKs too. AWS generates RFC-compliant PSKs that satisfy this
constraint.

### `terraform/aws/` variables

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `region` | `string` | yes | — | AWS region for all resources. |
| `deployment_name` | `string` | no | `"crusoe-vpn"` | Resource name prefix. |
| `vpc_id` | `string` | yes | — | Existing customer VPC to attach the TGW to. |
| `subnet_ids` | `list(string)` | yes | — | Subnets for the TGW VPC attachment. |
| `aws_asn` | `number` | no | `64512` | Transit Gateway ASN. |
| `crusoe_asn` | `number` | yes | — | Crusoe-side BGP ASN. |
| `crusoe_public_ip` | `string` | yes | — | Crusoe VPN VM public IP (one CGW per Crusoe VM). |
| `bgp_inside_cidrs` | `list(string)` | no | `[]` | Zero or two inside /30 CIDRs. Empty = AWS auto-assigns. |
| `route_table_ids` | `list(string)` | no | `[]` | VPC route table IDs to receive return routes toward Crusoe. Empty = manage routes yourself. |
| `crusoe_cidrs` | `list(string)` | no | `[]` | Crusoe CIDRs to route toward the TGW from the customer VPC. |

---

## `crypto_profile` (optional override)

When `null` (the default), the module selects a built-in profile based on
`cloud`:

| Field | GCP default | AWS default |
|---|---|---|
| `ike_proposals` | `["aes256gcm16-prfsha384-ecp384", "aes256-sha384-modp2048"]` | same |
| `esp_proposals` | `["aes256gcm16-ecp384"]` | same |
| `ike_lifetime` | `8h` | `8h` |
| `esp_lifetime` | `1h` | `1h` |
| `dpd_delay` | `30s` | `30s` |
| `dpd_timeout` | `120s` | `120s` |
| `rekey_margin` | `3m` | `3m` |

To override, supply the full object (all fields required):

```hcl
crypto_profile = {
  ike_proposals = ["aes256-sha256-modp2048"]
  esp_proposals = ["aes256-sha256-modp2048"]
  ike_lifetime  = "24h"
  esp_lifetime  = "8h"
  dpd_delay     = "10s"
  dpd_timeout   = "60s"
  rekey_margin  = "5m"
}
```

See `docs/crypto-profiles.md` for pre-tested profiles and compliance notes.
