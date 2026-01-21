#!/bin/bash
set -e

# Bastion Host Hardening Script
# This script is executed on first boot via cloud-init

LOG_FILE="/var/log/bastion-setup.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=========================================="
echo "Bastion Host Setup Started: $(date)"
echo "=========================================="

# Variables from Terraform
ADMIN_USERNAME="${admin_username}"
SSH_PUBLIC_KEY="${ssh_public_key}"
ENABLE_SESSION_LOGGING="${enable_session_logging}"
AUTO_UPDATE_ENABLED="${auto_update_enabled}"
FAIL2BAN_ENABLED="${fail2ban_enabled}"
SSH_PORT="${ssh_port}"
SESSION_TIMEOUT="${session_timeout_seconds}"

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
    
    # Setup SSH key for admin user
    mkdir -p "/home/$ADMIN_USERNAME/.ssh"
    echo "$SSH_PUBLIC_KEY" > "/home/$ADMIN_USERNAME/.ssh/authorized_keys"
    chmod 700 "/home/$ADMIN_USERNAME/.ssh"
    chmod 600 "/home/$ADMIN_USERNAME/.ssh/authorized_keys"
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
MaxAuthTries 3
MaxSessions 10

# Session timeout
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# Allow only specific users
AllowUsers $ADMIN_USERNAME

# Protocol and ciphers
Protocol 2
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
    
    # Create log directory
    mkdir -p /var/log/bastion-sessions
    chmod 755 /var/log/bastion-sessions
    
    # Install script for session recording
    apt-get install -y script
    
    # Create session logging script
    cat > /usr/local/bin/log-session.sh <<'LOGSCRIPT'
#!/bin/bash
# Log SSH sessions
SESSION_LOG_DIR="/var/log/bastion-sessions"
SESSION_LOG="$SESSION_LOG_DIR/$(date +%Y%m%d-%H%M%S)-$USER-$$-$(who am i | awk '{print $NF}' | tr -d '()').log"

# Create log entry
echo "Session started: $(date)" > "$SESSION_LOG"
echo "User: $USER" >> "$SESSION_LOG"
echo "From: $(who am i | awk '{print $NF}' | tr -d '()')" >> "$SESSION_LOG"
echo "========================================" >> "$SESSION_LOG"

# Start script recording
/usr/bin/script -q -f -a "$SESSION_LOG"
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
maxretry = 3
destemail = root@localhost
sendername = Fail2Ban
action = %(action_mwl)s

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
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
ufw allow "$SSH_PORT/tcp"
ufw --force enable

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

# Restart SSH service
echo "Restarting SSH service..."
systemctl restart sshd

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

echo "=========================================="
echo "Bastion Host Setup Completed: $(date)"
echo "=========================================="
