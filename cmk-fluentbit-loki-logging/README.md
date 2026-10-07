# Log aggregation for all pods in a CMK cluster using Fluentbit, Loki and Grafana

A Helm umbrella chart that deploys:

| Component | Role | Chart source |
|-----------|------|--------------|
| **Grafana Loki** (single-binary) | Log aggregation & storage | `grafana/loki` |
| **Fluent Bit** (DaemonSet) | Per-node log collector → Loki | `fluent/fluent-bit` |
| **Grafana datasource ConfigMap** | Auto-wires Loki into Grafana | this chart |

Pod logs are written to a `crusoe-csi-driver-fs-sc` PersistentVolumeClaim (1 Ti minimum). Grafana itself is **not** installed by this chart;
only the datasource ConfigMap is created so the existing Grafana sidecar can discover Loki automatically.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Helm | ≥ 3.10 |
| kubectl | matching cluster version |

Grafana must be deployed from the `grafana/grafana` Helm chart (or compatible)
with the datasource sidecar enabled (`sidecar.datasources.enabled: true`). This requirement is met by
the 'grafana-cmk' solution in this repo (Crusoe Solutions Library), which is what we recommend.

---

## Quick start

```bash
# 1. Add upstream Helm repositories
helm repo add grafana  https://grafana.github.io/helm-charts
helm repo add fluent   https://fluent.github.io/helm-charts
helm repo update

# 2. Fetch subchart tarballs into cmk-logging/charts/
helm dependency update ./cmk-logging

# 3. Install into the same namespace as Grafana
#    (the example below uses "monitoring", as used by grafana-cmk; adjust to match your setup if different)
export KUBECONFIG=$(pwd)/config

helm upgrade --install cmk-logging ./cmk-logging \
  --namespace monitoring \
  --values cmk-logging/values.yaml \
  --wait
```


---

## Architecture

```
┌─────────────────────────────────────────┐
│  Each cluster node                      │
│                                         │
│  /var/log/containers/*.log              │
│         │                               │
│  ┌──────▼──────┐                        │
│  │ Fluent Bit  │ (DaemonSet pod)        │
│  │             │  • tail input          │
│  │             │  • kubernetes filter   │
│  │             │  • loki output         │
│  └──────┬──────┘                        │
└─────────│───────────────────────────────┘
          │ HTTP push (port 80)
          ▼
  ┌───────────────┐      ┌──────────────────────────────┐
  │  Loki gateway │─────▶│  Loki single-binary          │
  │  (nginx)      │      │  • ingester / querier / ruler│
  └───────────────┘      │  • PVC: 1 Ti (crusoe CSI)    │
                         └──────────────────────────────┘
                                    ▲
                         ┌──────────┴──────────┐
                         │  Grafana            │
                         │  (existing install) │
                         │  datasource: Loki   │ ◀── ConfigMap (this chart)
                         └─────────────────────┘
```

---

## Grafana: viewing logs

After install:

1. Open Grafana → **Explore**.
2. Select the **Loki** datasource (auto-configured by the datasource ConfigMap).
3. Use the label browser or LogQL:

```logql
# All logs for a specific namespace
{namespace_name="my-app"}

# Logs containing "ERROR" in a specific pod
{namespace_name="my-app", pod_name=~"my-service-.*"} |= "ERROR"

# Rate of error logs per namespace (for dashboards)
sum by (namespace_name) (rate({namespace_name=~".+"} |= "error" [5m]))
```

For a pre-built dashboard, import Grafana dashboard **ID 15141**
("Kubernetes / Logs / Pod") from grafana.com, which is designed for
Fluent Bit → Loki pipelines.

---

## Configuration reference

### Top-level values

| Key | Default | Description |
|-----|---------|-------------|
| `grafanaDatasource.enabled` | `true` | Create the Loki datasource ConfigMap |
| `grafanaDatasource.grafanaNamespace` | `""` (= release namespace) | Namespace where Grafana runs |
| `grafanaDatasource.sidecarLabel` | `grafana_datasource` | Label key the Grafana sidecar watches |
| `grafanaDatasource.sidecarLabelValue` | `"1"` | Label value |

### Loki key values

| Key | Default | Description |
|-----|---------|-------------|
| `loki.loki.limits_config.retention_period` | `744h` (31 days) | Log retention |
| `loki.singleBinary.persistence.size` | `1Ti` | PVC size (minimum for crusoe CSI) |
| `loki.singleBinary.persistence.storageClass` | `crusoe-csi-driver-fs-sc` | Storage class |

### Fluent Bit key values

| Key | Default | Description |
|-----|---------|-------------|
| `fluent-bit.extraEnvVars[0].value` | `cmk-logging-loki-gateway.monitoring.svc.cluster.local` | Loki gateway hostname |
| `fluent-bit.config.filters` | see values.yaml | Edit the `grep` filter to include/exclude namespaces |

---

## Uninstall

```bash
helm uninstall cmk-logging -n monitoring

# The PVC is NOT deleted automatically (Kubernetes retain policy).
# To free storage:
kubectl delete pvc -n monitoring storage-cmk-logging-loki-0
```
