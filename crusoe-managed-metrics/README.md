# Crusoe Telemetry Agent Ansible Deployment Guide

## Prerequisites

1. **Ansible Installation** (on control machine):
   ```bash
   pip install ansible
   ```

2. **Ansible Docker Collection**:
   ```bash
   ansible-galaxy collection install community.docker
   ```


4. **Crusoe Monitoring Token**: Generate a monitoring token from Crusoe Cloud CLI

   ```
   crusoe monitoring tokens create 
   ```

## File Structure

```
crusoe-telemetry-deployment/
├── setup-metrics.yaml
├── inventory.ini
└── README.md
```

## Usage

### Method 1: Pass Token as Command-Line Variable (Recommended)

```bash
ansible-playbook -i inventory.ini playbook.yml \
  -e 'crusoe_monitoring_token=YOUR_MONITORING_TOKEN_HERE'
```

### Method 2: Use Environment Variable

```bash
export CRUSOE_MONITORING_TOKEN='YOUR_MONITORING_TOKEN_HERE'
ansible-playbook -i inventory.ini playbook.yml
```

### Method 3: Use Ansible Vault (Most Secure)

1. Create an encrypted variables file:
   ```bash
   ansible-vault create vars/secrets.yml
   ```

2. Add your token to the file:
   ```yaml
   crusoe_monitoring_token: "YOUR_MONITORING_TOKEN_HERE"
   ```

3. Run the playbook with vault:
   ```bash
   ansible-playbook -i inventory.ini playbook.yml \
     -e @vars/secrets.yml --ask-vault-pass
   ```

## Deployment Examples

### Deploy to All VMs
```bash
ansible-playbook -i inventory.ini setup-metrics.yaml \
  -e 'crusoe_monitoring_token=YOUR_TOKEN'
```



### Deploy to Single VM
```bash
ansible-playbook -i inventory.ini setup-metrics.yaml \
  -e 'crusoe_monitoring_token=YOUR_TOKEN' \
  --limit vm-1
```

### Dry Run (Check Mode)
```bash
ansible-playbook -i inventory.ini setup-metrics.yaml \
  -e 'crusoe_monitoring_token=YOUR_TOKEN' \
  --check
```

### Verbose Output
```bash
ansible-playbook -i inventory.ini setup-metrics.yaml \
  -e 'crusoe_monitoring_token=YOUR_TOKEN' \
  -vvv
```

## Verification

After deployment, verify the installation on target VMs:

```bash
# Check service status
ansible crusoe_vms -i inventory.ini -m shell \
  -a "sudo systemctl status crusoe-telemetry-agent" -b

# Check Docker containers
ansible crusoe_vms -i inventory.ini -m shell \
  -a "docker ps | grep crusoe" -b

# View vector logs
ansible crusoe_vms -i inventory.ini -m shell \
  -a "docker logs crusoe-vector --tail 20" -b
```

## Troubleshooting

### Issue: "Crusoe monitoring token is required"
**Solution**: Ensure token is passed via `-e` flag or environment variable

### Issue: SSH connection failures
**Solution**: Verify SSH access and update `ansible_user` in inventory file
```bash
ansible crusoe_vms -i inventory.ini -m ping
```

### Issue: Docker containers not starting
**Solution**: Check Docker service and logs on target VM
```bash
ansible crusoe_vms -i inventory.ini -m shell \
  -a "sudo systemctl status docker" -b
```

### Issue: expect package not found
**Solution**: The playbook automatically installs expect, but you can pre-install:
```bash
ansible crusoe_vms -i inventory.ini -m apt \
  -a "name=expect state=present" -b
```

## Advanced Configuration

### Custom Variables

Create a `group_vars/crusoe_vms.yml` file:

```yaml
---
crusoe_monitoring_token: "{{ lookup('env', 'CRUSOE_MONITORING_TOKEN') }}"
telemetry_agent_script_url: "https://raw.githubusercontent.com/crusoecloud/crusoe-telemetry-agent/refs/heads/main/setup_crusoe_telemetry_agent.sh"
```

### Parallel Execution

Run on multiple hosts in parallel (default is 5):
```bash
ansible-playbook -i inventory.ini setup-metrics.yaml \
  -e 'crusoe_monitoring_token=YOUR_TOKEN' \
  --forks 10
```

### Using Dynamic Inventory

For large-scale deployments, consider using dynamic inventory with Crusoe Cloud API.

## Maintenance Operations

### Restart Telemetry Agent on All VMs
```bash
ansible crusoe_vms -i inventory.ini -m systemd \
  -a "name=crusoe-telemetry-agent state=restarted" -b
```

### Stop Telemetry Agent
```bash
ansible crusoe_vms -i inventory.ini -m systemd \
  -a "name=crusoe-telemetry-agent state=stopped" -b
```

### Check Agent Status
```bash
ansible crusoe_vms -i inventory.ini -m systemd \
  -a "name=crusoe-telemetry-agent state=started enabled=yes" -b
```

## Security Best Practices

1. **Never commit tokens to version control**
2. **Use Ansible Vault for sensitive data**
3. **Rotate monitoring tokens regularly**
4. **Use SSH key authentication instead of passwords**
5. **Limit playbook execution to authorized users**

## CI/CD Integration

Example GitLab CI pipeline:

```yaml
deploy_telemetry:
  stage: deploy
  script:
    - ansible-playbook -i inventory.ini setup-metrics.yaml 
      -e "crusoe_monitoring_token=$CRUSOE_TOKEN"
  only:
    - main
```

## Support

For issues with the telemetry agent, contact Crusoe Cloud support.
For Ansible playbook issues, check the task output with `-vvv` flag for detailed debugging information.
