#!/bin/bash
set -e

# Add a new user to the bastion host
# Usage: ./add-user.sh <username> <ssh-public-key-file> [bastion-ip]

if [ $# -lt 2 ]; then
    echo "Usage: $0 <username> <ssh-public-key-file> [bastion-ip]"
    echo ""
    echo "Examples:"
    echo "  $0 john ~/.ssh/john_id_rsa.pub 203.0.113.10"
    echo "  $0 jane ~/.ssh/jane_id_ed25519.pub"
    exit 1
fi

USERNAME=$1
SSH_KEY_FILE=$2
BASTION_IP=${3:-""}

# Validate username
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Error: Invalid username. Use lowercase letters, numbers, underscore, and hyphen only."
    exit 1
fi

# Check if SSH key file exists
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Error: SSH public key file not found: $SSH_KEY_FILE"
    exit 1
fi

SSH_KEY=$(cat "$SSH_KEY_FILE")

# Validate SSH key format
if ! [[ "$SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ]]; then
    echo "Error: Invalid SSH public key format in $SSH_KEY_FILE"
    exit 1
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

# If bastion IP not provided, try to get it from Terraform output
if [ -z "$BASTION_IP" ]; then
    if [ -d "$TERRAFORM_DIR" ]; then
        BASTION_IP=$(cd "$TERRAFORM_DIR" && terraform output -json bastion_public_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo "")
    fi
    
    if [ -z "$BASTION_IP" ]; then
        echo "Error: Bastion IP not provided and could not be determined from Terraform state."
        echo "Please provide the bastion IP as the third argument."
        exit 1
    fi
fi

echo "Adding user '$USERNAME' to bastion host at $BASTION_IP..."
echo ""

# Create remote script
REMOTE_SCRIPT=$(cat <<'SCRIPT'
#!/bin/bash
USERNAME="$1"
SSH_KEY="$2"

# Create user
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists"
else
    useradd -m -s /bin/bash "$USERNAME"
    echo "Created user: $USERNAME"
fi

# Setup SSH directory and key
mkdir -p "/home/$USERNAME/.ssh"
echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
chmod 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

# Update SSH config to allow this user
if [ -f /etc/ssh/sshd_config.d/99-bastion-hardening.conf ]; then
    if ! grep -q "^AllowUsers.*$USERNAME" /etc/ssh/sshd_config.d/99-bastion-hardening.conf; then
        sed -i "s/^AllowUsers.*/& $USERNAME/" /etc/ssh/sshd_config.d/99-bastion-hardening.conf
        systemctl reload sshd
        echo "Updated SSH configuration and reloaded SSH service"
    fi
fi

echo "User $USERNAME configured successfully"
SCRIPT
)

# Execute on bastion host (connect as bastionadmin - ubuntu is disabled for security)
ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes "bastionadmin@$BASTION_IP" "sudo bash -s -- '$USERNAME' '$SSH_KEY'" <<< "$REMOTE_SCRIPT"

echo ""
echo "✓ User '$USERNAME' added successfully!"
echo ""
echo "Connection command:"
echo "  ssh $USERNAME@$BASTION_IP"
