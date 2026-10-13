# Crypto profiles

The Crusoe module ships one default profile per cloud (selected by
`var.cloud` when `crypto_profile = null`). Both defaults are currently
identical — a strong-crypto intersection of AWS and GCP support — and live in
`locals.crypto_defaults` in `terraform/crusoe/main.tf`.

## Default profile

| Parameter | Default (gcp and aws) | Where it lands |
|---|---|---|
| IKE proposals | `aes256gcm16-prfsha384-ecp384`, fallback `aes256-sha384-modp2048` | `proposals` in swanctl.conf |
| ESP proposals | `aes256gcm16-ecp384` (PFS: DH group in the ESP proposal) | `esp_proposals` |
| IKE lifetime | `8h` | `rekey_time` (connection) |
| ESP lifetime | `1h` | `rekey_time` (child) |
| DPD delay / timeout | `30s` / `120s` | `dpd_delay` (timeout enforced by retransmission policy) |
| Rekey margin | `3m` | wired as `over_time` (IKE) and `rand_time` (child) |
| IKE version | 2 only (`version = 2`) | IKEv1 is never offered or accepted |
| NAT-T | forced (`encap = yes`) | UDP 4500 |
| MOBIKE | off (`mobike = no`) | fixed endpoints |

In strongSwan notation: `aes256gcm16` = AES-256-GCM with 16-byte ICV (AEAD,
no separate integrity algorithm), `prfsha384` = PRF, `ecp384` = DH group 20,
`modp2048` = DH group 14. The CBC fallback (`aes256-sha384-modp2048`) exists
for peers that don't negotiate GCM; remove it if your policy demands
AEAD-only.

## Overriding per deployment

Set `crypto_profile` in `params/params.tfvars` (all fields required when
overriding):

```hcl
crypto_profile = {
  ike_proposals = ["aes256gcm16-prfsha384-ecp384"] # AEAD-only, no CBC fallback
  esp_proposals = ["aes256gcm16-ecp384"]
  ike_lifetime  = "8h"
  esp_lifetime  = "1h"
  dpd_delay     = "30s"
  dpd_timeout   = "120s"
  rekey_margin  = "3m"
}
```

AWS-side tunnel options must mirror this. The `terraform/aws/` module pins
the matching set: phase 1 `AES256-GCM-16` / `SHA2-384` / DH 20; phase 2
`AES256-GCM-16` / DH 20. GCP negotiates from its supported list, so only the
Crusoe side needs the override there.

## The #1 IKE-failure cause

> **Both clouds revise their supported cipher lists.** Before trusting any
> profile in production — and whenever IKE fails with
> `NO_PROPOSAL_CHOSEN` — check the provider's **live** documentation, not
> this repo:
>
> - AWS: [Tunnel options for your Site-to-Site VPN connection](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPNTunnels.html)
> - GCP: [Supported IKE ciphers for Cloud VPN](https://cloud.google.com/network-connectivity/docs/vpn/concepts/supported-ike-ciphers)
>
> A proposal that was valid at build time can stop matching after a provider
> update. Treat mismatched proposals as the first suspect for "IKE won't come
> up" (runbook §6.1).

## FIPS hook

Not implemented in v1, but the seam exists: if a customer requires FIPS,
build/obtain a FIPS-validated strongSwan (e.g., Ubuntu Pro FIPS packages or a
certified build against a FIPS OpenSSL provider) on the VPN VM image, and
constrain `crypto_profile` to the algorithms permitted by their policy — for
example, drop GCM if their profile forbids AEAD-only suites, keep SHA-384 and
DH groups 14/20. Everything is a variable; no template changes are needed.
Certificate-based IKE auth (running a small PKI instead of PSKs) is the other
documented hardening upgrade, also not automated in v1.
