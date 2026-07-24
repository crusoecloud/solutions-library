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
assert_not_grep nftables.conf 'vxlan-ceg'                        "cluster-egress rules absent when disabled"

# nftables with cluster_egress enabled
assert_grep nftables-ceg.conf 'udp dport 4789 accept'            "cluster-egress vxlan transport allowed"
assert_grep nftables-ceg.conf 'iifname "vxlan-ceg" accept'       "cluster-egress overlay forwarding"
assert_grep nftables-ceg.conf 'vxlan-ceg" tcp flags syn'         "cluster-egress overlay MSS clamp"

# secrets assertions
assert_grep tunnels.secrets.conf 'ike-tunnel-a \{'               "secret block per tunnel"
assert_grep tunnels.secrets.conf 'id = 203\.0\.113\.10'          "secret id is peer IP"
assert_grep tunnels.secrets.conf 'secret = "fixture-psk-aaaaaaaa"' "PSK injected from map"

# xfrm script assertions (+ rendered-shell syntax check)
assert_grep vpn-xfrm-up.sh 'ip link add "ipsec101" type xfrm'    "xfrm interface per tunnel"
assert_grep vpn-xfrm-up.sh 'mtu 1400'                            "tunnel MTU applied"
assert_grep vpn-xfrm-up.sh '169\.254\.21\.2/30'                  "BGP /30 address, mask from inside CIDR"
if bash -n out/vpn-xfrm-up.sh 2>/dev/null; then say "PASS: xfrm script is valid bash"; else say "FAIL: xfrm script has bash syntax errors"; fail=1; fi

# handoff assertions
assert_grep handoff.txt 'Crusoe BGP ASN: 65000'                  "handoff carries local ASN"
assert_grep handoff.txt 'Crusoe endpoint public IP: 192\.0\.2\.10' "handoff maps tunnel to VM endpoint"
assert_not_grep handoff.txt 'fixture-psk'                        "no PSKs in handoff"

# full bootstrap render: a syntax error in any template fails here, not at first apply
if bash -n out/startup-script.sh 2>/dev/null; then say "PASS: rendered startup script is valid bash"; else say "FAIL: rendered startup script has bash syntax errors"; fail=1; fi
assert_grep startup-script.sh 'sysctl --system'                  "bootstrap applies sysctls"
assert_grep startup-script.sh 'systemctl restart strongswan'     "bootstrap (re)starts strongswan"
assert_grep startup-script.sh 'vpn-cluster-egress'               "cluster-egress unit installed when enabled"
assert_grep startup-script.sh 'snat_mode=gateway'                "snat_mode=gateway does SNAT"
assert_grep startup-script.sh 'snat to'                          "gateway-mode SNAT rule present"
# node mode: no SNAT, overlay advertised via BGP
assert_grep startup-script-node.sh 'snat_mode=node'              "snat_mode=node branch"
assert_not_grep startup-script-node.sh 'snat to'                 "node mode has no SNAT"
assert_grep frr-node.conf 'network 169.254.0.0/16'              "node mode advertises overlay via BGP"
assert_grep frr-node.conf 'CRUSOE-OUT seq 10 permit 169.254.0.0/16' "overlay in outbound prefix filter"

exit $fail
