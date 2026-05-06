# etchosts-pin

A daemon that resolves a hostname on a fixed interval and keeps the resulting A/AAAA records in `/etc/hosts`. Designed to run as a Kubernetes DaemonSet so every node in the cluster gets live, up-to-date entries. Works around undesirable TTL cache values from DNS resolvers

## How it works

On each tick the daemon:

1. Calls `net.LookupHost` against the configured hostname.
2. Reads the current `/etc/hosts`.
3. Replaces its previously written block (demarcated by `BEGIN`/`END` comments) with the freshly resolved addresses.
4. Writes the file back in place.

Records are added, updated, or removed automatically as DNS changes. If a lookup fails, the existing block is left untouched and the error is logged.

### Example `/etc/hosts` entry

```
# BEGIN etchosts-pin:myservice.internal
10.0.1.4	myservice.internal
10.0.1.7	myservice.internal
# END etchosts-pin:myservice.internal
```

## Environment variables

| Variable           | Required | Default       | Description                        |
|--------------------|----------|---------------|------------------------------------|
| `RESOLVE_HOSTNAME` | yes      | —             | Hostname to resolve                |
| `HOSTS_FILE`       | no       | `/etc/hosts`  | Path to the hosts file             |
| `INTERVAL_SECONDS` | no       | `5`           | Polling interval in seconds        |

## Build

```bash
# Local binary (linux/amd64)
make build

# Container image
make docker-build REGISTRY=myregistry.io/ TAG=v1.0.0

# Push
make docker-push REGISTRY=myregistry.io/ TAG=v1.0.0
```

The final image is built `FROM scratch` — no OS, no shell, ~3 MB.

## Deploy

### Helm (recommended)

```bash
helm install etchosts-pin ./helm \
  --set resolveHostname=myservice.internal \
  --set image.repository=myregistry.io/etchosts-pin
```

Key values in `helm/values.yaml`:

| Value | Required | Default | Description |
|---|---|---|---|
| `resolveHostname` | yes | — | Hostname to resolve |
| `image.repository` | yes | — | Image registry and repo |
| `image.tag` | no | `latest` | Image tag |
| `resolvers` | no | — | Comma-separated DNS servers; defaults to `/etc/resolv.conf` |
| `intervalSeconds` | no | `5` | Polling interval in seconds |
| `hostsFile` | no | `/etc/hosts` | Path to hosts file |

### Raw manifest

1. Edit `manifests/daemonset.yaml`:
   - Set `RESOLVE_HOSTNAME` to your target hostname.
   - Replace `REGISTRY/etchosts-pin:latest` with your image reference.

2. Apply:

```bash
kubectl apply -f manifests/daemonset.yaml
```

### Verify

```bash
kubectl exec -n kube-system ds/etchosts-pin -- cat /etc/hosts
# or on the node itself:
cat /etc/hosts
```

## Security notes

- The container runs as `root` (UID 0) — required to write the host's `/etc/hosts`.
- All Linux capabilities are dropped; `allowPrivilegeEscalation` is false.
- The root filesystem is read-only; only `/etc/hosts` (hostPath) is writable.
- No network ports are opened.
