# CMK logs to Google Cloud Logging with Fluent Bit

This is a solution that configures your Crusoe Managed Kubernetes (CMK) cluster to filter container logs and then ship them to Google Cloud Logging using Fluent Bit.

## Prerequisites

1. **GCP Service Account** configured with gcloud CLI.

2. **Crusoe Managed Kubernetes** cluster with:
   - Helm 3 installed
   - Access to create namespaces and secrets

## Installation

### 1. Create Google Cloud Service Account

```bash
# Set your GCP project ID
export PROJECT_ID="your-gcp-project-id"
export SERVICE_ACCOUNT_NAME="fluent-bit-logger"

# Create service account
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --display-name="Fluent Bit Log Shipper" \
    --project=$PROJECT_ID

# Grant necessary permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/logging.logWriter"

# Create and download the key
gcloud iam service-accounts keys create ./gcp-credentials.json \
    --iam-account="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
```

The GCP credential file is in a JSON format, similar to the file you see under `examples/gcp-credentials-example.json`. Make sure you move the downloaded key to this main directory.

### 2. Create Kubernetes resources

We will operate our resources out of a new namespace:

```bash
kubectl create namespace logging
```

To ship our logs, we need to integrate the GCP credentials we created. We will generate a Kubernetes Secret:

```bash
# Base64 encode the service account key and create secret
kubectl create secret generic gcp-credentials \
    --from-file=gcp-credentials.json=./gcp-credentials.json \
    -n logging

# Or apply the YAML (after replacing the placeholder)
# cat gcp-credentials.json | base64 | pbcopy  # macOS
# cat gcp-credentials.json | base64 -w 0      # Linux
# Then paste into gcp-credentials-secret.yaml and apply:
# kubectl apply -f gcp-credentials-secret.yaml
```

### 3. Configure Fluent Bit Values

Edit `fluent-bit-values.yaml` and replace the following placeholders:
- `YOUR_GCP_PROJECT_ID`: Your GCP project ID
- `YOUR_CLUSTER_NAME`: Name of your CMK cluster
- `YOUR_CLUSTER_REGION`: Region of your CMK cluster

```bash
# Example using sed
sed -i 's/YOUR_GCP_PROJECT_ID/my-project-123/g' fluent-bit-values.yaml
sed -i 's/YOUR_CLUSTER_NAME/prod-cluster/g' fluent-bit-values.yaml
sed -i 's/YOUR_CLUSTER_REGION/us-east-1/g' fluent-bit-values.yaml
```

The file `examples/fluent-bit-values-example.yaml` shows an example file with all the values populated.

### 5. Install Fluent Bit

```bash
# Add Fluent Bit Helm repository
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# Install Fluent Bit with custom values
helm install fluent-bit fluent/fluent-bit \
    -f fluent-bit-values.yaml \
    -n logging

# Verify installation
kubectl get pods -n logging
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit
```

You will soon start seeing your container logs in the Google Cloud Logging console.

## Configuration Details

> Consult the official Fluent Bit [documentation](https://docs.fluentbit.io/manual) for a full list of options.

### Key Features

- **Namespace Filtering**: Only collects logs from the `default` namespace
- **DaemonSet**: Runs on every node to collect all pod logs
- **Stackdriver plugin**: Ships logs directly to Google Cloud Logging
- **Kubernetes Metadata**: Enriches logs with pod, namespace, and container information

### Log Filtering

The configuration uses a grep filter to only include the `default` namespace:

```ini
[FILTER]
    Name grep
    Match kube.*
    Regex $kubernetes['namespace_name'] ^default$
```

To include additional namespaces, modify the regex pattern (e.g., `^(default|production|staging)$`).

### Adjust Resource Limits

Modify the `resources` section in `fluent-bit-values.yaml` based on your cluster size and log volume.

### Custom Metadata

Logs are enriched with:
- `cluster_name`: Your Kubernetes cluster name
- `project_id`: Your GCP project ID
- All Kubernetes labels from pods
- Namespace, pod name, container name

## Verification

### Check Fluent Bit Status

```bash
# Check pod status
kubectl get pods -n logging

# View Fluent Bit logs
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit -f

# Check Fluent Bit metrics endpoint
kubectl port-forward -n logging <fluent-bit-pod-name> 2020:2020
curl http://localhost:2020/api/v1/metrics
```

### View Logs in Google Cloud

1. Go to [Google Cloud Console Logs Explorer](https://console.cloud.google.com/logs)
2. Use query filters:
   ```
   resource.type="k8s_container"
   resource.labels.cluster_name="YOUR_CLUSTER_NAME"
   ```
3. Filter by namespace (if using several namespaces in your Fluent Bit configurations):
   ```
   resource.labels.namespace_name="default"
   ```

## Troubleshooting

### Logs not appearing in GCP

1. Check Fluent Bit logs for errors:
   ```bash
   kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit
   ```

2. Verify GCP credentials are mounted:
   ```bash
   kubectl exec -n logging <fluent-bit-pod> -- ls -la /var/secrets/google/
   ```

3. Test GCP credentials:
   ```bash
   kubectl exec -n logging <fluent-bit-pod> -- cat /var/secrets/google/gcp-credentials.json
   ```

### Permission Issues

Ensure the service account has `roles/logging.logWriter`:
```bash
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
```

### Pod Logs Not Being Collected

Check if the log paths are correct for your container runtime:
- Docker: `/var/lib/docker/containers`
- containerd: `/var/log/pods`

## Cleanup

```bash
# Uninstall Fluent Bit
helm uninstall fluent-bit -n logging

# Delete namespace and secrets
kubectl delete namespace logging

# Delete GCP service account (optional)
gcloud iam service-accounts delete \
    "${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project=$PROJECT_ID
```

