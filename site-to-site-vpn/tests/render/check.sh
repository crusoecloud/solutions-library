#!/usr/bin/env bash
# Template render dry-run: render via terraform apply (local_file only), grep required stanzas.
set -euo pipefail
cd "$(dirname "$0")"
fail=0
say() { printf '%s\n' "$*"; }
assert_grep() { # file pattern description
  [ -f "out/$1" ] || { say "FAIL: $3 (out/$1 missing)"; fail=1; return; }
  if grep -qE "$2" "out/$1"; then say "PASS: $3"; else say "FAIL: $3 (pattern '$2' missing in out/$1)"; fail=1; fi
}
assert_not_grep() {
  [ -f "out/$1" ] || { say "FAIL: $3 (out/$1 missing)"; fail=1; return; }
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
assert_grep swanctl.conf 'over_time = 3m'              "rekey_margin wired as over_time"
assert_grep swanctl.conf 'rand_time = 3m'              "rekey_margin wired as rand_time"

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
