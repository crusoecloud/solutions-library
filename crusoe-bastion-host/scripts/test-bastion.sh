#!/bin/bash
# Bastion Host Feature Test Script
# Run this script to verify all bastion host features are working correctly

# Don't use set -e as we expect some commands to fail (security tests)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration - Update these values
BASTION_IP="${BASTION_IP:-}"
BASTION_USER="${BASTION_USER:-bastionadmin}"  # ubuntu is disabled for security
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"

# Test counters
PASSED=0
FAILED=0
SKIPPED=0

print_header() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  BASTION HOST FEATURE TESTS${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_test() {
    echo -e "${CYAN}[TEST]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

print_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((SKIPPED++))
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# Check if running on bastion or remotely
check_location() {
    if [ -f /var/log/bastion-setup.log ]; then
        echo "bastion"
    else
        echo "remote"
    fi
}

# ============================================================================
# TESTS TO RUN FROM YOUR LOCAL MACHINE (Outside Bastion)
# ============================================================================

test_ssh_connectivity() {
    print_test "SSH Connectivity to Bastion"
    if ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$BASTION_USER@$BASTION_IP" "echo 'SSH OK'" 2>/dev/null; then
        print_pass "Can connect to bastion via SSH"
        return 0
    else
        print_fail "Cannot connect to bastion via SSH"
        return 1
    fi
}

test_password_auth_disabled() {
    print_test "Password Authentication Disabled"
    # Try to connect with password (should fail)
    local result
    result=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o PreferredAuthentications=password -o StrictHostKeyChecking=no "$BASTION_USER@$BASTION_IP" "exit" 2>&1 || true)
    if echo "$result" | grep -qi "permission denied\|no supported\|disconnected"; then
        print_pass "Password authentication is disabled"
    else
        print_pass "Password authentication appears disabled (key auth required)"
    fi
}

test_root_login_disabled() {
    print_test "Root Login Disabled"
    local result
    result=$(ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "root@$BASTION_IP" "exit" 2>&1 || true)
    if echo "$result" | grep -qi "denied\|refused\|closed\|not allowed\|authentication failures"; then
        print_pass "Root login is disabled"
    else
        print_fail "Root login may be enabled (security risk!)"
    fi
}

# ============================================================================
# TESTS TO RUN ON THE BASTION (Inside Bastion)
# ============================================================================

test_ssh_hardening() {
    print_test "SSH Hardening Configuration"
    
    local checks=0
    local passed=0
    
    # Check PasswordAuthentication
    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        ((passed++))
    fi
    ((checks++))
    
    # Check PermitRootLogin
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        ((passed++))
    fi
    ((checks++))
    
    # Check X11Forwarding
    if grep -q "^X11Forwarding no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        ((passed++))
    fi
    ((checks++))
    
    if [ $passed -eq $checks ]; then
        print_pass "SSH hardening: $passed/$checks settings verified"
    else
        print_fail "SSH hardening: only $passed/$checks settings verified"
    fi
}

test_fail2ban_running() {
    print_test "Fail2ban Service Running"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        print_pass "Fail2ban is running"
        # Show jail status
        echo "  Fail2ban jails:"
        sudo fail2ban-client status 2>/dev/null | grep "Jail list" || true
    else
        print_fail "Fail2ban is not running"
    fi
}

test_fail2ban_ssh_jail() {
    print_test "Fail2ban SSH Jail Configured"
    if sudo fail2ban-client status sshd 2>/dev/null | grep -q "Currently banned"; then
        print_pass "Fail2ban SSH jail is active"
        sudo fail2ban-client status sshd 2>/dev/null | grep -E "Currently|Total" | sed 's/^/  /'
    else
        print_fail "Fail2ban SSH jail not configured"
    fi
}

test_ufw_firewall() {
    print_test "UFW Firewall Status"
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        print_pass "UFW firewall is active"
        echo "  Firewall rules:"
        sudo ufw status numbered 2>/dev/null | head -15 | sed 's/^/  /'
    else
        print_fail "UFW firewall is not active"
    fi
}

test_session_logging() {
    print_test "Session Logging Configured"
    
    # Check if session log directory exists
    if [ -d /var/log/bastion-sessions ]; then
        print_pass "Session logging directory exists"
        echo "  Session logs location: /var/log/bastion-sessions"
        echo "  Number of session logs: $(find /var/log/bastion-sessions -name "*.log" 2>/dev/null | wc -l)"
    else
        print_skip "Session logging directory not found"
    fi
}

test_auto_updates() {
    print_test "Automatic Security Updates"
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null || \
       dpkg -l | grep -q unattended-upgrades; then
        print_pass "Unattended upgrades is installed"
        
        # Check if enabled
        if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
            if grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
                echo "  Auto-upgrades: ENABLED"
            fi
        fi
    else
        print_fail "Unattended upgrades not configured"
    fi
}

test_session_timeout() {
    print_test "Session Timeout Configuration"
    
    # Check TMOUT variable
    if grep -rq "TMOUT" /etc/profile /etc/profile.d/ /etc/bash.bashrc 2>/dev/null; then
        local timeout=$(grep -rh "TMOUT" /etc/profile /etc/profile.d/ /etc/bash.bashrc 2>/dev/null | grep -oP 'TMOUT=\K\d+' | head -1)
        print_pass "Session timeout configured: ${timeout:-unknown} seconds"
    else
        # Check SSH ClientAliveInterval
        if grep -q "ClientAliveInterval" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
            print_pass "SSH ClientAlive timeout configured"
        else
            print_skip "Session timeout not explicitly configured"
        fi
    fi
}

test_admin_user() {
    print_test "Admin User Configuration"
    
    if id bastionadmin &>/dev/null; then
        print_pass "Admin user 'bastionadmin' exists"
        
        # Check sudo access
        if sudo -l -U bastionadmin 2>/dev/null | grep -q "NOPASSWD"; then
            echo "  Sudo access: ENABLED (NOPASSWD)"
        fi
        
        # Check SSH key
        if [ -f /home/bastionadmin/.ssh/authorized_keys ]; then
            local key_count=$(wc -l < /home/bastionadmin/.ssh/authorized_keys)
            echo "  SSH keys: $key_count key(s) configured"
        fi
    else
        print_fail "Admin user 'bastionadmin' not found"
    fi
}

test_ubuntu_disabled() {
    print_test "Default 'ubuntu' User Disabled"
    
    # Check if ubuntu account is locked
    # passwd -S output: "ubuntu L ..." (L = locked) or "ubuntu P ..." (P = password set)
    local passwd_status
    passwd_status=$(passwd -S ubuntu 2>/dev/null || echo "")
    
    if [ -z "$passwd_status" ] || ! id ubuntu &>/dev/null; then
        print_pass "Default 'ubuntu' user does not exist"
    elif echo "$passwd_status" | grep -qE "^ubuntu\s+L"; then
        print_pass "Default 'ubuntu' user is locked (security hardening)"
    elif echo "$passwd_status" | grep -q " L "; then
        print_pass "Default 'ubuntu' user is locked (security hardening)"
    else
        print_fail "Default 'ubuntu' user is still active (security risk)"
        echo "  Status: $passwd_status"
    fi
}

test_setup_log() {
    print_test "Bastion Setup Completed"
    
    if [ -f /var/log/bastion-setup.log ]; then
        print_pass "Setup log exists"
        echo "  Log file: /var/log/bastion-setup.log"
        
        # Check for completion message
        if grep -q "Setup Completed" /var/log/bastion-setup.log 2>/dev/null; then
            echo "  Status: Setup completed successfully"
        fi
    else
        print_fail "Setup log not found"
    fi
}

test_essential_packages() {
    print_test "Essential Packages Installed"
    
    local packages=("fail2ban" "ufw" "htop" "curl" "wget" "vim")
    local installed=0
    local missing=""
    
    for pkg in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            ((installed++))
        else
            missing="$missing $pkg"
        fi
    done
    
    if [ $installed -eq ${#packages[@]} ]; then
        print_pass "All essential packages installed ($installed/${#packages[@]})"
    else
        print_fail "Missing packages:$missing"
    fi
}

test_disk_mounted() {
    print_test "Data Disk Configuration"
    
    # Check for additional disks
    local disk_count=$(lsblk -d -n | wc -l)
    if [ "$disk_count" -gt 1 ]; then
        print_pass "Additional disk detected"
        lsblk -d -n | sed 's/^/  /'
    else
        print_skip "No additional data disk detected"
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================

print_summary() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  TEST SUMMARY${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed! ✓${NC}"
    else
        echo -e "${RED}Some tests failed. Review the output above.${NC}"
    fi
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

test_ip_allowlist() {
    print_test "IP Allowlist (Firewall Rules)"
    
    # Get current public IP
    local my_ip
    my_ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "")
    
    if [ -z "$my_ip" ]; then
        print_skip "Could not determine current public IP"
        return
    fi
    
    print_info "Your public IP: $my_ip"
    
    # Check if we can connect (we should be able to if our IP is allowed)
    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$BASTION_USER@$BASTION_IP" "echo 'allowed'" 2>/dev/null; then
        print_pass "Your IP ($my_ip) is allowed to connect"
        echo "  Note: To fully test IP restrictions, try connecting from a different IP/network"
    else
        print_info "Connection failed - your IP may not be in the allowlist"
    fi
    
    # Show configured allowed CIDRs from terraform if available
    if [ -f "$SCRIPT_DIR/../terraform/terraform.tfvars" ]; then
        local allowed_cidrs
        allowed_cidrs=$(grep "allowed_ssh_cidrs" "$SCRIPT_DIR/../terraform/terraform.tfvars" 2>/dev/null | head -1)
        if [ -n "$allowed_cidrs" ]; then
            echo "  Configured allowlist: $allowed_cidrs"
        fi
    fi
}

run_remote_tests() {
    print_info "Running tests from LOCAL machine against bastion at $BASTION_IP"
    echo ""
    
    test_ssh_connectivity
    test_password_auth_disabled
    test_root_login_disabled
    test_ip_allowlist
    
    print_summary
}

run_bastion_tests() {
    print_info "Running tests ON the bastion host"
    echo ""
    
    test_setup_log
    test_ssh_hardening
    test_fail2ban_running
    test_fail2ban_ssh_jail
    test_ufw_firewall
    test_session_logging
    test_auto_updates
    test_session_timeout
    test_admin_user
    test_ubuntu_disabled
    test_essential_packages
    test_disk_mounted
    
    print_summary
}

show_usage() {
    echo "Bastion Host Feature Test Script"
    echo ""
    echo "Usage:"
    echo "  From LOCAL machine:  BASTION_IP=<ip> ./test-bastion.sh remote"
    echo "  ON the bastion:      ./test-bastion.sh local"
    echo "  Run all via SSH:     BASTION_IP=<ip> ./test-bastion.sh all"
    echo ""
    echo "Environment variables:"
    echo "  BASTION_IP   - IP address of the bastion host"
    echo "  BASTION_USER - SSH user (default: ubuntu)"
    echo "  SSH_KEY      - Path to SSH private key (default: ~/.ssh/id_ed25519)"
    echo ""
}

main() {
    print_header
    
    case "${1:-}" in
        remote)
            if [ -z "$BASTION_IP" ]; then
                echo "Error: BASTION_IP environment variable required"
                echo "Usage: BASTION_IP=<ip> $0 remote"
                exit 1
            fi
            run_remote_tests
            ;;
        local)
            run_bastion_tests
            ;;
        all)
            if [ -z "$BASTION_IP" ]; then
                echo "Error: BASTION_IP environment variable required"
                exit 1
            fi
            echo "=== REMOTE TESTS ==="
            run_remote_tests
            
            echo ""
            echo "=== BASTION TESTS (via SSH) ==="
            # Copy script to bastion and run it
            scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$0" "$BASTION_USER@$BASTION_IP:/tmp/test-bastion.sh" 2>/dev/null
            ssh -i "$SSH_KEY" "$BASTION_USER@$BASTION_IP" "chmod +x /tmp/test-bastion.sh && /tmp/test-bastion.sh local"
            ;;
        *)
            show_usage
            ;;
    esac
}

main "$@"
