# Building the Mooncake NVMe-oF image for MI355X

Builds Mooncake `v0.3.12.post1` with `USE_NOF` (SPDK NVMe-oF) and `USE_HIP` on
ROCm, for AMD Instinct MI355X.

The build runs in-cluster with kaniko and pushes straight to your registry.
Roughly 30 to 45 minutes, most of it compiling SPDK and Mooncake.

---

## Before you start

Three things: a registry secret, the ionic provider files, and a build node.

### 1. Registry credentials

The build pushes the finished image, and the validation pods pull it back.
**The build needs push rights, the pods need pull rights.** One secret with
both is simplest, and that is what the manifests assume: `__PULL_SECRET__` is
substituted into the kaniko pod (as push credentials) and into both pod specs
(as `imagePullSecrets`).

Create it as a standard `docker-registry` Secret in the namespace you will
build and run in:

```bash
kubectl -n <namespace> create secret docker-registry <secret-name> \
  --docker-server=<registry-host> \
  --docker-username=<username> \
  --docker-password=<token>
```

<details>
<summary><b>Crusoe Container Registry (CCR) — worked example</b></summary>

```bash
kubectl -n default create secret docker-registry ccr-cred \
  --docker-server=registry.<region>.ccr.crusoecloudcompute.com \
  --docker-username="<your-crusoe-email>" \
  --docker-password="<crusoe-registry-token>"
```

Two things that catch people out:

- **The username is your Crusoe account email address**, not the user UUID and
  not the token ID.
- **The password is a registry token**, created with
  `crusoe registry tokens create`. It is not your console password.

The image path then looks like:

```
registry.<region>.ccr.crusoecloudcompute.com/<registry-name>.<project-short>/mooncake-nof-mi355x:v0.3.12.post1
```

where `<registry-name>.<project-short>` is the registry you created in your
project.

</details>

Any OCI registry works: a cloud registry, a private Harbor, anything kaniko can
authenticate to. Nothing in this build is tied to one provider.

Verify the secret before you spend 40 minutes on a build that cannot push:

```bash
kubectl -n <namespace> get secret <secret-name> \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

You should see your registry host and an `auth` field.

### 2. The ionic provider files

Put these three in `src/ionic-provider/`:

```
libionic-rdmav34.so
libionic.so.1
ionic.driver
```

They are not in this repo. Copy them off any running MI355X node:

```bash
/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so
/usr/lib/x86_64-linux-gnu/libionic.so.1
/etc/libibverbs.d/ionic.driver
```

Without them the image cannot see the Pollara NICs and every RDMA step fails.
See the README's [prerequisites](./README.md#the-ionic-rdma-provider).

### 3. A build node

Any schedulable node with roughly 8 GB of memory free. It does **not** need a
GPU: the Dockerfile stubs `amdgpu-arch` to return `gfx950`, because Mooncake's
CMake otherwise calls it to autodetect the architecture and fails on a GPU-less
node.

---

## Build

### 1. Create the build context

The context is flat even though the sources live in `src/`: kaniko receives
the Dockerfile and the three ionic files side by side, which is why the
Dockerfile's COPY lines use bare filenames.

```bash
kubectl create configmap mooncake-nof-build-context \
  --from-file=Dockerfile=src/Dockerfile.mooncake-nof-mi355x \
  --from-file=src/ionic-provider/libionic-rdmav34.so \
  --from-file=src/ionic-provider/libionic.so.1 \
  --from-file=src/ionic-provider/ionic.driver \
  -n <namespace>
```

The IPv6 address-family fix is applied in-build with `sed`, so
`src/mooncake-ipv6-adrfam.patch` does **not** belong in the context. It is kept in
the repo as the artifact to send upstream.

### 2. Run the build

```bash
sed -e "s#__IMAGE__#<registry>/mooncake-nof-mi355x:v0.3.12.post1#g" \
    -e "s#__PULL_SECRET__#<your-push-secret>#g" \
    src/kaniko-build-mooncake-nof.yaml \
  | kubectl apply -n <namespace> -f -
```

`__IMAGE__` is the full destination including tag. `__PULL_SECRET__` is the
Secret you created in [step 1](#1-registry-credentials) — the same name goes
into both pod specs later.

### 3. Watch it

```bash
kubectl logs -f kaniko-mooncake-nof -n <namespace>
```

---

## What a good build looks like

Four checkpoints, in order:

| | What it proves |
|---|---|
| `HIP dmabuf MR registration enabled` in the cmake log | HIP and dmabuf configured |
| SPDK and DPDK static libraries copied to `/usr/local/lib` | the `USE_NOF` link will resolve |
| `[ xx%] Built target mooncake_store` | `USE_NOF` actually links |
| `spdk-rpc --help` succeeds | the RPC client runs |

The Dockerfile also asserts at build time, so the build **fails** rather than
producing a broken image if any of these are wrong:

- `mooncake.engine` is linked against `libamdhip64` and `libhsa-runtime64`
- `libcudart` is absent from both the Python module and `mooncake_client`
- `nvmf_tgt`, `spdk_nvme_perf` and `spdk-rpc` are present and executable

> Check `mooncake_client`, not `mooncake_master`, for HIP linkage.
> `mooncake_master` is the control plane and does no GPU work, so it links
> neither HIP nor CUDA. Checking the master gives a false negative.

---

## What the image contains

```
/usr/local/bin/nvmf_tgt            SPDK NVMe-oF target
/usr/local/bin/spdk_nvme_perf      benchmark (use this, not fio)
/usr/local/bin/spdk-rpc            wrapper running rpc.py under Python 3.12
/usr/local/bin/mooncake_master     Mooncake control plane
/usr/local/bin/mooncake_client     Mooncake client
/usr/local/share/spdk/scripts/     SPDK RPC scripts
/usr/local/share/spdk/python/      their imports — rpc.py needs ../python
python site-packages/mooncake/     Python bindings (engine, store)
```

The `spdk-rpc` wrapper exists because the vendored SPDK uses
`action='store_true'` on a positional argument, which Python 3.14 rejects. The
base image's Python is 3.14, so the wrapper runs `rpc.py` under the system
Python 3.12 instead. Patching SPDK's CLI would be the wrong fix: there is
likely more than one such argument, and changing them alters the RPC
interface.

Base image:

```
docker.io/rocm/vllm:rocm7.14.1_cdna_ubuntu24.04_py3.14_pytorch_2.11_vllm_0.23.0
```

ROCm 7.14.1, which supports gfx950. **Do not substitute ROCm 6.x** — it
predates MI355X and the build will not produce a working image.

SPDK is whatever version the Mooncake submodule pins at `v0.3.12.post1`;
`dependencies.sh --with-spdk` fetches and builds it, including isa-l.

---

## Alternative: build to a tar, push separately

Only needed when the build node cannot reach the registry directly. Change the
kaniko args from `--destination=__IMAGE__` to:

```yaml
- --no-push
- --tar-path=/output/mooncake-nof-mi355x.tar
```

with an `/output` volume, then push the tar from somewhere that can:

```bash
skopeo copy \
  --dest-authfile /path/to/registry-auth.json \
  docker-archive:/path/to/mooncake-nof-mi355x.tar \
  docker://<registry>/mooncake-nof-mi355x:v0.3.12.post1
```

The auth file:

```json
{
  "auths": {
    "<registry-host>": {
      "username": "<your-registry-user>",
      "password": "<your-registry-token>",
      "auth": "<base64 of username:password>"
    }
  }
}
```

If the push fails on certificate verification, fix the trust chain rather than
adding `--dest-tls-verify=false`. That flag disables verification of the
registry's certificate and sends your push credentials over an unverified
connection. Mount the CA bundle into the pod instead.

The image is large, so this path means moving tens of gigabytes by hand. Prefer
the direct push.

---

## Next

Deploy with `src/mooncake-nvmeof-target-pod.yaml` and
`src/mooncake-nvmeof-initiator-pod.yaml`, substituting `__IMAGE__`,
`__PULL_SECRET__` and the node names. Then follow the
[runbook](./README.md#run).
