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
