# Building the Mooncake NVMe-oF Image for MI355X

This directory contains the Dockerfile and patch for building Mooncake v0.3.12.post1 with:
- NVMe-oF SSD pool support (`USE_NOF=ON`)
- HIP + dmabuf support for AMD MI355X (gfx950)
- IPv6 address family auto-detection patch
- ROCm 7.14.1 base (via AMD's vLLM image)

## Files

- `Dockerfile.mooncake-nof-mi355x` - Multi-stage build with SPDK v23.01.1 + Mooncake
- `mooncake-ipv6-adrfam.patch` - Fixes hardcoded IPv4 assumption in ssd_register_client.cpp

## Build with Kaniko (in-cluster)

### Prerequisites

1. A Crusoe Managed Kubernetes cluster with access to a container registry
2. Registry push credentials as a Kubernetes Secret (e.g., `gcr-push-secret`)
3. kubectl access to the cluster

### Build Steps

1. **Create ConfigMap with build context:**

```bash
kubectl create configmap mooncake-nof-build-context \
  --from-file=Dockerfile=Dockerfile.mooncake-nof-mi355x \
  --from-file=libionic-rdmav34.so \
  --from-file=libionic.so.1 \
  --from-file=ionic.driver \
  -n <namespace>
```

2. **Create kaniko build pod:**

Using `kaniko-build-mooncake-nof.yaml` in this directory, or inline:

```bash
# Set your registry and secret name
REGISTRY="<your-registry>"
IMAGE_NAME="mooncake-nof-mi355x:v0.3.12.post1"
PULL_SECRET="<your-push-secret>"

# Create the build pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-mooncake-nof
  namespace: <namespace>
spec:
  restartPolicy: Never
  initContainers:
  - name: copy-context
    image: busybox
    command:
    - sh
    - -c
    - |
      mkdir -p /workspace
      cp -L /build-context/* /workspace/
      ls -la /workspace
    volumeMounts:
    - name: build-context
      mountPath: /build-context
    - name: workspace
      mountPath: /workspace
  containers:
  - name: kaniko
    # NOTE: :latest is a mutable tag and this pod holds registry push
    # credentials. Pin a released version or a digest before any
    # repeated or automated use.
    image: gcr.io/kaniko-project/executor:latest
    args:
    - --context=/workspace
    - --dockerfile=/workspace/Dockerfile
    - --destination=${REGISTRY}/${IMAGE_NAME}
    - --cache=true
    - --compressed-caching=false
    volumeMounts:
    - name: workspace
      mountPath: /workspace
    - name: docker-config
      mountPath: /kaniko/.docker
  volumes:
  - name: build-context
    configMap:
      name: mooncake-nof-build-context
  - name: workspace
    emptyDir: {}
  - name: docker-config
    secret:
      secretName: ${PULL_SECRET}
      items:
      - key: .dockerconfigjson
        path: config.json
EOF
```

3. **Monitor the build:**

```bash
kubectl logs -f kaniko-mooncake-nof -n <namespace>
```

The build takes approximately 30-45 minutes and includes:
- SPDK v23.01.1 compilation
- Mooncake compilation with HIP, dmabuf, and NVMe-oF support
- Installation of mooncake_master, mooncake_client, and nvmf_tgt binaries

## Build Verification

The Dockerfile includes sanity checks that verify:
1. `mooncake.engine` Python module is HIP-linked (`libamdhip64`, `libhsa-runtime64`)
2. No CUDA linkage (`libcudart` absent)
3. `mooncake_client` binary is HIP-linked
4. HIP dmabuf MR registration is enabled (build log check)

## Usage

After building, deploy pods using this image for Mooncake NVMe-oF validation:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mooncake-nvmeof-test
spec:
  containers:
  - name: mooncake
    image: <your-registry>/mooncake-nof-mi355x:v0.3.12.post1
    # ... additional configuration
```

The image provides:
- `/usr/local/bin/nvmf_tgt` - SPDK NVMe-oF target
- `/usr/local/bin/mooncake_master` - Mooncake control plane
- `/usr/local/bin/mooncake_client` - Mooncake client for SSD registration
- `/usr/local/share/spdk/scripts/` - SPDK RPC scripts
- Python `mooncake` module in site-packages

## Base Image

`docker.io/rocm/vllm:rocm7.14.1_cdna_ubuntu24.04_py3.14_pytorch_2.11_vllm_0.23.0`

This base provides ROCm 7.14.1 which supports AMD MI355X (gfx950) architecture.

## Pushing to CCR

After the kaniko build completes and produces the tar file, push to CCR:

```bash
# From inside the pod that has the tar file:
skopeo copy \
  --dest-authfile /path/to/ccr-auth.json \
  docker-archive:/tmp/mooncake-image/mooncake-nof-mi355x.tar \
  docker://__IMAGE__
```

If the push fails on certificate verification, fix the trust chain rather than
adding `--dest-tls-verify=false`. That flag disables verification of the
registry's certificate and sends your push credentials over an unverified
connection. Mount the CA bundle into the pod instead.

The auth file contains:
```json
{
  "auths": {
    "<registry-host>": {
      "username": "<your-registry-user>",
      "password": "<CCR_TOKEN>",
      "auth": "<BASE64_ENCODED_USERNAME:PASSWORD>"
    }
  }
}
```
