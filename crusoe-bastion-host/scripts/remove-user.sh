#!/bin/bash
set -e

# Remove a user from the bastion host
# Usage: ./remove-user.sh <username> [bastion-ip]

if [ $# -lt 1 ]; then
    echo "Usage: $0 <username> [bastion-ip]"
    echo ""
    echo "Examples:"
    echo "  $0 john 203.0.113.10"
    echo "  $0 jane"
    exit 1
fi

USERNAME=$1
BASTION_IP=${2:-""}

# Validate username
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Error: Invalid username format."
    exit 1
fi

# If bastion IP not provided, try to get it from Terraform output
if [ -z "$BASTION_IP" ]; then
    if [ -f "../terraform/terraform.tfstate" ]; then
        BASTION_IP=$(cd ../terraform && terraform output -json bastion_public_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo "")
    fi
    
    if [ -z "$BASTION_IP" ]; then
        echo "Error: Bastion IP not provided and could not be determined from Terraform state."
        echo "Please provide the bastion IP as the second argument."
        exit 1
    fi
fi

echo "Removing user '$USERNAME' from bastion host at $BASTION_IP..."
echo ""

# Confirm deletion
read -p "Are you sure you want to remove user '$USERNAME'? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Create remote script
REMOTE_SCRIPT=$(cat <<'SCRIPT'
#!/bin/bash
USERNAME="$1"

# Check if user exists
if ! id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME does not exist"
    exit 1
fi

# Remove user and home directory
userdel -r "$USERNAME" 2>/dev/null || true
echo "Removed user: $USERNAME"

# Update SSH config to remove this user
if [ -f /etc/ssh/sshd_config.d/99-bastion-hardening.conf ]; then
    sed -i "s/ $USERNAME//g" /etc/ssh/sshd_config.d/99-bastion-hardening.conf
    systemctl reload sshd
    echo "Updated SSH configuration and reloaded SSH service"
fi

echo "User $USERNAME removed successfully"
SCRIPT
)

# Execute on bastion host
ssh -o StrictHostKeyChecking=no "$BASTION_IP" "sudo bash -s -- '$USERNAME'" <<< "$REMOTE_SCRIPT"

echo ""
echo "✓ User '$USERNAME' removed successfully!"
