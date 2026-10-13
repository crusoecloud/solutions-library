# Open WebUI Frontend

A chat UI ([Open WebUI](https://github.com/open-webui/open-webui)) and OpenAI-compatible API in
front of the vLLM/KServe models. It is exposed **privately on a NodePort** (no public
LoadBalancer), supports **self-service accounts + personal API keys**, and **auto-detects** any
model you deploy.

```
client ──▶ NodePort :30080 (private) ──▶ Open WebUI :8080 ──▶ vLLM /v1  (one or more models)
```

Reach it in-cluster, via `make openwebui-forward`, or by putting your **own ingress / gateway /
VPN** in front of the NodePort (which also terminates TLS). Nothing is exposed to the public
internet by default.

## What it deploys

- **Open WebUI** Deployment (RWO PVC for users/chats), pinned to the CPU (`c1a`) pool, pointed at
  the vLLM OpenAI-compatible endpoint(s).
- A **NodePort Service** on `:30080` (plain HTTP) for private access.
- A **model-autodetect CronJob** that keeps the backend list in sync with deployed models.

## Prerequisites

- A CMK cluster with KServe installed (`make setup`) and at least one model deployed (e.g.
  `make deploy-amd-mi355x`).

## Deploy

```bash
make deploy-openwebui
```

Applies `frontend/manifests/`, points Open WebUI at every `*-workload-svc` in the model namespace,
and rolls it out. To pin specific backends instead of auto-detecting:

```bash
make deploy-openwebui OPENWEBUI_BACKEND_URLS='http://a-...:8000/v1;http://b-...:8000/v1'
```

## Access

```bash
make openwebui-url        # how to reach it (NodePort / in-cluster)
make openwebui-forward    # http://localhost:8080 via kubectl port-forward
```

Each served model appears in the dropdown by its served-model-name (e.g. `qwen3`). The first
visitor signs up and becomes the admin (`WEBUI_AUTH=True`).

## Self-service accounts + API keys

Enabled in `manifests/40-openwebui.yaml`:

- **Sign up** at the Open WebUI URL. New users land in `pending`; an **admin approves** them in
  Admin Panel → Users (so access stays limited to approved users).
- Approved users mint a **personal API key** in Settings → Account and drive the models from
  OpenAI-compatible tools (e.g. OpenCode) at `<base>/api` with `Authorization: Bearer <key>`.

## Automatic model detection

`manifests/60-model-autodetect.yaml` runs a small CronJob (every 2 min) that reconciles Open
WebUI's backend list to whatever `*-workload-svc` Services currently have **ready endpoints** — so
a newly-deployed model appears within a couple minutes, and a scaled-to-zero one drops off. It
only patches (and rolls) Open WebUI when the set actually changes.

## Security

The NodePort is private (not exposed publicly by default), but before anything beyond a demo:

- Front the NodePort with your own ingress/gateway/VPN and terminate TLS there.
- Keep signups gated on admin approval (`DEFAULT_USER_ROLE=pending`, already set) and claim the
  admin account immediately.

## Teardown

```bash
make destroy-openwebui    # removes Open WebUI; leaves KServe in place
```
