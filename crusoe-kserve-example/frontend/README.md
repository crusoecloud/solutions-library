# Open WebUI Frontend

A chat UI ([Open WebUI](https://github.com/open-webui/open-webui)) in front of the vLLM/KServe model, exposed to the internet over HTTPS with a self-signed certificate — and also reachable via `kubectl port-forward`.

## What it deploys

- **Open WebUI** Deployment (SSD-backed PVC for users/chats), pointed at the vLLM OpenAI-compatible endpoint.
- A **Caddy TLS sidecar** terminating HTTPS on `:8443` from a cert-manager–issued self-signed cert.
- A **`LoadBalancer` Service** on `:443`, provisioned by the Crusoe load-balancer controller (annotation `crusoe.ai/manage-firewall-rule: "true"` also opens the firewall).
- A **ClusterIP Service** on `:8080` for port-forwarding.

```
internet ──HTTPS:443──▶ Crusoe LB (VIP) ──nodePort──▶ Caddy :8443 (self-signed TLS) ──▶ Open WebUI :8080 ──▶ vLLM /v1
```

## Prerequisites

- A CMK cluster with KServe installed (`make setup`) and a model deployed (e.g. `make deploy-basic`).
- cert-manager (installed with KServe) for the self-signed cert.

## Deploy

```bash
make deploy-openwebui
```

This installs the Crusoe load-balancer controller if missing, issues the self-signed cert, applies the manifests, and prints the public URL. To point at a model other than the `deploy-basic` default:

```bash
make deploy-openwebui OPENWEBUI_BACKEND_URL=http://<model>-kserve-workload-svc.kserve-test.svc.cluster.local:8000/v1
```

## Access

```bash
make openwebui-url        # public HTTPS URL (self-signed — accept the browser warning)
make openwebui-forward    # http://localhost:8080 (no public IP needed)
```

The first visitor signs up and becomes the admin (`WEBUI_AUTH=True`).

## Security

The `LoadBalancer` exposes the app to `0.0.0.0/0` by default and the cert is self-signed. Before anything beyond a demo:

- Restrict access — add `loadBalancerSourceRanges: ["<your-cidr>"]` to `manifests/50-service-lb.yaml`.
- Swap the self-signed `Issuer` in `manifests/20-tls.yaml` for a real (ACME/DNS) issuer once you have a hostname.
- Claim the admin account immediately so a stranger can't.

## Teardown

```bash
make destroy-openwebui    # removes Open WebUI; leaves KServe + the LB controller
```
