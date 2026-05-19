[![Crusoe](./assets/CrusoeLogo_black.png)](https://www.crusoe.ai/)

# Crusoe Solutions Library

## Table of contents
* [Introduction](#introduction)
* [Prerequisites](#prerequisites)
* [Solutions](#solutions)

## Introduction

This repository is a curated collection of solutions designed to deploy and manage infrastructure and other applications on Crusoe Cloud. 

## Prerequisites

These solutions are built for [Crusoe Cloud](https://crusoe.ai/), and will require you to install some (or all) of the following tools:

- [Terraform](https://www.terraform.io/) (and the [Terraform Provider for Crusoe](https://registry.terraform.io/providers/crusoecloud/crusoe/latest))
- [Crusoe CLI](https://docs.crusoecloud.com/quickstart/installing-the-cli/index.html)

Each solution README will also list its own specific prerequisites.

## Solutions

### Training

[TorchTitan pre-training benchmark as a PyTorchJob for Crusoe Managed Kubernetes](./torchtitan-llama3_1_8B-kubernetes-pytorchjob)  

TorchTitan is a widely-used reference Pytorch program for benchmarking the pretraining of Llama 3.1 and other models. This implementation is designed to be run as a PyTorchJob on CMK.

### Inference

[LangChain × Crusoe AI](./langchain-crusoe/)

[![PyPI version](https://badge.fury.io/py/langchain-crusoe.svg)](https://pypi.org/project/langchain-crusoe/)

The `langchain-crusoe` package integrates Crusoe's [Managed Inference](https://www.crusoe.ai/cloud/managed-inference) service with the [LangChain](https://www.langchain.com/) ecosystem. It provides a `ChatCrusoe` class that wraps Crusoe's OpenAI-compatible API, giving you access to leading open-source models — including Llama 3.3, DeepSeek V3/R1, Qwen3, Gemma 3, and Kimi-K2 — through a standard LangChain interface.

Key capabilities:

- **Drop-in LangChain integration** via `BaseChatOpenAI` — streaming, async, tool calling, and structured output work out of the box
- **LangSmith tracing** with `ls_provider="crusoe"` for built-in observability
- **Project attribution** via `CRUSOE_PROJECT_ID` header for multi-tenant usage tracking
- **Flexible configuration** — API key, base URL, and project ID all configurable via environment variables

```bash
pip install langchain-crusoe
```

```python
from langchain_crusoe import ChatCrusoe

llm = ChatCrusoe(model="meta-llama/Llama-3.3-70B-Instruct")
response = llm.invoke("Explain MemoryAlloy inference technology in one paragraph.")
```

See the [langchain-crusoe README](./langchain-crusoe/README.md) for full setup instructions and usage examples.

[Serving HuggingFace Models on CMK with KServe](./crusoe-kserve-example/)

Deploy open-source LLMs from HuggingFace on Crusoe Managed Kubernetes (CMK) using [KServe](https://kserve.github.io/) and [vLLM](https://docs.vllm.ai/), from a single-GPU endpoint to disaggregated prefill-decode across heterogeneous GPU pools. Supports both NVIDIA and AMD GPU clusters.

Key capabilities:

- **NVIDIA GPU serving** — single-GPU, multi-node tensor parallelism, and disaggregated prefill-decode across A100/H100 node pools
- **AMD GPU serving** — single-node and multi-node serving on MI300X using ROCm-based vLLM; supports large MoE models like MiniMax-M2
- **Model deployment** — deploy any HuggingFace model with an OpenAI-compatible `/v1/chat/completions` endpoint; large models (70B+) use persistent storage backed by the Crusoe SSD CSI driver
- **One-command setup** — `make setup` (NVIDIA) or `make setup-amd` (AMD) provisions the CMK cluster, installs the GPU operator and KServe, and creates the model namespace end-to-end

See the [crusoe-kserve-example README](./crusoe-kserve-example/README.md) for full setup instructions and usage examples.

### Storage

[Shared Volumes NFS Setup](./shared-volumes-driver-setup/)

This solution will install all the necessary drivers, packages and configurations to enable your Crusoe Cloud VMs to mount Crusoe Shared Volumes via NFS.

[OCI Registry Cache for Google Artifact Registry](./registry-cache-gar/)

This is a working solution of an OCI Image registry, on Kubernetes, that acts as a cache for an upstream [Google Artifact Registry](https://docs.cloud.google.com/artifact-registry/docs).

### Performance

[Multi-VM NCCL Test](./nccl-allreduce-test-vms/)

Crusoe Cloud GPU VMs are equipped with high-performance NVIDIA Mellanox InfiniBand (IB) networking. This solution will set up your VMs with necessary configurations to use the pre-loaded NCCL all_reduce test on your VMs and test InfiniBand networking performance. 

### Observability

[Crusoe Managed Kubernetes logs to Google Cloud Logging](./crusoe-managed-kubernetes-logs-to-gcp/)

For your applications running on Crusoe Managed Kubernetes cluster, you can collect, filter and ship logs using [Fluent Bit](https://fluentbit.io/) to send to a centralized location. This solution provides a set of Kubernetes manifest files needed to configure those logs to be sent to Google Cloud Logging using Fluent Bit.

[Self-hosted Grafana on Crusoe Managed Kubernetes](./grafana-cmk/)

A team-dedicated Grafana deployment for Crusoe Managed Kubernetes / Managed Slurm clusters. Pulls GPU, DCGM, power, and InfiniBand metrics from the Crusoe Telemetry Relay endpoint and ships pre-built dashboards (cluster GPU overview, per-node GPU detail, Xid / ECC error tracking, GPU power, and InfiniBand fabric activity). Includes a zero-dependency two-node H100 burn-in benchmark to validate the dashboards end-to-end.

### Identity & Security

[Crusoe to Splunk HEC Log Forwarder](./crusoe-splunk-hec/README.md)

Crusoe Cloud provides a 90-day history of who did what in your cloud, when, where, and with what result - also called [Crusoe Audit Logs](https://docs.crusoecloud.com/identity-and-security/audit-logs/index.html). This solution provides a sample Python tool to fetch those logs and forward them to a Splunk HTTP Event Collector (HEC). 

### Networking

[/etc/hosts Pin](./etchosts-pin/README.md)

A daemon that resolves a hostname on a fixed interval and keeps the resulting A/AAAA records in `/etc/hosts`. Works around undesirable TTL cache values from intermediate DNS resolvers
