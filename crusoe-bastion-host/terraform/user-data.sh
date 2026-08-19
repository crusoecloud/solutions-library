#!/bin/bash
# Don't use set -e - we want the script to continue even if some steps fail
# Each critical step will handle errors individually

# Bastion Host Hardening Script
# This script is executed on first boot via cloud-init

LOG_FILE="/var/log/bastion-setup.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=========================================="
echo "Bastion Host Setup Started: $(date)"
echo "=========================================="

# Configuration - can be customized
ADMIN_USERNAME="bastionadmin"
ENABLE_SESSION_LOGGING="true"
AUTO_UPDATE_ENABLED="true"
FAIL2BAN_ENABLED="true"
SSH_PORT="22"
SESSION_TIMEOUT="900"

# Update system packages
echo "[1/10] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# Install essential packages
echo "[2/10] Installing essential packages..."
apt-get install -y \
    curl \
    wget \
    vim \
    htop \
    net-tools \
    ufw \
    unattended-upgrades \
    apt-listchanges \
    software-properties-common

# Create admin user
echo "[3/10] Creating admin user: $ADMIN_USERNAME..."
if ! id "$ADMIN_USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$ADMIN_USERNAME"
    echo "$ADMIN_USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$ADMIN_USERNAME"
    chmod 0440 "/etc/sudoers.d/$ADMIN_USERNAME"
    
    # Setup SSH key for admin user (copy from ubuntu user if exists)
    mkdir -p "/home/$ADMIN_USERNAME/.ssh"
    if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
        cp /home/ubuntu/.ssh/authorized_keys "/home/$ADMIN_USERNAME/.ssh/authorized_keys"
    fi
    chmod 700 "/home/$ADMIN_USERNAME/.ssh"
    chmod 600 "/home/$ADMIN_USERNAME/.ssh/authorized_keys" 2>/dev/null || true
    chown -R "$ADMIN_USERNAME:$ADMIN_USERNAME" "/home/$ADMIN_USERNAME/.ssh"
fi

# Configure SSH hardening
echo "[4/10] Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "$SSH_CONFIG.backup"

# SSH hardening settings
cat > /etc/ssh/sshd_config.d/99-bastion-hardening.conf <<EOF
# Bastion Host SSH Hardening Configuration

# Disable root login
PermitRootLogin no

# Key-based authentication only
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Security settings
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 6
MaxSessions 10

# Session timeout
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# Allow only the custom admin user (ubuntu is disabled for security)
AllowUsers $ADMIN_USERNAME

# Modern ciphers (Protocol 2 is default in modern OpenSSH)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256

# Banner
Banner /etc/ssh/banner
EOF

# Create SSH banner
cat > /etc/ssh/banner <<'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                         AUTHORIZED ACCESS ONLY                             ║
╚════════════════════════════════════════════════════════════════════════════╝

This system is a bastion host for accessing private infrastructure.
All connections are monitored and logged.
Unauthorized access is prohibited and will be prosecuted.

EOF

# Configure session logging if enabled
if [ "$ENABLE_SESSION_LOGGING" = "true" ]; then
    echo "[5/10] Configuring session logging..."
    
    # Create log directory - writable by all users (sticky bit like /tmp)
    mkdir -p /var/log/bastion-sessions
    chmod 1777 /var/log/bastion-sessions
    
    # The 'script' command is part of bsdutils which is pre-installed on Ubuntu
    # No additional package installation needed
    
    # Create session logging script
    cat > /usr/local/bin/log-session.sh <<'LOGSCRIPT'
#!/bin/bash
# Log SSH sessions - errors are silently ignored to avoid messy output
SESSION_LOG_DIR="/var/log/bastion-sessions"
SESSION_LOG="$SESSION_LOG_DIR/$(date +%Y%m%d-%H%M%S)-$USER-$$-$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()').log"

# Only log if we can write to the directory
if [ -w "$SESSION_LOG_DIR" ]; then
    # Create log entry
    {
        echo "Session started: $(date)"
        echo "User: $USER"
        echo "From: $(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()')"
        echo "========================================"
    } > "$SESSION_LOG" 2>/dev/null
    
    # Start script recording
    exec /usr/bin/script -q -f -a "$SESSION_LOG"
fi
LOGSCRIPT
    
    chmod +x /usr/local/bin/log-session.sh
    
    # Add to bash profile for all users
    echo 'if [ -n "$SSH_CONNECTION" ] && [ -x /usr/local/bin/log-session.sh ]; then /usr/local/bin/log-session.sh; fi' >> /etc/profile.d/session-logging.sh
    chmod +x /etc/profile.d/session-logging.sh
else
    echo "[5/10] Session logging disabled, skipping..."
fi

# Configure automatic security updates
if [ "$AUTO_UPDATE_ENABLED" = "true" ]; then
    echo "[6/10] Configuring automatic security updates..."
    
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
else
    echo "[6/10] Automatic updates disabled, skipping..."
fi

# Install and configure fail2ban
if [ "$FAIL2BAN_ENABLED" = "true" ]; then
    echo "[7/10] Installing and configuring fail2ban..."
    apt-get install -y fail2ban
    
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_mwl)s

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF
    
    systemctl enable fail2ban
    systemctl start fail2ban
else
    echo "[7/10] Fail2ban disabled, skipping..."
fi

# Configure firewall (UFW)
echo "[8/10] Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
# Enable UFW only after SSH is allowed
ufw --force enable || echo "Warning: UFW enable failed"

# Configure system limits and kernel parameters
echo "[9/10] Configuring system security parameters..."
cat >> /etc/sysctl.conf <<EOF

# Bastion Host Security Settings
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
EOF

sysctl -p

# Create management scripts directory
echo "[10/10] Creating management scripts..."
mkdir -p /opt/bastion-scripts
cat > /opt/bastion-scripts/add-user.sh <<'ADDUSER'
#!/bin/bash
# Add a new user to the bastion host
if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <ssh-public-key>"
    exit 1
fi

USERNAME=$1
SSH_KEY=$2

useradd -m -s /bin/bash "$USERNAME"
mkdir -p "/home/$USERNAME/.ssh"
echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
chmod 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

# Update SSH config to allow this user
if ! grep -q "^AllowUsers.*$USERNAME" /etc/ssh/sshd_config.d/99-bastion-hardening.conf; then
    sed -i "s/^AllowUsers.*/& $USERNAME/" /etc/ssh/sshd_config.d/99-bastion-hardening.conf
    systemctl reload sshd
fi

echo "User $USERNAME added successfully"
ADDUSER

cat > /opt/bastion-scripts/remove-user.sh <<'REMOVEUSER'
#!/bin/bash
# Remove a user from the bastion host
if [ $# -ne 1 ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

USERNAME=$1

userdel -r "$USERNAME" 2>/dev/null || true

# Update SSH config to remove this user
sed -i "s/ $USERNAME//" /etc/ssh/sshd_config.d/99-bastion-hardening.conf
systemctl reload sshd

echo "User $USERNAME removed successfully"
REMOVEUSER

chmod +x /opt/bastion-scripts/*.sh

# Test SSH config before restarting
echo "Testing SSH configuration..."
if sshd -t 2>/dev/null; then
    echo "SSH config valid, restarting service..."
    systemctl restart sshd
else
    echo "WARNING: SSH config test failed, not restarting sshd"
    echo "Removing custom config to preserve access..."
    rm -f /etc/ssh/sshd_config.d/99-bastion-hardening.conf
fi

# Create MOTD
cat > /etc/motd <<'MOTD'
╔════════════════════════════════════════════════════════════════════════════╗
║                         CRUSOE BASTION HOST                                ║
╚════════════════════════════════════════════════════════════════════════════╝

This is a hardened bastion host for secure access to private infrastructure.

Management Scripts:
  - Add user:    sudo /opt/bastion-scripts/add-user.sh <username> <ssh-key>
  - Remove user: sudo /opt/bastion-scripts/remove-user.sh <username>

Session Logs: /var/log/bastion-sessions/
System Logs:  /var/log/bastion-setup.log

For support, see: https://github.com/crusoecloud/solutions-library

MOTD

# Disable the default ubuntu user for security
# Attackers commonly try default usernames like 'ubuntu'
echo "Disabling default ubuntu user for security..."
if id ubuntu &>/dev/null; then
    # Lock the ubuntu account (prevents login but keeps the account for reference)
    passwd -l ubuntu
    # Remove ubuntu from AllowUsers is already done above
    echo "Default 'ubuntu' user has been locked"
    echo "Use '$ADMIN_USERNAME' for all administrative access"
fi

echo "=========================================="
echo "Bastion Host Setup Completed: $(date)"
echo "=========================================="
echo ""
echo "IMPORTANT: Connect using: ssh $ADMIN_USERNAME@<bastion-ip>"
echo "The default 'ubuntu' user has been disabled for security."
