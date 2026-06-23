#!/bin/bash

# View audit logs from the bastion host
# Usage: ./audit-logs.sh [bastion-ip] [options]

BASTION_IP=${1:-""}
LINES=${2:-50}

# If bastion IP not provided, try to get it from Terraform output
if [ -z "$BASTION_IP" ]; then
    if [ -f "../terraform/terraform.tfstate" ]; then
        BASTION_IP=$(cd ../terraform && terraform output -json bastion_public_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo "")
    fi
    
    if [ -z "$BASTION_IP" ]; then
        echo "Error: Bastion IP not provided and could not be determined from Terraform state."
        echo "Usage: $0 [bastion-ip] [number-of-lines]"
        exit 1
    fi
fi

echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                         BASTION AUDIT LOGS                                 ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Bastion Host: $BASTION_IP"
echo ""

# Create remote script to gather logs
REMOTE_SCRIPT=$(cat <<'SCRIPT'
#!/bin/bash
LINES=$1

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SSH Authentication Logs (Last $LINES entries)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
grep -i "sshd" /var/log/auth.log | tail -n "$LINES"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Active SSH Sessions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
who

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Recent Login History"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
last -n 20

if [ -d /var/log/bastion-sessions ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Session Recordings"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ls -lh /var/log/bastion-sessions/ | tail -n 20
fi

if command -v fail2ban-client &> /dev/null; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Fail2Ban Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fail2ban-client status sshd 2>/dev/null || echo "Fail2ban not configured for SSH"
fi
SCRIPT
)

# Execute on bastion host
ssh -o StrictHostKeyChecking=no "$BASTION_IP" "sudo bash -s -- '$LINES'" <<< "$REMOTE_SCRIPT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To download a specific session recording:"
echo "  scp $BASTION_IP:/var/log/bastion-sessions/<session-file> ."
echo ""
echo "To view live auth logs:"
echo "  ssh $BASTION_IP 'sudo tail -f /var/log/auth.log'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
