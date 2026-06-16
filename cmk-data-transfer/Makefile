# cmk-data-transfer — operator entrypoints.
# All targets read config from .env (see .env.example). Override on the CLI:
#   make run TARGET_GBPS=11.6 NUM_NODES=4
PY ?= python3

.DEFAULT_GOAL := help

.PHONY: help sizing dry-run preflight run run-yes sweep collect clean clean-all

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

sizing: ## Print the BDP/target sizing plan (no cluster access)
	$(PY) -m orchestrator.sizing

dry-run: ## Render manifests + run preflight checks, launch nothing
	$(PY) -m orchestrator.run --dry-run

preflight: ## VAST write-ceiling test (fio, one pod per node) — safe, no egress
	$(PY) preflight/run_fio.py

fio-bench: ## Disk read+write benchmark: fio on every s2a node -> bench/results/
	$(PY) bench/fio/run_fio_bench.py --pvc $(FIO_PVC) --size $(FIO_SIZE) \
		--jobs $(FIO_JOBS) --iodepth $(FIO_IODEPTH) --runtime $(FIO_RUNTIME) \
		--direct $(FIO_DIRECT)

run: ## Full pipeline; PROMPTS before launching the large transfer
	$(PY) -m orchestrator.run

run-yes: ## Full pipeline, skip the launch confirmation (CAUTION: egress)
	$(PY) -m orchestrator.run --yes

sweep: ## Parameter sweep (bounded sample); set SAMPLE_PREFIX. CAUTION: egress
	$(PY) bench/sweep.py --yes --sample-prefix "$(SAMPLE_PREFIX)" \
		--transfers-grid "$(TRANSFERS_GRID)" --mts-grid "$(MTS_GRID)" \
		--pods-per-node-grid "$(PODS_PER_NODE_GRID)" --max-seconds "$(MAX_SECONDS)" --do-list

collect: ## Attach the throughput collector to a running fleet
	$(PY) bench/collect.py --namespace $(NAMESPACE)

clean: ## Delete worker + master + fio pods (keep PVC/Secret/data)
	-kubectl -n $(NAMESPACE) delete pod -l app=cmk-data-transfer-worker --ignore-not-found
	-kubectl -n $(NAMESPACE) delete pod -l app=cmk-data-transfer-fio --ignore-not-found
	-kubectl -n $(NAMESPACE) delete pod cmk-data-transfer-master --ignore-not-found

clean-all: clean ## Also delete the Secret (keeps the PVC and downloaded data)
	-kubectl -n $(NAMESPACE) delete secret cmk-data-transfer-oci --ignore-not-found
	@echo "PVC and downloaded data left intact. Delete the PVC manually if desired."

# --- defaults for sweep knobs (override on CLI) ---
NAMESPACE ?= default
FIO_PVC ?= cmk-data-transfer-fs
FIO_SIZE ?= 4G
FIO_JOBS ?= 16
FIO_IODEPTH ?= 32
FIO_RUNTIME ?= 30
FIO_DIRECT ?= 1
SAMPLE_PREFIX ?=
TRANSFERS_GRID ?= 16,32,48
MTS_GRID ?= 4,8
PODS_PER_NODE_GRID ?= 2,4,8
MAX_SECONDS ?= 120
