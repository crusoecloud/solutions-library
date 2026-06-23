# Single Bastion Host Example

This example demonstrates deploying a single bastion host for basic use cases.

## Use Case

A single bastion host is suitable for:
- Development and testing environments
- Small teams (< 10 users)
- Non-critical workloads
- Cost-sensitive deployments

## Configuration

```hcl
# terraform.tfvars

project_id      = "your-project-id"
location        = "us-east1-a"
ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC..."

bastion_name    = "dev-bastion"
instance_type   = "c1a.2x"
admin_username  = "bastionadmin"

# Restrict to office IP range
allowed_ssh_cidrs = [
  "203.0.113.0/24"
]

# Enable all security features
enable_session_logging = true
auto_update_enabled    = true
fail2ban_enabled       = true

# Single bastion (default)
ha_enabled = false

tags = {
  Environment = "development"
  Purpose     = "bastion-host"
  Team        = "platform"
}
```

## Deployment

```bash
# Navigate to terraform directory
cd ../../terraform

# Copy example configuration
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
vim terraform.tfvars

# Deploy
terraform init
terraform apply
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                             │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           │ SSH (port 22)
                           │ Restricted to allowed_ssh_cidrs
                           │
                  ┌────────▼────────┐
                  │  Bastion Host   │
                  │  (Public IP)    │
                  │  c1a.2x         │
                  └────────┬────────┘
                           │
                           │ Private Network
                           │
        ┏━━━━━━━━━━━━━━━━━━┻━━━━━━━━━━━━━━━━━━┓
        ┃                                      ┃
   ┌────▼─────┐                          ┌────▼─────┐
   │ Private  │                          │ Private  │
   │ Instance │                          │ Instance │
   │    #1    │                          │    #2    │
   └──────────┘                          └──────────┘
```

## Cost Estimate

**Monthly Cost** (approximate):
- Bastion Host (c1a.2x): ~$30-50/month
- Storage (32 GiB): ~$3-5/month
- **Total**: ~$35-55/month

## Limitations

- **Single Point of Failure**: If the bastion goes down, access is lost
- **No Redundancy**: Maintenance requires downtime
- **Limited Capacity**: May struggle with many concurrent users

For production environments, consider the [High Availability example](../ha-bastion/).

## Maintenance

### Backup Configuration

```bash
# Backup Terraform state
terraform state pull > backup-$(date +%Y%m%d).tfstate

# Backup user data
ssh bastionadmin@<bastion-ip> 'sudo tar -czf /tmp/backup.tar.gz /home /etc/ssh'
scp bastionadmin@<bastion-ip>:/tmp/backup.tar.gz ./bastion-backup.tar.gz
```

### Updates

```bash
# Check for updates
ssh bastionadmin@<bastion-ip> 'sudo apt update && apt list --upgradable'

# Apply updates (automatic updates are enabled by default)
ssh bastionadmin@<bastion-ip> 'sudo apt upgrade -y'
```

## Scaling Up

To upgrade to high availability:

```hcl
# In terraform.tfvars, change:
ha_enabled = true
ha_count   = 2
```

Then run:
```bash
terraform apply
```
