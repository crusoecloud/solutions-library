# Node Remediation Helm Chart

Automatically cordons, drains, and takes configurable remediation actions
(vm-reset, vm-stop, vm-start, vm-delete) on nodes approaching critical
uptime thresholds.

## Quick Start

### CMK Clusters (default)

Uses the built-in `crusoe-secrets` from `crusoe-system` namespace — no manual secret creation needed.

```bash
# Install with dry-run mode (observation only)
helm install crusoe-node-remediation ./crusoe-node-remediation \
  --namespace crusoe-node-remediation \
  --create-namespace \
  --set nodeSelector.matchLabels.crusoe.ai/project.id=<your-project-id> \
  --set dryRun=true
```

### Custom/Non-CMK Clusters

Requires creating a custom secret with your Crusoe API credentials.

```bash
# 1. Create the secret
kubectl create secret generic crusoe-api-credentials \
  --namespace crusoe-node-remediation \
  --from-literal=access-key=<your-access-key> \
  --from-literal=secret-key=<your-secret-key> \
  --from-literal=api-url=https://api.cloud.crusoe.ai/v1alpha5

# 2. Install with custom secret mode
helm install crusoe-node-remediation ./crusoe-node-remediation \
  --namespace crusoe-node-remediation \
  --create-namespace \
  --set useBuiltinSecret=false \
  --set crusoeProjectId=<your-project-id> \
  --set nodeSelector.matchLabels.crusoe.ai/project.id=<your-project-id> \
  --set dryRun=true
```

## Configuration

See `values.yaml` for all options. Key credential settings:

- **`useBuiltinSecret`** (default: `true`) — use `crusoe-secrets` from CMK cluster
- **`crusoeProjectId`** (optional for built-in, required for custom) — Crusoe project UUID
- **`crusoeApiSecret`** (default: `crusoe-api-credentials`) — K8s secret name for custom mode

## Action Types

| Type | Description |
|------|-------------|
| `vm-reset` | Crusoe API VM RESET + poll node Ready (default) |
| `vm-stop` | Crusoe API VM STOP + poll VM stopped |
| `vm-start` | Crusoe API VM START + poll node Ready |
| `vm-delete` | Crusoe API VM DELETE + wait for new node |
| `noop` | No action (for dry-run / testing) |

## Multi-Step Sequences

```yaml
action:
  maxRetries: 3
  steps:
    - type: vm-stop
      timeout: 5m
    - type: vm-delete
      timeout: 30m
      wait: 2m
```

## Configuration

See values.yaml for all configurable options.
