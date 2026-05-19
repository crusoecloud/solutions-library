# High Availability Bastion Host Example

This example demonstrates deploying multiple bastion hosts for high availability and redundancy.

## Use Case

High availability bastion hosts are suitable for:
- Production environments
- Large teams (> 10 users)
- Critical workloads requiring 99.9%+ uptime
- Compliance requirements for redundancy
- 24/7 operations

## Configuration

```hcl
# terraform.tfvars

project_id      = "your-project-id"
location        = "us-east1-a"
ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC..."

bastion_name    = "prod-bastion"
instance_type   = "c1a.4x"  # Larger instance for production
admin_username  = "bastionadmin"

# Restrict to corporate IP ranges
allowed_ssh_cidrs = [
  "203.0.113.0/24",  # Office network
  "198.51.100.0/24"  # VPN network
]

# Enable all security features
enable_session_logging = true
auto_update_enabled    = true
fail2ban_enabled       = true

# High Availability Configuration
ha_enabled = true
ha_count   = 2  # Deploy 2 bastions for redundancy

tags = {
  Environment = "production"
  Purpose     = "bastion-host"
  Team        = "platform"
  Criticality = "high"
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
└──────────────┬────────────────────────┬─────────────────────┘
               │                        │
               │ SSH (port 22)          │ SSH (port 22)
               │                        │
      ┌────────▼────────┐      ┌───────▼─────────┐
      │  Bastion #1     │      │  Bastion #2     │
      │  (Public IP 1)  │      │  (Public IP 2)  │
      │  c1a.4x         │      │  c1a.4x         │
      └────────┬────────┘      └───────┬─────────┘
               │                        │
               │    Private Network     │
               │                        │
        ┏━━━━━━┻━━━━━━━━━━━━━━━━━━━━━━┻━━━━━━┓
        ┃                                      ┃
   ┌────▼─────┐                          ┌────▼─────┐
   │ Private  │                          │ Private  │
   │ Instance │                          │ Instance │
   │    #1    │                          │    #2    │
   └──────────┘                          └──────────┘
```

## High Availability Setup

### Option 1: DNS Round-Robin

Create a DNS A record with multiple IPs:

```
bastion.example.com.  300  IN  A  203.0.113.10
bastion.example.com.  300  IN  A  203.0.113.11
```

Users connect to: `ssh user@bastion.example.com`

**Pros**: Simple, no additional infrastructure
**Cons**: No health checking, may connect to failed host

### Option 2: SSH Config with Multiple Hosts

```
# ~/.ssh/config

Host bastion-1
    HostName 203.0.113.10
    User bastionadmin
    IdentityFile ~/.ssh/id_ed25519

Host bastion-2
    HostName 203.0.113.11
    User bastionadmin
    IdentityFile ~/.ssh/id_ed25519

# Try bastion-1 first, fallback to bastion-2
Host bastion
    HostName 203.0.113.10
    User bastionadmin
    IdentityFile ~/.ssh/id_ed25519
    
Host private-instance
    HostName 10.0.1.100
    User ubuntu
    ProxyJump bastion-1,bastion-2
    IdentityFile ~/.ssh/id_ed25519
```

**Pros**: Client-side failover, explicit control
**Cons**: Manual configuration per user

### Option 3: Load Balancer (Advanced)

Deploy a TCP load balancer in front of bastions:

```
┌─────────────┐
│ TCP Load    │ :22
│ Balancer    │────┬────> Bastion #1
│             │    │
└─────────────┘    └────> Bastion #2
```

**Pros**: Automatic health checking, seamless failover
**Cons**: Additional cost and complexity

## Cost Estimate

**Monthly Cost** (approximate):
- 2x Bastion Hosts (c1a.4x): ~$120-160/month
- 2x Storage (32 GiB each): ~$6-10/month
- **Total**: ~$130-170/month

**Cost vs Single Bastion**: ~3-4x more expensive
**Benefit**: 99.9%+ uptime, zero-downtime maintenance

## Maintenance

### Rolling Updates

Update bastions one at a time to maintain availability:

```bash
# Get bastion IPs
terraform output bastion_public_ips

# Update bastion #1
ssh bastionadmin@<bastion-1-ip> 'sudo apt update && sudo apt upgrade -y'
ssh bastionadmin@<bastion-1-ip> 'sudo reboot'

# Wait for bastion #1 to come back online
./scripts/health-check.sh <bastion-1-ip>

# Update bastion #2
ssh bastionadmin@<bastion-2-ip> 'sudo apt update && sudo apt upgrade -y'
ssh bastionadmin@<bastion-2-ip> 'sudo reboot'

# Verify both are healthy
./scripts/health-check.sh <bastion-1-ip>
./scripts/health-check.sh <bastion-2-ip>
```

### User Management Across Multiple Bastions

Add users to all bastions:

```bash
# Get bastion IPs
BASTION_IPS=$(cd ../../terraform && terraform output -json bastion_public_ips | jq -r '.[]')

# Add user to all bastions
for ip in $BASTION_IPS; do
    echo "Adding user to $ip..."
    ./scripts/add-user.sh john ~/.ssh/john_key.pub $ip
done
```

### Monitoring

Monitor all bastions:

```bash
# Health check all bastions
for ip in $BASTION_IPS; do
    echo "Checking $ip..."
    ./scripts/health-check.sh $ip
done

# View logs from all bastions
for ip in $BASTION_IPS; do
    echo "=== Logs from $ip ==="
    ./scripts/audit-logs.sh $ip
done
```

## Disaster Recovery

### Backup Strategy

```bash
# Backup both bastions
for ip in $BASTION_IPS; do
    echo "Backing up $ip..."
    ssh bastionadmin@$ip 'sudo tar -czf /tmp/backup-$(hostname).tar.gz /home /etc/ssh /var/log/bastion-sessions'
    scp bastionadmin@$ip:/tmp/backup-*.tar.gz ./backups/
done
```

### Recovery Procedure

If a bastion fails:

1. **Immediate**: Users automatically failover to healthy bastion
2. **Investigation**: Determine cause of failure
3. **Recovery**: 
   ```bash
   # Destroy failed bastion
   terraform taint crusoe_compute_instance.bastion[0]
   
   # Recreate
   terraform apply
   ```
4. **Verification**: Run health checks
5. **Documentation**: Update incident log

## Scaling

### Increase Bastion Count

```hcl
# In terraform.tfvars
ha_count = 3  # Add a third bastion
```

```bash
terraform apply
```

### Increase Instance Size

```hcl
# In terraform.tfvars
instance_type = "c1a.8x"  # Upgrade to larger instance
```

```bash
terraform apply
```

## Best Practices

1. **Stagger Maintenance**: Never update all bastions simultaneously
2. **Monitor Health**: Set up automated health checks
3. **Sync Configuration**: Keep all bastions identically configured
4. **Test Failover**: Regularly test failover procedures
5. **Document Procedures**: Maintain runbooks for common scenarios
6. **Capacity Planning**: Monitor usage and scale proactively

## Compliance

High availability configuration helps meet:
- **SOC 2**: Availability commitments
- **ISO 27001**: Business continuity (A.17.1)
- **PCI DSS**: System availability requirements
- **HIPAA**: Contingency planning (§164.308(a)(7))

## Troubleshooting

### Bastion Not Responding

```bash
# Check if bastion is running
crusoe compute vms list | grep bastion

# Try alternative bastion
ssh bastionadmin@<bastion-2-ip>

# Check from working bastion
ssh bastionadmin@<bastion-2-ip>
ping <bastion-1-private-ip>
```

### Session Sync Issues

User sessions are NOT synced between bastions. Each bastion maintains its own session logs.

To view all sessions:
```bash
for ip in $BASTION_IPS; do
    ./scripts/audit-logs.sh $ip > logs-$ip.txt
done
```

## Migration from Single to HA

```bash
# 1. Update configuration
vim terraform.tfvars
# Set: ha_enabled = true, ha_count = 2

# 2. Apply changes (creates second bastion)
terraform apply

# 3. Update DNS/SSH configs to use both IPs

# 4. Test failover

# 5. Document new procedures
```

## Support

For HA-specific questions, see the main [README.md](../../README.md) or [SECURITY.md](../../SECURITY.md).
