#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: all bash -c '...' strings are intentionally single-quoted so that
# env vars expand in the child shell (vars are exported before these calls).
# Security posture checks. Run from a NON-allow-listed source unless noted.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST

export VPN_HOST

echo "== External surface (from this machine; expected NOT allow-listed) =="

if [ "${CALLER_ALLOWLISTED:-0}" = "1" ]; then
  echo "SKIP: caller is in ssh_allowed_cidrs — SSH-filtered probe is meaningless from here"
elif command -v nc >/dev/null; then
  assert "SSH (22/tcp) filtered from non-allow-listed source" bash -c '
    ! nc -z -w 5 "$VPN_HOST" 22
  '
else
  echo "SKIP: nc not installed (SSH filtered check)"
fi

if command -v nmap >/dev/null; then
  _nmap_out=$(mktemp)
  nmap -Pn --open -T4 "$VPN_HOST" -oG - > "$_nmap_out" 2>&1
  _nmap_rc=$?
  if [ "$_nmap_rc" -ne 0 ]; then
    echo "FAIL: nmap exited $_nmap_rc (tool error — treating as FAIL, not SKIP)"
    FAIL_COUNT=$((FAIL_COUNT+1))
  else
    if [ "${CALLER_ALLOWLISTED:-0}" = "1" ]; then
      # From an allow-listed source, SSH (22) is legitimately reachable;
      # anything else open is a finding.
      assert "no TCP ports open besides allow-listed SSH (top 1000)" bash -c '
        ! grep -oE "[0-9]+/open/tcp" '"$_nmap_out"' | grep -v "^22/" | grep -q .
      '
    else
      assert "no unexpected TCP ports open (top 1000)" bash -c '
        ! grep -oE "[0-9]+/open/tcp" '"$_nmap_out"' | grep -q .
      '
    fi
  fi
  rm -f "$_nmap_out"
else
  echo "SKIP: nmap not installed (open ports check)"
fi

echo "== On-box config assertions (needs allow-listed SSH; set VPN_SSH_VIA=1 to run) =="
if [ "${VPN_SSH_VIA:-0}" = "1" ]; then
  assert "IKEv2 only in swanctl config" bash -c '
    vssh "$VPN_HOST" "sudo grep -q '"'"'version = 2'"'"' /etc/swanctl/conf.d/tunnels.conf && ! sudo grep -q '"'"'version = 1'"'"' /etc/swanctl/conf.d/tunnels.conf"
  '

  assert "secrets file is 0600" bash -c '
    vssh "$VPN_HOST" stat -c %a /etc/swanctl/conf.d/tunnels.secrets.conf | grep -q 600
  '

  assert "PFS: CHILD_SA negotiated a DH group" bash -c '
    vssh "$VPN_HOST" sudo swanctl --list-sas | grep -qE "ECP_384|MODP_2048|CURVE_"
  '

  assert "password auth disabled" bash -c '
    vssh "$VPN_HOST" sudo sshd -T | grep -q "passwordauthentication no"
  '

  assert "nftables default-deny active" bash -c '
    vssh "$VPN_HOST" sudo nft list chain inet filter input | grep -q "policy drop"
  '
fi

# NOTE: strongSwan pins responders to the configured peer IPs (remote_addrs),
# so an active IKE scan from any non-peer source gets no response regardless of
# IKE version — it cannot distinguish "IKEv1 rejected" from "source not a peer".
# The authoritative IKEv1-disabled evidence is the on-box config assertion above
# (version = 2, no version = 1). These probes are a best-effort extra signal;
# run them from a configured peer source for a meaningful positive control.
echo "== Negative IKE probes (requires ike-scan installed locally) =="
if command -v ike-scan >/dev/null; then
  assert "IKEv1 rejected (no handshake returned)" bash -c '
    ! sudo ike-scan -M "$VPN_HOST" 2>/dev/null | grep -q "Handshake returned"
  '

  assert "weak IKEv1 aggressive-mode DH1 proposal rejected" bash -c '
    ! sudo ike-scan -A --trans=1,1,1,1 "$VPN_HOST" 2>/dev/null | grep -q "Handshake returned"
  '
else
  echo "SKIP: ike-scan not installed (IKEv1/weak-proposal probes)"
fi

summary
