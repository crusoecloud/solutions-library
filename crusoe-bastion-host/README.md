# Crusoe Bastion Host

A production-ready, click-to-deploy bastion host solution for Crusoe Cloud. This solution provides a hardened jump server for secure access to private infrastructure with comprehensive security features and management tools.

## Table of Contents

- [Overview](#overview)
- [What is a Bastion Host?](#what-is-a-bastion-host)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Manual Deployment](#manual-deployment)
- [Configuration](#configuration)
- [Usage](#usage)
- [Management](#management)
- [High Availability](#high-availability)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Advanced Configuration](#advanced-configuration)

## Overview

This solution deploys a hardened bastion host on Crusoe Cloud using Terraform. The bastion host serves as a secure gateway for SSH access to private instances, implementing security best practices and providing comprehensive audit logging.

## What is a Bastion Host?

A bastion host (also known as a jump server or jump box) is a special-purpose server designed to be the primary access point from an external network to resources within a private network. It acts as a secure gateway that:

- **Provides a single point of entry** for administrative access
- **Reduces attack surface** by limiting direct access to private resources
- **Enables centralized access control** and monitoring
- **Facilitates audit logging** of all access attempts and sessions

### Key Benefits

- ✅ **Enhanced Security**: Hardened configuration with minimal attack surface
- ✅ **Access Control**: Centralized management of user access
- ✅ **Audit Trail**: Complete logging of all SSH sessions
- ✅ **Compliance**: Meets security and compliance requirements
- ✅ **Network Isolation**: Private instances don't need public IPs

## Features

### Security Features

- 🔐 **SSH Key-Based Authentication Only** - No password authentication
- 🛡️ **Hardened SSH Configuration** - Modern ciphers and security settings
- 🚫 **Root Login Disabled** - Prevents direct root access
- 🔒 **Fail2ban Integration** - Automatic IP blocking after failed attempts
- 📝 **Session Logging** - Records all SSH sessions for audit purposes
- 🔄 **Automatic Security Updates** - Keeps system patched and secure
- 🔥 **UFW Firewall** - Restricts network access to essential services
- ⏱️ **Session Timeouts** - Automatic disconnection of idle sessions

### Management Features

- 👥 **User Management Scripts** - Easy addition/removal of users
- 📊 **Health Check Script** - Monitor bastion host status
- 📋 **Audit Log Viewer** - Review access logs and session recordings
- 🔧 **Infrastructure as Code** - Reproducible deployments with Terraform
- 🎯 **High Availability Option** - Deploy multiple bastions for redundancy

### Deployment Features

- 🚀 **Interactive Deployment Script** - Guided setup process
- ⚙️ **Customizable Configuration** - Flexible options for different use cases
- 📦 **One-Command Deployment** - Quick and easy setup
- 🏷️ **Tagging Support** - Organize resources with custom tags

## Prerequisites

Before deploying the bastion host, ensure you have:

1. **Crusoe Cloud Account** with an active project
2. **Terraform** (>= 1.0) - [Install Terraform](https://www.terraform.io/downloads)
3. **Crusoe CLI** (optional but recommended) - [Install Crusoe CLI](https://docs.crusoecloud.com/quickstart/installing-the-cli/)
4. **SSH Key Pair** - For authentication to the bastion host
5. **jq** (optional) - For JSON parsing in scripts

### Install Prerequisites

```bash
# macOS
brew install terraform jq

# Ubuntu/Debian
sudo apt-get install terraform jq

# Verify installations
terraform version
jq --version
```

## Quick Start

The fastest way to deploy a bastion host is using the interactive deployment script:

```bash
# Clone the repository
git clone https://github.com/crusoecloud/solutions-library.git
cd solutions-library/crusoe-bastion-host

# Make the deployment script executable
chmod +x deploy.sh

# Run the interactive deployment
./deploy.sh
```

The script will guide you through:
1. ✓ Checking prerequisites
2. ✓ Collecting configuration (project ID, location, SSH key, etc.)
3. ✓ Configuring security features
4. ✓ Reviewing the configuration
5. ✓ Deploying with Terraform
6. ✓ Displaying connection instructions

**That's it!** Your bastion host will be ready in a few minutes.

## Manual Deployment

If you prefer manual deployment or need more control:

### 1. Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
project_id      = "your-crusoe-project-id"
location        = "us-east1-a"
ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC..."

# Optional customizations
bastion_name    = "bastion-host"
instance_type   = "c1a.2x"
admin_username  = "bastionadmin"

allowed_ssh_cidrs = [
  "203.0.113.0/24",  # Your office IP range
]

enable_session_logging = true
auto_update_enabled    = true
fail2ban_enabled       = true
```

### 2. Initialize and Deploy

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the bastion host
terraform apply
```

### 3. Get Connection Information

```bash
# View all outputs
terraform output

# Get just the public IP
terraform output bastion_public_ips

# Get SSH connection command
terraform output ssh_commands
```

## Configuration

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `project_id` | Crusoe Cloud project ID | `"abc123..."` |
| `location` | Crusoe Cloud location | `"us-east1-a"` |
| `ssh_public_key` | SSH public key for access | `"ssh-rsa AAAA..."` |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `bastion_name` | `"bastion-host"` | Name for the bastion instance |
| `instance_type` | `"c1a.2x"` | Instance type (2 vCPU, 4GB RAM) |
| `disk_size_gib` | `32` | Root disk size in GiB |
| `admin_username` | `"bastionadmin"` | Admin username |
| `allowed_ssh_cidrs` | `["0.0.0.0/0"]` | Allowed source IP ranges |
| `enable_session_logging` | `true` | Enable SSH session recording |
| `auto_update_enabled` | `true` | Enable automatic security updates |
| `fail2ban_enabled` | `true` | Enable fail2ban |
| `ssh_port` | `22` | SSH port (can be changed) |
| `session_timeout_seconds` | `900` | SSH session timeout (15 min) |
| `ha_enabled` | `false` | Enable high availability mode |
| `ha_count` | `2` | Number of bastions in HA mode |

## Usage

### Connecting to the Bastion Host

```bash
# Direct SSH connection
ssh bastionadmin@<bastion-public-ip>

# Using SSH config (recommended)
# Add to ~/.ssh/config:
Host crusoe-bastion
    HostName <bastion-public-ip>
    User bastionadmin
    IdentityFile ~/.ssh/your-private-key
    ServerAliveInterval 60

# Then connect with:
ssh crusoe-bastion
```

### Accessing Private Instances via Bastion

#### Method 1: SSH Jump Host (ProxyJump)

```bash
# One-liner
ssh -J bastionadmin@<bastion-ip> ubuntu@<private-instance-ip>

# With SSH config
Host private-instance
    HostName <private-instance-ip>
    User ubuntu
    ProxyJump crusoe-bastion
    IdentityFile ~/.ssh/your-private-key

# Then connect with:
ssh private-instance
```

#### Method 2: SSH Tunneling

```bash
# Create a tunnel
ssh -L 8080:<private-instance-ip>:80 bastionadmin@<bastion-ip>

# Access the private service
curl http://localhost:8080
```

#### Method 3: SCP Through Bastion

```bash
# Copy file to private instance
scp -o ProxyJump=bastionadmin@<bastion-ip> file.txt ubuntu@<private-ip>:~/

# Copy file from private instance
scp -o ProxyJump=bastionadmin@<bastion-ip> ubuntu@<private-ip>:~/file.txt .
```

## Management

### Adding Users

```bash
cd scripts

# Add a new user with their SSH public key
./add-user.sh john ~/.ssh/john_id_rsa.pub <bastion-ip>

# The script will:
# 1. Create the user account
# 2. Configure their SSH key
# 3. Update SSH configuration
# 4. Reload SSH service
```

### Removing Users

```bash
cd scripts

# Remove a user
./remove-user.sh john <bastion-ip>

# This will:
# 1. Delete the user account
# 2. Remove their home directory
# 3. Update SSH configuration
```

### Viewing Audit Logs

```bash
cd scripts

# View recent audit logs
./audit-logs.sh <bastion-ip>

# This displays:
# - SSH authentication logs
# - Active sessions
# - Recent login history
# - Session recordings
# - Fail2ban status
```

### Health Checks

```bash
cd scripts

# Run a comprehensive health check
./health-check.sh <bastion-ip>

# Checks:
# - SSH connectivity
# - System resources (CPU, memory, disk)
# - Service status (SSH, UFW, fail2ban)
# - Active sessions
# - Security configuration
# - Available updates
# - Failed login attempts
```

### Testing Security Features

The bastion host includes an automated test script to verify all security features are properly configured. This is useful after deployment or when troubleshooting.

> **Note**: Wait 2-3 minutes after deployment before running tests to ensure all services (fail2ban, UFW, etc.) are fully initialized.

```bash
cd scripts

# Run all tests (remote connectivity + on-bastion security checks)
BASTION_IP=<bastion-ip> ./test-bastion.sh all

# Run only remote tests (from your local machine)
BASTION_IP=<bastion-ip> ./test-bastion.sh remote

# Run only bastion tests (must be run on the bastion itself)
./test-bastion.sh bastion
```

The test script validates:
- **SSH Connectivity** - Verifies the bastion is reachable
- **Root Login Disabled** - Confirms root SSH access is blocked
- **SSH Hardening** - Checks secure SSH configuration
- **Fail2ban** - Verifies intrusion prevention is active
- **UFW Firewall** - Confirms firewall rules are in place
- **Session Logging** - Validates session recording is configured
- **Admin User** - Checks bastionadmin account exists with proper permissions
- **Ubuntu User Disabled** - Confirms default user is locked (security hardening)

## High Availability

For production environments, deploy multiple bastion hosts for redundancy:

```hcl
# In terraform.tfvars
ha_enabled = true
ha_count   = 2  # Deploy 2 bastion hosts
```

This creates multiple bastion hosts that can be used with:

- **DNS Round-Robin**: Point a DNS record to all bastion IPs
- **Load Balancer**: Use a TCP load balancer (Layer 4)
- **Client-Side Failover**: Configure multiple ProxyJump hosts in SSH config

### SSH Config for HA

```
# ~/.ssh/config
Host crusoe-bastion-1
    HostName <bastion-1-ip>
    User bastionadmin

Host crusoe-bastion-2
    HostName <bastion-2-ip>
    User bastionadmin

Host private-instance
    HostName <private-ip>
    User ubuntu
    ProxyJump crusoe-bastion-1,crusoe-bastion-2
```

## Security Considerations

### Best Practices

1. **Restrict Source IPs**: Limit `allowed_ssh_cidrs` to known IP ranges
2. **Regular Key Rotation**: Rotate SSH keys periodically
3. **Monitor Logs**: Review audit logs regularly
4. **Keep Updated**: Ensure automatic updates are enabled
5. **Minimal Privileges**: Grant users only necessary access
6. **Session Recording**: Keep session logs for compliance
7. **Network Segmentation**: Use private subnets for internal resources

### Security Checklist

- ✅ SSH key-based authentication only
- ✅ Root login disabled
- ✅ Password authentication disabled
- ✅ Fail2ban enabled and configured
- ✅ UFW firewall active
- ✅ Automatic security updates enabled
- ✅ Session logging enabled
- ✅ SSH hardening configuration applied
- ✅ Source IP restrictions configured
- ✅ Session timeouts configured

For detailed security information, see [SECURITY.md](./SECURITY.md).

## Troubleshooting

### Cannot Connect to Bastion

**Problem**: SSH connection times out or is refused

**Solutions**:
1. Verify the bastion is running: `crusoe compute vms list`
2. Check firewall rules allow your IP: Review `allowed_ssh_cidrs`
3. Verify SSH key is correct: `ssh-add -l`
4. Check bastion logs: `./scripts/audit-logs.sh <bastion-ip>`

### User Cannot Login

**Problem**: User gets "Permission denied" error

**Solutions**:
1. Verify user was added: `./scripts/audit-logs.sh <bastion-ip>`
2. Check SSH key format: Must be valid public key
3. Verify user in AllowUsers: SSH config must include username
4. Check fail2ban: User's IP may be banned

### Session Disconnects

**Problem**: SSH session disconnects after idle time

**Solutions**:
1. This is expected behavior (security feature)
2. Adjust `session_timeout_seconds` if needed
3. Use `ServerAliveInterval` in SSH config:
   ```
   Host crusoe-bastion
       ServerAliveInterval 60
       ServerAliveCountMax 3
   ```

### Cannot Access Private Instance

**Problem**: Cannot SSH to private instance through bastion

**Solutions**:
1. Verify bastion can reach private instance:
   ```bash
   ssh bastionadmin@<bastion-ip>
   ping <private-instance-ip>
   ```
2. Check private instance firewall allows bastion's private IP
3. Verify SSH key is available on bastion or use agent forwarding:
   ```bash
   ssh -A bastionadmin@<bastion-ip>
   ```

### Terraform Errors

**Problem**: Terraform apply fails

**Solutions**:
1. Verify Crusoe credentials: `crusoe config list`
2. Check project ID is correct
3. Verify location is valid: `crusoe locations list`
4. Review Terraform logs: `TF_LOG=DEBUG terraform apply`

## Advanced Configuration

### Custom SSH Port

```hcl
# terraform.tfvars
ssh_port = 2222  # Use non-standard port
```

Update firewall rules accordingly.

### Custom Hardening Script

Modify `terraform/user-data.sh` to add custom security configurations.

### Integration with Monitoring

Add monitoring agents in the user-data script:

```bash
# Install monitoring agent
apt-get install -y datadog-agent
# Configure agent...
```

### Backup Configuration

```bash
# Backup Terraform state
terraform state pull > backup-$(date +%Y%m%d).tfstate

# Backup SSH keys and configs
tar -czf bastion-backup-$(date +%Y%m%d).tar.gz \
    terraform/terraform.tfvars \
    ~/.ssh/config
```

## Cleanup

To remove the bastion host and all resources:

```bash
cd terraform
terraform destroy
```

**Warning**: This will permanently delete the bastion host and all associated resources.

## Support

- **Documentation**: [Crusoe Cloud Docs](https://docs.crusoecloud.com/)
- **Issues**: [GitHub Issues](https://github.com/crusoecloud/solutions-library/issues)
- **Security**: See [SECURITY.md](./SECURITY.md) for security policies

## License

This solution is provided as-is for use with Crusoe Cloud.

## Contributing

Contributions are welcome! Please submit pull requests or issues to the [solutions-library repository](https://github.com/crusoecloud/solutions-library).
