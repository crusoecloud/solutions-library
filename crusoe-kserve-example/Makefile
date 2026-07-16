.PHONY: help setup setup-amd install-kserve patch-storage-initializer install-amd-gpu-operator deploy-basic deploy-large deploy-multi-node deploy-disaggregated deploy-amd-basic deploy-amd-large redeploy-amd-large deploy-amd-multi-node install-lb-controller install-crusoe-autoscaler destroy-crusoe-autoscaler install-vllm-hpa destroy-vllm-hpa install-gateway-scaling destroy-gateway-scaling install-gateway-bypass destroy-gateway-bypass deploy-openwebui openwebui-forward openwebui-url destroy-openwebui watch watch-metrics test chat bench bench-all bench-all-amd bench-amd monitor-up monitor-up-nvidia monitor-up-amd monitor-down monitor-clean destroy

SHELL := /bin/bash
NAMESPACE ?= kserve-test
HF_TOKEN       ?= $(shell grep '^hf_token'       terraform/terraform.tfvars     2>/dev/null | sed 's/.*= *"//;s/"//')
KSERVE_VERSION ?= v0.19.0

# Open WebUI frontend — the vLLM OpenAI endpoint it talks to.
# Leave empty to auto-detect the deployed "*-workload-svc" Service in $(NAMESPACE) (works for any deploy mode);
# set it explicitly to pin a specific backend, e.g. http://qwen3-llm-kserve-workload-svc.$(NAMESPACE).svc.cluster.local:8000/v1
OPENWEBUI_BACKEND_URL ?=

# AMD config — all values read from terraform-amd/terraform.tfvars
_AMD_TFVARS    := terraform-amd/terraform.tfvars
AMD_HF_TOKEN   ?= $(shell grep '^hf_token'        $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
DOCKER_USERNAME ?= $(shell grep '^docker_username' $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
DOCKER_EMAIL    ?= $(shell grep '^docker_email'    $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
DOCKER_PASSWORD  ?= $(shell grep '^docker_password' $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
AMD_DRIVER_IMAGE ?= docker.io/$(DOCKER_USERNAME)/amd-gpu-driver

# Crusoe cluster-autoscaler — auto-provisions on-demand MI355X nodes to back Pending vLLM pods.
# Image tag must match the cluster's k8s minor (this cluster is v1.33.x).
AUTOSCALER_IMAGE ?= ghcr.io/crusoecloud/cluster-autoscaler-crusoecloud:1.33.2-crusoe.8
AUTOSCALER_MIN   ?= 2
AUTOSCALER_MAX   ?= 4
# Must match the GPU node pool's NAME (not its k8s node prefix). The terraform-amd
# default is "amd-pool" (var.amd_pool_name); override if you renamed the pool. A
# mismatch here fails silently — the autoscaler logs "skipping nodepool" and never scales.
AUTOSCALER_POOL  ?= amd-pool

# vLLM pod HPA (KEDA + Prometheus on vllm:num_requests_running) between SCALE_MIN/MAX.
# NOTE: on KServe LLMInferenceService the standalone ScaledObject does not actuate — KServe owns
# spec.replicas and reverts external scaling. This installs the metric pipeline + signal; real
# actuation needs spec.scaling.wva (see manifests/keda-scaledobject.yaml header).
KEDA_VERSION    ?= 2.16.1
SCALE_MIN       ?= 2
SCALE_MAX       ?= 4
SCALE_THRESHOLD ?= 100   # target running seqs per replica (num_requests_running); scale out above this

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup (cluster + KServe + namespace — all via Terraform)
# ---------------------------------------------------------------------------

setup: ## Provision cluster, install KServe, create namespace (terraform apply)
	cd terraform && \
	  cp -n terraform.tfvars.example terraform.tfvars 2>/dev/null || true && \
	  terraform init && \
	  terraform apply

setup-amd: ## Provision AMD cluster (CMK-managed AMD GPU/network add-ons) + install KServe. Edit terraform-amd/terraform.tfvars first.
	cd terraform-amd && \
	  cp -n terraform.tfvars.example terraform.tfvars 2>/dev/null || true && \
	  terraform init && \
	  terraform apply
	@echo "AMD GPU + network operators are CMK-managed via cluster add-ons — no manual operator install."
	@echo "The managed operator reconciles the GPU driver in the background; verify before deploying with:"
	@echo "  kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:'.status.allocatable.amd\\.com/gpu'"
	$(MAKE) install-kserve HF_TOKEN=$(AMD_HF_TOKEN)

install-amd-gpu-operator: ## [LEGACY: crusoe_csi-only clusters] Manually install cert-manager + AMD GPU operator (needs DOCKER_USERNAME/EMAIL/PASSWORD). NOT needed with the default managed amd_gpu_operator add-on.
	@if [ -z "$(DOCKER_USERNAME)" ] || [ -z "$(DOCKER_EMAIL)" ] || [ -z "$(DOCKER_PASSWORD)" ]; then \
	  echo "ERROR: DOCKER_USERNAME, DOCKER_EMAIL, and DOCKER_PASSWORD are required."; \
	  echo "  make install-amd-gpu-operator DOCKER_USERNAME=you DOCKER_EMAIL=you@example.com DOCKER_PASSWORD=... AMD_DRIVER_IMAGE=docker.io/you/amd-gpu-driver"; \
	  exit 1; \
	fi
	@set -euo pipefail; \
	echo "[1/4] Adding Helm repos and installing cert-manager v1.15.1..."; \
	helm repo add jetstack https://charts.jetstack.io --force-update && helm repo update; \
	helm install cert-manager jetstack/cert-manager \
	  --namespace cert-manager \
	  --create-namespace \
	  --version v1.15.1 \
	  --set crds.enabled=true; \
	echo "[2/4] Installing AMD GPU operator v1.4.2..."; \
	helm repo add rocm https://rocm.github.io/gpu-operator && helm repo update; \
	helm install amd-gpu-operator rocm/gpu-operator-charts \
	  --namespace kube-amd-gpu --create-namespace \
	  --version v1.4.2; \
	echo "[3/4] Creating Docker registry secret..."; \
	kubectl create secret docker-registry my-docker-secret -n kube-amd-gpu \
	  --docker-username=$(DOCKER_USERNAME) \
	  --docker-email=$(DOCKER_EMAIL) \
	  --docker-password=$(DOCKER_PASSWORD) \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	echo "[4/4] Applying AMD DeviceConfig..."; \
	AMD_DRIVER_IMAGE=$(AMD_DRIVER_IMAGE) envsubst < manifests/amd-device-config.yaml | kubectl apply -f -; \
	echo "=== AMD GPU operator installation complete ==="

install-kserve: ## Install KServe on an existing cluster (skips Terraform infra)
	@if [ -z "$(HF_TOKEN)" ]; then echo "ERROR: HF_TOKEN is required. Run: make install-kserve HF_TOKEN=hf_..."; exit 1; fi
	@set -euo pipefail; \
	BASE_URL="https://github.com/kserve/kserve/releases/download/$(KSERVE_VERSION)"; \
	echo "=== Installing KServe $(KSERVE_VERSION) ==="; \
	echo "[1/5] Installing standard mode dependencies..."; \
	curl -fsSL "$${BASE_URL}/kserve-standard-mode-dependency-install.sh" | bash; \
	echo "[2/5] Installing LLMInferenceService dependencies..."; \
	curl -fsSL "$${BASE_URL}/llmisvc-dependency-install.sh" | bash; \
	echo "[3/5] Installing KServe CRDs..."; \
	kubectl apply --server-side -f "$${BASE_URL}/kserve-crds.yaml"; \
	kubectl wait --for=condition=Established crds --all --timeout=60s; \
	echo "[4/5] Installing KServe controller..."; \
	kubectl apply --server-side --force-conflicts -f "$${BASE_URL}/kserve.yaml"; \
	kubectl wait --for=condition=ready pod \
	  -l control-plane=kserve-controller-manager \
	  -n kserve --timeout=300s; \
	echo "Waiting for webhook endpoint..."; \
	for i in $$(seq 1 30); do \
	  if kubectl get endpoints kserve-webhook-server-service -n kserve \
	       -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then \
	    echo "Webhook endpoint ready."; break; \
	  fi; \
	  echo "Waiting for webhook... ($$i/30)"; sleep 5; \
	done; \
	echo "[5/5] Installing KServe cluster resources..."; \
	kubectl apply --server-side -f "$${BASE_URL}/kserve-cluster-resources.yaml"; \
	echo "Patching storage-initializer for large model downloads..."; \
	kubectl patch configmap inferenceservice-config -n kserve --type merge -p \
	  '{"data":{"storageInitializer":"{\"image\":\"kserve/storage-initializer:$(KSERVE_VERSION)\",\"memoryRequest\":\"8Gi\",\"memoryLimit\":\"256Gi\",\"cpuRequest\":\"4\",\"cpuLimit\":\"32\",\"envVars\":[{\"name\":\"HF_HUB_DISABLE_XET\",\"value\":\"1\"}],\"caBundleConfigMapName\":\"\",\"caBundleVolumeMountPath\":\"/etc/ssl/custom-certs\",\"enableModelcar\":true,\"cpuModelcar\":\"10m\",\"memoryModelcar\":\"15Mi\",\"uidModelcar\":1010}"}}'; \
	echo "Creating namespace and HuggingFace secret..."; \
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create secret generic hf-secret \
	  --from-literal=HF_TOKEN=$(HF_TOKEN) \
	  -n $(NAMESPACE) \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	echo "=== KServe $(KSERVE_VERSION) installation complete ==="

patch-storage-initializer: ## Patch storage-initializer configmap for large model downloads (run after KServe is installed)
	kubectl patch configmap inferenceservice-config -n kserve --type merge -p \
	  '{"data":{"storageInitializer":"{\"image\":\"kserve/storage-initializer:$(KSERVE_VERSION)\",\"memoryRequest\":\"8Gi\",\"memoryLimit\":\"256Gi\",\"cpuRequest\":\"4\",\"cpuLimit\":\"32\",\"envVars\":[{\"name\":\"HF_HUB_DISABLE_XET\",\"value\":\"1\"}],\"caBundleConfigMapName\":\"\",\"caBundleVolumeMountPath\":\"/etc/ssl/custom-certs\",\"enableModelcar\":true,\"cpuModelcar\":\"10m\",\"memoryModelcar\":\"15Mi\",\"uidModelcar\":1010}"}}'
	kubectl rollout restart deployment kserve-controller-manager -n kserve
	@echo "Storage-initializer patched. New limits: 256Gi RAM, 32 CPU. Xet disabled."

# ---------------------------------------------------------------------------
# Deploy (Helm)
# ---------------------------------------------------------------------------

deploy-basic: ## Deploy single-GPU LLM (Qwen2.5-0.5B on 1x A100 or H100)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=true \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set basic.args[0]="--gpu-memory-utilization" \
	  --set basic.args[1]="0.95" \
	  --set basic.args[2]="--enable-chunked-prefill" \
	  --set basic.args[3]="--max-num-batched-tokens" \
	  --set-string basic.args[4]="4096" \
	  --set basic.args[5]="--enable-auto-tool-choice" \
	  --set basic.args[6]="--tool-call-parser" \
	  --set basic.args[7]="hermes"

deploy-large: ## Deploy large single-node LLM (Qwen2.5-72B on 8x H100, TP=8) — edit values.yaml large: to change model/resources
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set large.enabled=true \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set modelStorage.enabled=true \
	  --set modelStorage.size=250Gi \
	  --set large.args[0]="--gpu-memory-utilization" \
	  --set large.args[1]="0.95" \
	  --set large.args[2]="--tensor-parallel-size" \
	  --set-string large.args[3]="8" \
	  --set large.args[4]="--enable-chunked-prefill" \
	  --set large.args[5]="--max-num-batched-tokens" \
	  --set-string large.args[6]="8192"

deploy-multi-node: ## Deploy multi-node LLM (Qwen2.5-72B on 2x8 A100 or H100)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set multiNode.enabled=true \
	  --set disaggregated.enabled=false

deploy-amd-basic: ## Deploy single-GPU LLM on AMD MI300X (Qwen2.5-0.5B)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set amd.basic.enabled=true \
	  --set multiNode.enabled=false \
	  --set amd.multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set amd.basic.args[0]="--gpu-memory-utilization" \
	  --set amd.basic.args[1]="0.95" \
	  --set amd.basic.args[2]="--enable-chunked-prefill" \
	  --set amd.basic.args[3]="--max-num-batched-tokens" \
	  --set-string amd.basic.args[4]="4096"

deploy-amd-large: ## Deploy large single-node LLM on AMD MI300X (MiniMax-M2 on 8x MI300X, TP=8) — edit values.yaml amd.large: to change model/resources
	kubectl delete pvc model-storage -n $(NAMESPACE) --ignore-not-found
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set amd.basic.enabled=false \
	  --set amd.large.enabled=true \
	  --set multiNode.enabled=false \
	  --set amd.multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set modelStorage.enabled=true \
	  --set modelStorage.size=1500Gi \
	  --set amd.large.args[0]="--gpu-memory-utilization" \
	  --set amd.large.args[1]="0.95" \
	  --set amd.large.args[2]="--tensor-parallel-size" \
	  --set-string amd.large.args[3]="8" \
	  --set amd.large.args[4]="--enable-expert-parallel" \
	  --set amd.large.args[5]="--reasoning-parser" \
	  --set amd.large.args[6]="minimax_m2_append_think" \
	  --set amd.large.args[7]="--trust-remote-code"

redeploy-amd-large: ## Update AMD large model args without deleting PVC (preserves downloaded model)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set amd.basic.enabled=false \
	  --set amd.large.enabled=true \
	  --set multiNode.enabled=false \
	  --set amd.multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set modelStorage.enabled=true \
	  --set modelStorage.size=1500Gi \
	  --set amd.large.args[0]="--gpu-memory-utilization" \
	  --set amd.large.args[1]="0.95" \
	  --set amd.large.args[2]="--tensor-parallel-size" \
	  --set-string amd.large.args[3]="8" \
	  --set amd.large.args[4]="--enable-expert-parallel" \
	  --set amd.large.args[5]="--reasoning-parser" \
	  --set amd.large.args[6]="minimax_m2_append_think" \
	  --set amd.large.args[7]="--trust-remote-code"

deploy-amd-multi-node: ## Deploy multi-node LLM on AMD MI300X (MiniMax-M2 on 2x8)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set amd.basic.enabled=false \
	  --set multiNode.enabled=false \
	  --set amd.multiNode.enabled=true \
	  --set disaggregated.enabled=false

# Replicas for the MI355X mode. Deploy at 1 first (weights download once to the
# shared disk), THEN re-run with REPLICAS=<node count> to put every node to work.
REPLICAS ?= 1
# AUTOSCALE=1 hands replica count to the autoscaler (emits spec.scaling instead of a fixed replicas).
AUTOSCALE ?=

# --force-conflicts (below): re-running deploy-amd-mi355x to change REPLICAS re-applies the
# LLMInferenceService via server-side apply (helm 3.18+/4). KServe's controller (and any prior
# `kubectl patch/scale`) co-own spec.replicas, so a plain apply fails with "conflicts with
# before-first-apply". Forcing conflicts lets the chart reclaim the helm-templated fields it
# owns (spec.replicas, resources.limits) -- the intended source of truth.
deploy-amd-mi355x: ## Deploy large single-node LLM on AMD MI355X gfx950 (Qwen3-235B on 8x MI355X, TP=8+EP) w/ RWX shared disk + tool calling. REPLICAS=N to use N nodes.
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --force-conflicts \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set large.enabled=false \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set amd.basic.enabled=false \
	  --set amd.large.enabled=false \
	  --set amd.multiNode.enabled=false \
	  --set amd.mi355x.enabled=true \
	  --set amd.mi355x.replicas=$(REPLICAS) \
	  $(if $(AUTOSCALE),--set amd.mi355x.autoscaling.enabled=true,) \
	  --set amd.mi355x.args[0]="--gpu-memory-utilization" \
	  --set amd.mi355x.args[1]="0.9" \
	  --set amd.mi355x.args[2]="--tensor-parallel-size" \
	  --set-string amd.mi355x.args[3]="8" \
	  --set amd.mi355x.args[4]="--enable-expert-parallel" \
	  --set amd.mi355x.args[5]="--max-model-len" \
	  --set-string amd.mi355x.args[6]="32768" \
	  --set amd.mi355x.args[7]="--enable-auto-tool-choice" \
	  --set amd.mi355x.args[8]="--tool-call-parser" \
	  --set amd.mi355x.args[9]="hermes"
	@echo ""
	@echo "Weights persist on the RWX shared disk (model-storage-shared). Re-run this target"
	@echo "to update args: the pod recompiles AITER kernels (~10-15 min) but does not re-download."
	@echo "Scale to all nodes once weights are downloaded: make deploy-amd-mi355x REPLICAS=<node count>"

deploy-disaggregated: ## Deploy disaggregated prefill-decode (needs KServe v0.19.0+; set model/TP/GPUs/labels in values.yaml disaggregated:)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=true

# ---------------------------------------------------------------------------
# Frontend (Open WebUI)
# ---------------------------------------------------------------------------

install-lb-controller: ## Install the Crusoe load-balancer controller (enables type=LoadBalancer external IPs)
	@if helm status crusoe-lb-controller -n crusoe-system >/dev/null 2>&1; then \
	  echo "crusoe-lb-controller already installed."; \
	else \
	  echo "Installing crusoe-lb-controller into crusoe-system..."; \
	  TMP=$$(mktemp -d); \
	  git clone --depth 1 https://github.com/crusoecloud/crusoe-load-balancer-controller-helm-charts.git $$TMP; \
	  helm install crusoe-lb-controller $$TMP/charts/crusoe-lb-controller -n crusoe-system; \
	  rm -rf $$TMP; \
	fi
	@kubectl wait --for=condition=Ready pod -n crusoe-system -l app=crusoe-lb-controller --timeout=120s

install-crusoe-autoscaler: ## Install the Crusoe cluster-autoscaler (auto-provisions on-demand MI355X nodes for Pending pods). AUTOSCALER_MIN/MAX/POOL/IMAGE to tune.
	@set -euo pipefail; \
	if ! kubectl get secret crusoe-secrets -n crusoe-system >/dev/null 2>&1; then \
	  echo "ERROR: Secret 'crusoe-secrets' not found in crusoe-system (autoscaler credentials — normally pre-provisioned by CMK)."; exit 1; \
	fi; \
	echo "Installing Crusoe cluster-autoscaler: image=$(AUTOSCALER_IMAGE), nodes=$(AUTOSCALER_MIN):$(AUTOSCALER_MAX):$(AUTOSCALER_POOL)"; \
	AUTOSCALER_IMAGE="$(AUTOSCALER_IMAGE)" AUTOSCALER_NODES="$(AUTOSCALER_MIN):$(AUTOSCALER_MAX):$(AUTOSCALER_POOL)" \
	  envsubst < manifests/cluster-autoscaler.yaml | kubectl apply --server-side -f -; \
	kubectl -n crusoe-system rollout status deploy/cluster-autoscaler --timeout=180s
	@echo "cluster-autoscaler installed. Bounds: $(AUTOSCALER_MIN):$(AUTOSCALER_MAX) on pool $(AUTOSCALER_POOL)."
	@echo "Watch it: kubectl -n crusoe-system logs deploy/cluster-autoscaler -f"

destroy-crusoe-autoscaler: ## Remove the Crusoe cluster-autoscaler (node count returns to manual control)
	AUTOSCALER_IMAGE=x AUTOSCALER_NODES=x envsubst < manifests/cluster-autoscaler.yaml | kubectl delete --ignore-not-found -f -

install-vllm-hpa: ## Install vLLM pod-autoscaling metric pipeline (KEDA + Prometheus on vllm:num_requests_running). See manifest header — does not actuate against KServe's owned replicas. SCALE_MIN/MAX/THRESHOLD to tune.
	@set -euo pipefail; \
	echo "[1/3] Installing KEDA $(KEDA_VERSION) (ns keda)..."; \
	helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true; helm repo update kedacore >/dev/null; \
	helm upgrade --install keda kedacore/keda --namespace keda --create-namespace --version $(KEDA_VERSION) --wait; \
	echo "[2/3] Deploying lightweight Prometheus that scrapes the vLLM pods..."; \
	kubectl apply -f manifests/prometheus-vllm.yaml; \
	kubectl -n vllm-metrics rollout status deploy/prometheus-vllm --timeout=120s; \
	echo "[3/3] Applying KEDA ScaledObject (min=$(SCALE_MIN) max=$(SCALE_MAX) threshold=$(SCALE_THRESHOLD) running-seqs/replica)..."; \
	SCALE_MIN="$(SCALE_MIN)" SCALE_MAX="$(SCALE_MAX)" SCALE_THRESHOLD="$(SCALE_THRESHOLD)" \
	  envsubst < manifests/keda-scaledobject.yaml | kubectl apply -f -
	@echo "Metric pipeline installed. Inspect: kubectl get scaledobject,hpa -n kserve-test"
	@echo "The HPA reads the signal but does NOT actuate KServe-owned replicas (see manifest header)."

destroy-vllm-hpa: ## Remove vLLM pod autoscaling (KEDA ScaledObject + Prometheus; leaves KEDA installed)
	-SCALE_MIN=2 SCALE_MAX=4 SCALE_THRESHOLD=10 envsubst < manifests/keda-scaledobject.yaml | kubectl delete --ignore-not-found -f -
	-kubectl delete -f manifests/prometheus-vllm.yaml --ignore-not-found

install-gateway-scaling: ## Scale the Envoy gateway data plane + raise circuit breakers (removes the ~128-concurrent HTTP-500 cliff). EPP CPU is set by the chart (deploy-amd-mi355x).
	@set -euo pipefail; \
	echo "[1/3] Applying EnvoyProxy (3x proxy replicas) + BackendTrafficPolicy circuit breakers..."; \
	kubectl apply -f manifests/gateway-scaling.yaml; \
	echo "[2/3] Pointing the GatewayClass at the EnvoyProxy (parametersRef)..."; \
	kubectl patch gatewayclass envoy --type merge \
	  -p '{"spec":{"parametersRef":{"group":"gateway.envoyproxy.io","kind":"EnvoyProxy","name":"kserve-gw-scale","namespace":"envoy-gateway-system"}}}'; \
	echo "[3/3] Waiting for the scaled Envoy proxy deployment to roll out..."; \
	sleep 8; \
	DEP=$$(kubectl get deploy -n envoy-gateway-system -o name | grep -i 'envoy-kserve' | head -1); \
	[ -n "$$DEP" ] && kubectl -n envoy-gateway-system rollout status "$$DEP" --timeout=180s || echo "(proxy deployment not found yet; check: kubectl get deploy -n envoy-gateway-system)"
	@echo "Gateway data plane scaled. Verify: kubectl get deploy -n envoy-gateway-system | grep envoy-kserve"
	@echo "Re-test through the LB: make bench-amd-mi355x-lb BENCH_CONCURRENCY=256 BENCH_RATE=inf"

destroy-gateway-scaling: ## Revert gateway data-plane scaling (back to the default single Envoy proxy + circuit breakers)
	-kubectl patch gatewayclass envoy --type json -p '[{"op":"remove","path":"/spec/parametersRef"}]' 2>/dev/null
	-kubectl delete -f manifests/gateway-scaling.yaml --ignore-not-found

# Route standard client paths straight to the vLLM Service (Envoy least_request L7 LB),
# bypassing the InferencePool+EPP whose single ext_proc caps the gateway at ~1.2k tok/s.
# Measured ~13x throughput and near-linear GPU scaling vs the EPP path. Override the vars
# below for a different ISVC/namespace.
ISVC_NAME          ?= qwen3-llm
ISVC_PATH          ?= /$(NAMESPACE)/$(ISVC_NAME)
WORKLOAD_SVC       ?= $(ISVC_NAME)-kserve-workload-svc
GATEWAY_NAME       ?= kserve-ingress-gateway
GATEWAY_NAMESPACE  ?= kserve

install-gateway-bypass: ## Make the standard gateway path use least_request LB across GPUs (bypass the EPP throughput cap ~1.2k->~15k tok/s). ISVC_NAME/ISVC_PATH/WORKLOAD_SVC to tune.
	@echo "Routing $(ISVC_PATH)/v1/* -> Service $(WORKLOAD_SVC) (Envoy least_request, bypassing EPP)..."
	@NAMESPACE="$(NAMESPACE)" ISVC_NAME="$(ISVC_NAME)" ISVC_PATH="$(ISVC_PATH)" WORKLOAD_SVC="$(WORKLOAD_SVC)" \
	  GATEWAY_NAME="$(GATEWAY_NAME)" GATEWAY_NAMESPACE="$(GATEWAY_NAMESPACE)" \
	  envsubst < manifests/gateway-bypass-route.yaml | kubectl apply -f -
	@echo "Done. Standard OpenAI paths now bypass the EPP. Verify: make bench-amd-mi355x-lb"

destroy-gateway-bypass: ## Remove the bypass route (standard paths fall back to EPP/InferencePool routing)
	-kubectl delete httproute $(ISVC_NAME)-bypass-epp -n $(NAMESPACE) --ignore-not-found

deploy-openwebui: install-lb-controller ## Deploy Open WebUI chat frontend with self-signed TLS on :443 via a Crusoe LoadBalancer
	kubectl apply -f frontend/manifests/00-namespace.yaml
	kubectl apply -f frontend/manifests/20-tls.yaml
	@echo "Waiting for the self-signed certificate to be issued..."
	kubectl wait --for=condition=Ready certificate/openwebui-tls -n openwebui --timeout=120s
	kubectl apply -f frontend/manifests/
	@set -e; \
	BACKEND="$(OPENWEBUI_BACKEND_URL)"; \
	if [ -z "$$BACKEND" ]; then \
	  SVC=$$(kubectl get svc -n $(NAMESPACE) -o name | grep workload | head -1 | sed 's|service/||'); \
	  if [ -z "$$SVC" ]; then echo "ERROR: no '*workload*' Service in $(NAMESPACE) — deploy a model first (e.g. make deploy-amd-mi355x), then re-run."; exit 1; fi; \
	  BACKEND="http://$$SVC.$(NAMESPACE).svc.cluster.local:8000/v1"; \
	  echo "Auto-detected backend Service: $$SVC"; \
	fi; \
	echo "Open WebUI backend -> $$BACKEND"; \
	kubectl set env deploy/open-webui -n openwebui OPENAI_API_BASE_URL="$$BACKEND"; \
	kubectl rollout status deploy/open-webui -n openwebui --timeout=600s; \
	echo "Waiting for the LoadBalancer VIP (crusoe-lb-controller)..."; \
	IP=""; for i in $$(seq 1 30); do \
	  IP=$$(kubectl get svc openwebui-lb -n openwebui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
	  [ -n "$$IP" ] && break; sleep 6; done; \
	echo ""; \
	echo "=== Open WebUI is up ==="; \
	echo "  Public HTTPS : https://$$IP  (self-signed cert — accept the browser warning)"; \
	echo "  Backend      : $$BACKEND"; \
	echo "  The model appears automatically from the backend's /v1/models (served-model-name, e.g. qwen3)."; \
	echo "  Port-forward : make openwebui-forward   (then http://localhost:8080)"; \
	echo "  First visitor signs up and becomes admin (WEBUI_AUTH=True)."

openwebui-forward: ## Port-forward Open WebUI to http://localhost:8080 (no public IP needed)
	@echo "Open WebUI at http://localhost:8080 (Ctrl-C to stop)"
	kubectl port-forward -n openwebui svc/openwebui 8080:8080

openwebui-url: ## Print the Open WebUI public HTTPS URL
	@IP=$$(kubectl get svc openwebui-lb -n openwebui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
	if [ -n "$$IP" ]; then echo "https://$$IP"; else echo "LoadBalancer VIP not assigned yet — check 'kubectl get svc openwebui-lb -n openwebui'"; fi

destroy-openwebui: ## Remove Open WebUI (leaves the LB controller and KServe in place)
	kubectl delete -f frontend/manifests/ --ignore-not-found

# ---------------------------------------------------------------------------
# Test & Benchmark
# ---------------------------------------------------------------------------

PORT  ?= 8080
MODEL ?=

chat: ## Interactive streaming chat with the deployed model (MODEL=<name> to override auto-detect)
	@SVC=$$(kubectl get svc -n $(NAMESPACE) -o name | grep workload | head -1) && \
	echo "Port-forwarding $$SVC to localhost:$(PORT)..." && \
	{ kubectl port-forward -n $(NAMESPACE) $$SVC $(PORT):8000 >/dev/null 2>/dev/null & } && \
	PF_PID=$$! && \
	sleep 2 && \
	python3 scripts/chat.py \
	  --url http://localhost:$(PORT) \
	  $$([ -n "$(MODEL)" ] && echo "--model $(MODEL)" || true) || true; \
	kill $$PF_PID 2>/dev/null || true

test: ## Port-forward and send a test chat request (auto-detects the served model; MODEL=<name> to override)
	@SVC=$$(kubectl get svc -n $(NAMESPACE) -o name | grep workload | head -1) && \
	echo "Port-forwarding $$SVC to localhost:$(PORT)..." && \
	{ kubectl port-forward -n $(NAMESPACE) $$SVC $(PORT):8000 >/dev/null 2>/dev/null & } && \
	PF_PID=$$! && \
	sleep 3 && \
	MODEL_NAME="$(MODEL)"; \
	[ -n "$$MODEL_NAME" ] || MODEL_NAME=$$(curl -s http://localhost:$(PORT)/v1/models | jq -r '.data[0].id'); \
	echo "Testing model '$$MODEL_NAME'..." && \
	jq --arg m "$$MODEL_NAME" '.model = $$m' chat-test.json | \
	  curl -s -H "Content-Type: application/json" \
	    http://localhost:$(PORT)/v1/chat/completions -d @- | jq . || true; \
	kill $$PF_PID 2>/dev/null || true

BENCH_NUM_PROMPTS ?= 200
BENCH_RATE        ?= 50
BENCH_INPUT_LEN   ?= 512
BENCH_OUTPUT_LEN  ?= 150
BENCH_MODEL       ?=          # served-model-name; blank => each target's default (qwen / minimax / qwen3)
BENCH_CONCURRENCY ?=          # max in-flight requests (--max-concurrency). Blank = unbounded (open-loop,
                              # arrival-rate driven). Set to your target concurrent-user count for a
                              # closed-loop test (e.g. BENCH_CONCURRENCY=200 BENCH_RATE=inf ~ 200 active users).

# $(1) is the per-target default served-model-name; BENCH_MODEL on the command line overrides it.
_bench_run = kubectl exec -n $(NAMESPACE) deploy/$$DEPLOY -c main -- \
	  vllm bench serve \
	    --model /mnt/models \
	    --served-model-name $(or $(BENCH_MODEL),$(1)) \
	    --base-url http://localhost:8000 \
	    --backend openai-chat \
	    --endpoint /v1/chat/completions \
	    --dataset-name random \
	    --random-output-len $(BENCH_OUTPUT_LEN)

bench: ## Run a benchmark (NVIDIA; served-model-name qwen — override with BENCH_MODEL=, plus BENCH_RATE/BENCH_INPUT_LEN/BENCH_NUM_PROMPTS)
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||') && \
	echo "Running vLLM benchmark on $$DEPLOY..." && \
	$(call _bench_run,qwen) \
	    --random-input-len $(BENCH_INPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) \
	    --request-rate $(BENCH_RATE)

bench-amd: ## Run a benchmark (AMD MI300X; served-model-name minimax — override with BENCH_MODEL=)
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||') && \
	echo "Running vLLM benchmark on $$DEPLOY (AMD)..." && \
	$(call _bench_run,minimax) \
	    --random-input-len $(BENCH_INPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) \
	    --request-rate $(BENCH_RATE)

bench-amd-mi355x: ## Run a benchmark (AMD MI355X; served-model-name qwen3 — override with BENCH_MODEL=)
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||') && \
	echo "Running vLLM benchmark on $$DEPLOY (AMD MI355X)..." && \
	$(call _bench_run,qwen3) \
	    --random-input-len $(BENCH_INPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) \
	    --request-rate $(BENCH_RATE)

bench-amd-mi355x-all: ## Benchmark EVERY replica pod at once (loads all nodes; reports per-pod + aggregate). BENCH_* apply per node.
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||'); \
	PODS=$$(kubectl get pods -n $(NAMESPACE) -o name | sed 's|pod/||' | grep "^$$DEPLOY-" | grep -vE 'router|epp|scheduler'); \
	N=$$(printf '%s\n' "$$PODS" | grep -c .); \
	if [ "$$N" -lt 1 ]; then echo "No workload pods found for $$DEPLOY"; exit 1; fi; \
	echo "Benchmarking $$N replica pod(s) concurrently — each drives its own node at $(BENCH_RATE) req/s:"; \
	printf '  - %s\n' $$PODS; \
	TMP=$$(mktemp -d); \
	for POD in $$PODS; do \
	  kubectl exec -n $(NAMESPACE) $$POD -c main -- vllm bench serve \
	    --model /mnt/models --served-model-name $(or $(BENCH_MODEL),qwen3) \
	    --base-url http://localhost:8000 --backend openai-chat --endpoint /v1/chat/completions \
	    --dataset-name random --random-input-len $(BENCH_INPUT_LEN) --random-output-len $(BENCH_OUTPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) --request-rate $(BENCH_RATE) > "$$TMP/$$POD.log" 2>&1 & \
	done; \
	wait; \
	echo ""; echo "===== per-pod results ====="; \
	for POD in $$PODS; do \
	  echo "--- $$POD ---"; \
	  grep -iE '^(request throughput|output token throughput|median ttft|median tpot)' "$$TMP/$$POD.log" || echo "  (no results — see $$TMP/$$POD.log)"; \
	done; \
	echo ""; echo "===== aggregate across $$N node(s) ====="; \
	grep -hiE '^request throughput'      "$$TMP"/*.log | awk '{s+=$$NF} END{printf "  Request throughput (req/s):      %.2f\n", s}'; \
	grep -hiE '^output token throughput' "$$TMP"/*.log | awk '{s+=$$NF} END{printf "  Output token throughput (tok/s): %.1f\n", s}'; \
	grep -hiE '^total token throughput'  "$$TMP"/*.log | awk '{s+=$$NF} END{printf "  Total token throughput (tok/s):  %.1f\n", s}'; \
	rm -rf "$$TMP"

bench-amd-mi355x-lb: ## Benchmark THROUGH the Envoy gateway/EPP — production path, requests load-balanced per-request across replicas. BENCH_CONCURRENCY=N caps in-flight.
	@GW=$$(kubectl get gateway kserve-ingress-gateway -n kserve -o jsonpath='{.status.addresses[0].value}' 2>/dev/null); \
	ISVC=$$(kubectl get llminferenceservice -n $(NAMESPACE) -o name 2>/dev/null | head -1 | sed 's|.*/||'); \
	DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||'); \
	if [ -z "$$GW" ] || [ -z "$$ISVC" ]; then echo "Could not resolve the Envoy gateway (kserve/kserve-ingress-gateway) address or an LLMInferenceService in $(NAMESPACE)."; exit 1; fi; \
	BASE="http://$$GW/$(NAMESPACE)/$$ISVC"; \
	echo "Driving load THROUGH the Envoy gateway (EPP load-balances each request across replicas):"; \
	echo "  endpoint:        $$BASE/v1/chat/completions"; \
	echo "  arrival rate:    $(BENCH_RATE) req/s   |   in-flight cap: $(if $(BENCH_CONCURRENCY),$(BENCH_CONCURRENCY),unbounded)   |   prompts: $(BENCH_NUM_PROMPTS)"; \
	kubectl exec -n $(NAMESPACE) deploy/$$DEPLOY -c main -- vllm bench serve \
	  --model /mnt/models --served-model-name $(or $(BENCH_MODEL),qwen3) \
	  --base-url $$BASE --backend openai-chat --endpoint /v1/chat/completions \
	  --dataset-name random --random-input-len $(BENCH_INPUT_LEN) --random-output-len $(BENCH_OUTPUT_LEN) \
	  --num-prompts $(BENCH_NUM_PROMPTS) --request-rate $(BENCH_RATE) \
	  $(if $(BENCH_CONCURRENCY),--max-concurrency $(BENCH_CONCURRENCY),)

# ---------------------------------------------------------------------------
# Local monitoring (Grafana + Prometheus via Docker)
# ---------------------------------------------------------------------------

monitor-up-nvidia: ## Start Grafana with NVIDIA dashboard (gpu-inference)
	@test -f monitoring/env || \
	  (echo "ERROR: create monitoring/env with CRUSOE_PROJECT_ID and CRUSOE_MONITORING_TOKEN"; exit 1)
	@cd monitoring && DASHBOARDS_DIR=./grafana/dashboards/nvidia docker compose up -d
	@cd monitoring && CLUSTER=nvidia python3 setup.py

monitor-up-amd: ## Start Grafana with AMD dashboard (amd-gpu-inference)
	@test -f monitoring/env || \
	  (echo "ERROR: create monitoring/env with CRUSOE_PROJECT_ID and CRUSOE_MONITORING_TOKEN"; exit 1)
	@cd monitoring && DASHBOARDS_DIR=./grafana/dashboards/amd docker compose up -d
	@cd monitoring && CLUSTER=amd python3 setup.py

monitor-up: monitor-up-nvidia ## Alias for monitor-up-nvidia (default)

monitor-down: ## Stop Grafana
	@cd monitoring && docker compose down

monitor-clean: ## Wipe Grafana state and restart fresh
	$(MAKE) monitor-down
	docker volume rm monitoring_grafana-data 2>/dev/null || true

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

destroy: ## Tear down everything (Helm release + Terraform resources)
	helm uninstall crusoe-kserve-example 2>/dev/null || true
	cd terraform && terraform destroy
