#!/bin/bash

# Health check for bastion host
# Usage: ./health-check.sh [bastion-ip]

BASTION_IP=${1:-""}

# If bastion IP not provided, try to get it from Terraform output
if [ -z "$BASTION_IP" ]; then
    if [ -f "../terraform/terraform.tfstate" ]; then
        BASTION_IP=$(cd ../terraform && terraform output -json bastion_public_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo "")
    fi
    
    if [ -z "$BASTION_IP" ]; then
        echo "Error: Bastion IP not provided and could not be determined from Terraform state."
        echo "Usage: $0 [bastion-ip]"
        exit 1
    fi
fi

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                      BASTION HOST HEALTH CHECK                            ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Bastion Host: $BASTION_IP"
echo ""

# Check SSH connectivity
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. SSH Connectivity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$BASTION_IP" "echo 'SSH connection successful'" 2>/dev/null; then
    echo "✓ SSH is accessible"
else
    echo "✗ SSH connection failed"
    exit 1
fi

# Create remote health check script
REMOTE_SCRIPT=$(cat <<'SCRIPT'
#!/bin/bash

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. System Resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# CPU and Memory
echo "CPU Usage:"
top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print "  " 100 - $1 "% used"}'

echo "Memory Usage:"
free -h | awk 'NR==2{printf "  %s / %s (%.2f%% used)\n", $3, $2, $3*100/$2 }'

echo "Disk Usage:"
df -h / | awk 'NR==2{printf "  %s / %s (%s used)\n", $3, $2, $5}'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. Service Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# SSH Service
if systemctl is-active --quiet sshd; then
    echo "✓ SSH service is running"
else
    echo "✗ SSH service is not running"
fi

# UFW Firewall
if systemctl is-active --quiet ufw; then
    echo "✓ UFW firewall is active"
    ufw status | grep -q "Status: active" && echo "  Status: Active" || echo "  Status: Inactive"
else
    echo "✗ UFW firewall is not running"
fi

# Fail2ban
if command -v fail2ban-client &> /dev/null; then
    if systemctl is-active --quiet fail2ban; then
        echo "✓ Fail2ban is running"
        BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}')
        echo "  Currently banned IPs: ${BANNED:-0}"
    else
        echo "✗ Fail2ban is installed but not running"
    fi
else
    echo "⚠ Fail2ban is not installed"
fi

# Unattended upgrades
if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    echo "✓ Automatic security updates enabled"
else
    echo "⚠ Automatic security updates not configured"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. Active Sessions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SESSIONS=$(who | wc -l)
echo "Active SSH sessions: $SESSIONS"
if [ "$SESSIONS" -gt 0 ]; then
    who
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. Security Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check SSH hardening
if grep -q "PermitRootLogin no" /etc/ssh/sshd_config* 2>/dev/null; then
    echo "✓ Root login disabled"
else
    echo "✗ Root login not disabled"
fi

if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config* 2>/dev/null; then
    echo "✓ Password authentication disabled"
else
    echo "✗ Password authentication not disabled"
fi

if [ -f /etc/ssh/sshd_config.d/99-bastion-hardening.conf ]; then
    echo "✓ SSH hardening configuration present"
else
    echo "⚠ SSH hardening configuration not found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. System Updates"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
if [ "$UPDATES" -eq 0 ]; then
    echo "✓ System is up to date"
else
    echo "⚠ $UPDATES package(s) can be updated"
fi

SECURITY_UPDATES=$(apt list --upgradable 2>/dev/null | grep -c security)
if [ "$SECURITY_UPDATES" -gt 0 ]; then
    echo "⚠ $SECURITY_UPDATES security update(s) available"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7. Recent Failed Login Attempts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
FAILED=$(grep "Failed password" /var/log/auth.log 2>/dev/null | tail -5 | wc -l)
if [ "$FAILED" -gt 0 ]; then
    echo "Recent failed login attempts: $FAILED (last 5 shown)"
    grep "Failed password" /var/log/auth.log 2>/dev/null | tail -5 | awk '{print "  " $0}'
else
    echo "✓ No recent failed login attempts"
fi

SCRIPT
)

# Execute on bastion host
ssh -o StrictHostKeyChecking=no "$BASTION_IP" "sudo bash -s" <<< "$REMOTE_SCRIPT"

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                      HEALTH CHECK COMPLETE                                 ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
