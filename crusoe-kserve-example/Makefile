.PHONY: help setup deploy-basic deploy-70b deploy-multi-node deploy-disaggregated test bench destroy

SHELL := /bin/bash
NAMESPACE ?= kserve-test
HF_TOKEN ?= $(shell grep '^hf_token' terraform/terraform.tfvars 2>/dev/null | sed 's/.*= *"//;s/"//')

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

# ---------------------------------------------------------------------------
# Deploy (Helm)
# ---------------------------------------------------------------------------

deploy-basic: ## Deploy single-GPU LLM (Qwen2.5-0.5B on 1x A100)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=true \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=false

deploy-70b: ## Deploy Qwen2.5-72B on 8x A100 (single node, TP=8)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=true \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=false \
	  --set modelStorage.enabled=true \
	  --set modelStorage.size=250Gi \
	  --set basic.model.uri=hf://Qwen/Qwen2.5-72B-Instruct \
	  --set basic.model.name=qwen \
	  --set basic.args[0]="--gpu-memory-utilization" \
	  --set basic.args[1]="0.95" \
	  --set basic.args[2]="--tensor-parallel-size" \
	  --set-string basic.args[3]="8" \
	  --set basic.args[4]="--enable-chunked-prefill" \
	  --set basic.args[5]="--max-num-batched-tokens" \
	  --set-string basic.args[6]="8192" \
	  --set basic.resources.limits.gpu="8" \
	  --set basic.resources.limits.cpu="64" \
	  --set basic.resources.limits.memory=512Gi \
	  --set basic.resources.requests.gpu="8" \
	  --set basic.resources.requests.cpu="32" \
	  --set basic.resources.requests.memory=256Gi

deploy-multi-node: ## Deploy multi-node LLM (Qwen2.5-72B on 2x8 A100)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set multiNode.enabled=true \
	  --set disaggregated.enabled=false

deploy-disaggregated: ## Deploy disaggregated prefill-decode (H100 + A100)
	helm upgrade --install crusoe-kserve-example ./helm/crusoe-kserve-example \
	  --set hfToken=$(HF_TOKEN) \
	  --set basic.enabled=false \
	  --set multiNode.enabled=false \
	  --set disaggregated.enabled=true

# ---------------------------------------------------------------------------
# Test & Benchmark
# ---------------------------------------------------------------------------

PORT ?= 8080

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
BENCH_RATE ?= 50
BENCH_INPUT_LEN ?= 512
BENCH_OUTPUT_LEN ?= 150

bench: ## Run vLLM benchmark from inside the serving pod
	@DEPLOY=$$(kubectl get deploy -n $(NAMESPACE) -o name | grep -v router | head -1 | sed 's|deployment.apps/||') && \
	echo "Running vLLM benchmark on $$DEPLOY..." && \
	kubectl exec -n $(NAMESPACE) deploy/$$DEPLOY -c main -- \
	  vllm bench serve \
	    --model /mnt/models \
	    --served-model-name qwen \
	    --base-url http://localhost:8000 \
	    --backend openai-chat \
	    --endpoint /v1/chat/completions \
	    --dataset-name random \
	    --random-input-len $(BENCH_INPUT_LEN) \
	    --random-output-len $(BENCH_OUTPUT_LEN) \
	    --num-prompts $(BENCH_NUM_PROMPTS) \
	    --request-rate $(BENCH_RATE)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

destroy: ## Tear down everything (Helm release + Terraform resources)
	helm uninstall crusoe-kserve-example 2>/dev/null || true
	cd terraform && terraform destroy
