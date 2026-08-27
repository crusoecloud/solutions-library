# Security Best Practices for Bastion Hosts

This document outlines security best practices, hardening guidelines, and compliance considerations for the Crusoe Bastion Host solution.

## Table of Contents

- [Security Architecture](#security-architecture)
- [Hardening Checklist](#hardening-checklist)
- [Access Control](#access-control)
- [Network Security](#network-security)
- [Audit and Compliance](#audit-and-compliance)
- [Incident Response](#incident-response)
- [Security Maintenance](#security-maintenance)
- [Compliance Frameworks](#compliance-frameworks)

## Security Architecture

### Defense in Depth

The bastion host implements multiple layers of security:

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Network Security                                   │
│ - Firewall rules (UFW)                                      │
│ - Source IP restrictions                                    │
│ - Fail2ban intrusion prevention                             │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: Authentication                                      │
│ - SSH key-based authentication only                         │
│ - No password authentication                                │
│ - Root login disabled                                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Authorization                                       │
│ - User-based access control                                 │
│ - AllowUsers SSH restriction                                │
│ - Sudo privileges management                                │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Monitoring & Auditing                              │
│ - Session logging and recording                             │
│ - Authentication logs                                       │
│ - Failed login attempt tracking                             │
└─────────────────────────────────────────────────────────────┘
```

### Security Principles

1. **Least Privilege**: Users have minimal necessary permissions
2. **Zero Trust**: Verify every access attempt
3. **Defense in Depth**: Multiple security layers
4. **Audit Everything**: Comprehensive logging
5. **Fail Secure**: Default deny policies

## Hardening Checklist

### SSH Hardening

- ✅ **Protocol 2 Only**: Modern SSH protocol
- ✅ **Key-Based Authentication**: No passwords allowed
- ✅ **Root Login Disabled**: `PermitRootLogin no`
- ✅ **Empty Passwords Disabled**: `PermitEmptyPasswords no`
- ✅ **X11 Forwarding Disabled**: Reduces attack surface
- ✅ **Max Auth Tries Limited**: `MaxAuthTries 3`
- ✅ **Strong Ciphers**: Modern encryption algorithms
- ✅ **Session Timeouts**: Automatic disconnection
- ✅ **Login Banner**: Legal warning message

### SSH Configuration Details

```
# /etc/ssh/sshd_config.d/99-bastion-hardening.conf

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no

# Security
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
MaxSessions 10

# Timeouts
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# Cryptography
Protocol 2
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,diffie-hellman-group-exchange-sha256
```

### System Hardening

- ✅ **Automatic Security Updates**: Unattended-upgrades configured
- ✅ **Minimal Package Installation**: Only essential packages
- ✅ **Kernel Hardening**: Sysctl security parameters
- ✅ **Firewall Enabled**: UFW with default deny
- ✅ **Fail2ban Active**: Automatic IP blocking
- ✅ **Audit Logging**: Session recording enabled

### Kernel Security Parameters

```bash
# /etc/sysctl.conf additions

# Disable IP forwarding (bastion is not a router)
net.ipv4.ip_forward = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable TCP SYN cookies
net.ipv4.tcp_syncookies = 1
```

## Access Control

### User Management Best Practices

#### 1. SSH Key Management

**Generate Strong Keys**:
```bash
# Recommended: Ed25519 (modern, secure, fast)
ssh-keygen -t ed25519 -C "user@example.com"

# Alternative: RSA 4096-bit
ssh-keygen -t rsa -b 4096 -C "user@example.com"
```

**Key Rotation Policy**:
- Rotate SSH keys every 90-180 days
- Immediately revoke keys for departed users
- Use different keys for different environments
- Never share private keys

**Key Storage**:
- Store private keys securely (encrypted disk, password manager)
- Use SSH agent for key management
- Consider hardware security keys (YubiKey, etc.)

#### 2. User Lifecycle

**Adding Users**:
```bash
# Use the provided script
./scripts/add-user.sh username ~/.ssh/username_key.pub <bastion-ip>

# Verify user was added
./scripts/audit-logs.sh <bastion-ip>
```

**Removing Users**:
```bash
# Remove immediately when access is no longer needed
./scripts/remove-user.sh username <bastion-ip>

# Verify removal
ssh username@<bastion-ip>  # Should fail
```

**Regular Access Reviews**:
- Review user list monthly
- Remove inactive users
- Verify users still require access
- Document access justifications

#### 3. Privilege Management

**Sudo Access**:
```bash
# Grant sudo only when necessary
echo "username ALL=(ALL) NOPASSWD:/specific/command" > /etc/sudoers.d/username

# Avoid blanket sudo access
# Review sudo logs regularly
```

**Principle of Least Privilege**:
- Users should only access what they need
- Time-bound access for temporary needs
- Separate accounts for different roles

### Multi-Factor Authentication (MFA)

For enhanced security, consider implementing MFA:

**Google Authenticator**:
```bash
# Install on bastion
apt-get install libpam-google-authenticator

# Configure PAM
# Edit /etc/pam.d/sshd
auth required pam_google_authenticator.so

# Update SSH config
# /etc/ssh/sshd_config
ChallengeResponseAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
```

**Hardware Keys (YubiKey)**:
```bash
# Install required packages
apt-get install libpam-u2f

# Configure for SSH
# Users enroll their hardware keys
pamu2fcfg > ~/.config/Yubico/u2f_keys
```

## Network Security

### Firewall Configuration

**UFW Rules**:
```bash
# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH from specific IPs only
ufw allow from 203.0.113.0/24 to any port 22

# Enable firewall
ufw enable

# Check status
ufw status verbose
```

**Advanced Firewall Rules**:
```bash
# Rate limiting SSH connections
ufw limit 22/tcp

# Allow from specific IP only
ufw allow from 203.0.113.10 to any port 22

# Deny from known bad actors
ufw deny from 198.51.100.0/24
```

### Fail2ban Configuration

**SSH Jail Settings**:
```ini
# /etc/fail2ban/jail.local

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200      # 2 hours
findtime = 600      # 10 minutes
action = iptables[name=SSH, port=22, protocol=tcp]
```

**Monitor Fail2ban**:
```bash
# Check status
fail2ban-client status sshd

# View banned IPs
fail2ban-client get sshd banned

# Unban an IP
fail2ban-client set sshd unbanip <ip-address>
```

### Network Segmentation

**Best Practices**:
1. **Public Subnet**: Bastion host only
2. **Private Subnets**: Internal resources
3. **Security Groups**: Restrict traffic between subnets
4. **No Direct Internet**: Private instances have no public IPs

**Firewall Rules for Private Instances**:
```bash
# On private instances, allow SSH only from bastion
ufw allow from <bastion-private-ip> to any port 22
ufw default deny incoming
```

## Audit and Compliance

### Session Logging

**What is Logged**:
- SSH connection attempts (successful and failed)
- User authentication events
- Commands executed (with session recording)
- Session start/end times
- Source IP addresses

**Log Locations**:
```
/var/log/auth.log              # Authentication logs
/var/log/bastion-sessions/     # Session recordings
/var/log/syslog                # System logs
```

**Viewing Logs**:
```bash
# Recent SSH attempts
grep "sshd" /var/log/auth.log | tail -50

# Failed login attempts
grep "Failed password" /var/log/auth.log

# Successful logins
grep "Accepted publickey" /var/log/auth.log

# Active sessions
who
last -n 20
```

### Session Recording

Session recordings capture all terminal activity:

```bash
# List session recordings
ls -lh /var/log/bastion-sessions/

# View a session recording
cat /var/log/bastion-sessions/20260121-143000-user-12345.log

# Download session recording
scp bastion:/var/log/bastion-sessions/session.log .
```

### Log Retention

**Recommended Retention Periods**:
- **Authentication logs**: 90 days minimum
- **Session recordings**: 1 year for compliance
- **System logs**: 30 days

**Implement Log Rotation**:
```bash
# /etc/logrotate.d/bastion-sessions
/var/log/bastion-sessions/*.log {
    daily
    rotate 365
    compress
    delaycompress
    missingok
    notifempty
}
```

### Centralized Logging

Forward logs to a centralized system:

**Rsyslog Configuration**:
```bash
# /etc/rsyslog.d/50-bastion.conf
*.* @@log-server.example.com:514
```

**Integration Options**:
- Splunk (see [crusoe-splunk-hec](../crusoe-splunk-hec/))
- ELK Stack (Elasticsearch, Logstash, Kibana)
- Cloud logging (GCP Cloud Logging, AWS CloudWatch)
- Syslog servers

## Incident Response

### Detecting Security Incidents

**Warning Signs**:
- Multiple failed login attempts
- Logins from unexpected locations
- Unusual command execution patterns
- Unexpected system changes
- High resource usage
- New user accounts

**Monitoring Commands**:
```bash
# Check for suspicious activity
./scripts/audit-logs.sh <bastion-ip>

# Monitor in real-time
ssh bastion 'sudo tail -f /var/log/auth.log'

# Check fail2ban bans
ssh bastion 'sudo fail2ban-client status sshd'
```

### Incident Response Procedures

**1. Detection**:
```bash
# Run health check
./scripts/health-check.sh <bastion-ip>

# Review recent logs
./scripts/audit-logs.sh <bastion-ip>
```

**2. Containment**:
```bash
# Block suspicious IP immediately
ssh bastion 'sudo ufw deny from <suspicious-ip>'

# Disable compromised user
ssh bastion 'sudo usermod -L username'

# Kill active sessions
ssh bastion 'sudo pkill -u username'
```

**3. Investigation**:
```bash
# Collect evidence
ssh bastion 'sudo tar -czf /tmp/evidence.tar.gz /var/log/auth.log /var/log/bastion-sessions/'
scp bastion:/tmp/evidence.tar.gz ./evidence-$(date +%Y%m%d).tar.gz

# Review session recordings
# Analyze authentication logs
# Check for unauthorized changes
```

**4. Recovery**:
```bash
# Remove compromised user
./scripts/remove-user.sh compromised-user <bastion-ip>

# Rotate SSH keys
# Update firewall rules
# Apply security patches

# Verify system integrity
./scripts/health-check.sh <bastion-ip>
```

**5. Post-Incident**:
- Document the incident
- Update security procedures
- Implement additional controls
- Conduct lessons learned review

### Emergency Procedures

**Lockdown Mode**:
```bash
# Block all SSH access except from specific IP
ssh bastion 'sudo ufw default deny incoming'
ssh bastion 'sudo ufw allow from <your-ip> to any port 22'
ssh bastion 'sudo ufw reload'
```

**Emergency User Removal**:
```bash
# Immediately disable user
ssh bastion 'sudo usermod -L username && sudo pkill -u username'
```

## Security Maintenance

### Regular Tasks

**Daily**:
- Monitor authentication logs
- Check fail2ban status
- Review active sessions

**Weekly**:
- Review user access list
- Check for available updates
- Verify backup integrity

**Monthly**:
- Conduct access reviews
- Review and rotate logs
- Test incident response procedures
- Update documentation

**Quarterly**:
- Rotate SSH keys
- Security audit
- Penetration testing
- Review and update security policies

### Update Management

**Automatic Updates**:
```bash
# Verify unattended-upgrades is active
systemctl status unattended-upgrades

# Check update configuration
cat /etc/apt/apt.conf.d/50unattended-upgrades
```

**Manual Updates**:
```bash
# Check for updates
ssh bastion 'sudo apt update && apt list --upgradable'

# Apply security updates
ssh bastion 'sudo apt upgrade -y'

# Reboot if kernel updated
ssh bastion 'sudo reboot'
```

### Security Scanning

**Vulnerability Scanning**:
```bash
# Install and run lynis
ssh bastion 'sudo apt install lynis'
ssh bastion 'sudo lynis audit system'

# Check for outdated packages
ssh bastion 'sudo apt list --upgradable'
```

**Configuration Auditing**:
```bash
# SSH configuration test
ssh bastion 'sudo sshd -t'

# Firewall status
ssh bastion 'sudo ufw status verbose'

# Check for weak permissions
ssh bastion 'sudo find /home -type f -perm -002'
```

## Compliance Frameworks

### SOC 2 Compliance

**Requirements Met**:
- ✅ Access controls (CC6.1)
- ✅ Logical and physical access restrictions (CC6.2)
- ✅ Audit logging (CC7.2)
- ✅ Security monitoring (CC7.3)

**Evidence Collection**:
- User access logs
- Session recordings
- Change management records
- Security configuration documentation

### PCI DSS Compliance

**Requirements Met**:
- ✅ Requirement 2: Secure configurations
- ✅ Requirement 8: User authentication
- ✅ Requirement 10: Audit trails
- ✅ Requirement 11: Security testing

**Specific Controls**:
- Strong cryptography (Req 4)
- Multi-factor authentication (Req 8.3)
- Log retention (Req 10.7)

### HIPAA Compliance

**Technical Safeguards**:
- ✅ Access control (§164.312(a)(1))
- ✅ Audit controls (§164.312(b))
- ✅ Integrity controls (§164.312(c)(1))
- ✅ Transmission security (§164.312(e)(1))

**Documentation**:
- Access authorization records
- Audit log reviews
- Security incident procedures
- Risk assessments

### ISO 27001 Compliance

**Controls Implemented**:
- A.9.2: User access management
- A.9.4: System and application access control
- A.12.4: Logging and monitoring
- A.18.1: Compliance with legal requirements

## Security Resources

### Tools

- **SSH Audit**: https://github.com/jtesta/ssh-audit
- **Lynis**: https://cisofy.com/lynis/
- **OSSEC**: https://www.ossec.net/
- **Wazuh**: https://wazuh.com/

### References

- **CIS Benchmarks**: https://www.cisecurity.org/cis-benchmarks/
- **NIST Guidelines**: https://csrc.nist.gov/publications
- **OWASP**: https://owasp.org/
- **SSH Hardening**: https://www.ssh.com/academy/ssh/security

### Security Contacts

For security issues or questions:
- Review the [README.md](./README.md)
- Check [Crusoe Cloud Documentation](https://docs.crusoecloud.com/)
- Report security vulnerabilities responsibly

---

**Remember**: Security is an ongoing process, not a one-time setup. Regular monitoring, updates, and reviews are essential for maintaining a secure bastion host.
