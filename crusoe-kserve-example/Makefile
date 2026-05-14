.PHONY: help setup setup-amd install-kserve patch-storage-initializer install-amd-gpu-operator deploy-basic deploy-large deploy-multi-node deploy-disaggregated deploy-amd-basic deploy-amd-large redeploy-amd-large deploy-amd-multi-node watch watch-metrics test chat bench bench-all bench-all-amd bench-amd monitor-up monitor-up-nvidia monitor-up-amd monitor-down monitor-clean destroy

SHELL := /bin/bash
NAMESPACE ?= kserve-test
HF_TOKEN       ?= $(shell grep '^hf_token'       terraform/terraform.tfvars     2>/dev/null | sed 's/.*= *"//;s/"//')
KSERVE_VERSION ?= v0.17.0

# AMD config — all values read from terraform-amd/terraform.tfvars
_AMD_TFVARS    := terraform-amd/terraform.tfvars
AMD_HF_TOKEN   ?= $(shell grep '^hf_token'        $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
DOCKER_USERNAME ?= $(shell grep '^docker_username' $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
DOCKER_EMAIL    ?= $(shell grep '^docker_email'    $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
DOCKER_PASSWORD  ?= $(shell grep '^docker_password' $(_AMD_TFVARS) 2>/dev/null | sed 's/.*= *"//;s/"//')
AMD_DRIVER_IMAGE ?= docker.io/$(DOCKER_USERNAME)/amd-gpu-driver

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup (cluster + KServe + namespace — all via Terraform)
# ---------------------------------------------------------------------------

setup: ## Provision cluster, install KServe, create namespace (terraform apply)
	cd terraform && \
	  cp -n terraform.tfvars.example terraform.tfvars 2>/dev/null || true && \
	  terraform init && \
	  terraform apply

setup-amd: ## Provision AMD cluster, install AMD GPU operator + KServe (configure terraform-amd/terraform.tfvars first)
	cd terraform-amd && \
	  cp -n terraform.tfvars.example terraform.tfvars 2>/dev/null || true && \
	  terraform init && \
	  terraform apply
	$(MAKE) install-amd-gpu-operator
	$(MAKE) install-kserve HF_TOKEN=$(AMD_HF_TOKEN)

install-amd-gpu-operator: ## Install cert-manager and AMD GPU operator (requires DOCKER_USERNAME, DOCKER_EMAIL, DOCKER_PASSWORD)
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
	  --set-string basic.args[4]="4096"

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

deploy-disaggregated: ## Deploy disaggregated prefill-decode (H100 + A100)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=true \
	  --set disaggregated.decode.args[0]="--tensor-parallel-size" \
	  --set-string disaggregated.decode.args[1]="8" \
	  --set disaggregated.decode.args[2]="--enforce-eager" \
	  --set disaggregated.decode.args[3]="--gpu-memory-utilization" \
	  --set disaggregated.decode.args[4]="0.90" \
	  --set disaggregated.prefill.args[0]="--tensor-parallel-size" \
	  --set-string disaggregated.prefill.args[1]="8" \
	  --set disaggregated.prefill.args[2]="--enable-chunked-prefill" \
	  --set disaggregated.prefill.args[3]="--max-num-batched-tokens" \
	  --set-string disaggregated.prefill.args[4]="8192" \
	  --set disaggregated.prefill.args[5]="--gpu-memory-utilization" \
	  --set disaggregated.prefill.args[6]="0.90"

# ---------------------------------------------------------------------------
# Test & Benchmark
# ---------------------------------------------------------------------------

PORT  ?= 8080
MODEL ?=

chat: ## Interactive streaming chat with the deployed model (MODEL=<name> to override auto-detect)
	@SVC=$$(kubectl get svc -n $(NAMESPACE) -o name | grep workload | head -1) && \
	echo "Port-forwarding $$SVC to localhost:$(PORT)..." && \
	kubectl port-forward -n $(NAMESPACE) $$SVC $(PORT):8000 >/dev/null 2>/dev/null & \
	PF_PID=$$! && \
	sleep 2 && \
	python3 scripts/chat.py \
	  --url http://localhost:$(PORT) \
	  $$([ -n "$(MODEL)" ] && echo "--model $(MODEL)" || true) || true; \
	kill $$PF_PID 2>/dev/null || true

test: ## Port-forward and send a test chat request
	@echo "Finding workload service..."
	@SVC=$$(kubectl get svc -n $(NAMESPACE) -o name | grep workload | head -1) && \
	  echo "Port-forwarding $$SVC to localhost:$(PORT)..." && \
	  kubectl port-forward -n $(NAMESPACE) $$SVC $(PORT):8000 &
	@sleep 3
	@echo "Sending test request..."
	@curl -s -H "Content-Type: application/json" \
	  http://localhost:$(PORT)/v1/chat/completions \
	  -d @chat-test.json | jq .
	@kill %1 2>/dev/null || true

BENCH_NUM_PROMPTS ?= 200
BENCH_RATE        ?= 50
BENCH_INPUT_LEN   ?= 512
BENCH_OUTPUT_LEN  ?= 150

_bench_run = kubectl exec -n $(NAMESPACE) deploy/$$DEPLOY -c main -- \
	  vllm bench serve \
	    --model /mnt/models \
	    --served-model-name qwen \
	    --base-url http://localhost:8000 \
	    --backend openai-chat \
	    --endpoint /v1/chat/completions \
	    --dataset-name random \
	    --random-output-len $(BENCH_OUTPUT_LEN)

_bench_run_amd = kubectl exec -n $(NAMESPACE) deploy/$$DEPLOY -c main -- \
	  vllm bench serve \
	    --model /mnt/models \
	    --served-model-name minimax \
	    --base-url http://localhost:8000 \
	    --backend openai-chat \
	    --endpoint /v1/chat/completions \
	    --dataset-name random \
	    --random-output-len $(BENCH_OUTPUT_LEN)

bench: ## Run a single benchmark profile (configure with BENCH_RATE, BENCH_INPUT_LEN, BENCH_NUM_PROMPTS)
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||') && \
	echo "Running vLLM benchmark on $$DEPLOY..." && \
	$(call _bench_run) \
	    --random-input-len $(BENCH_INPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) \
	    --request-rate $(BENCH_RATE)

bench-amd: ## Run AMD benchmark profile (same params as bench — configure with BENCH_RATE, BENCH_INPUT_LEN, BENCH_NUM_PROMPTS)
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||') && \
	echo "Running vLLM benchmark on $$DEPLOY (AMD)..." && \
	$(call _bench_run_amd) \
	    --random-input-len $(BENCH_INPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) \
	    --request-rate $(BENCH_RATE)

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
