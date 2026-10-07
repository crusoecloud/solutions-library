[![Crusoe](./assets/CrusoeLogo_black.png)](https://www.crusoe.ai/)

# Crusoe Solutions Library

## Table of contents
* [Introduction](#introduction)
* [Disclaimer](#warning-disclaimer)
* [Prerequisites](#prerequisites)
* [Solutions](#solutions)
    * [Training](#training)
    * [Inference](#inference)
    * [Storage](#storage)
    * [Compute](#compute)
    * [Performance](#performance)
    * [Observability](#observability)
    * [Identity & Security](#identity--security)
    * [Networking](#networking)
* [Contributing](#contributing)

## Introduction

This repository is a curated collection of solutions designed to deploy and manage infrastructure and other applications on Crusoe Cloud. 

## :warning: **DISCLAIMER**

These solutions are a community resource and are not **officially supported, endorsed, or maintained by Crusoe**. While we make reasonable, best-effort attempts to maintain and update base images and dependencies, this repository is provided "AS IS" without warranties of any kind. You use this software entirely at your own risk.

## Prerequisites

These solutions are built for [Crusoe Cloud](https://crusoe.ai/), and will require you to install some (or all) of the following tools:

- [Terraform](https://www.terraform.io/) (and the [Terraform Provider for Crusoe](https://registry.terraform.io/providers/crusoecloud/crusoe/latest))
- [Crusoe CLI](https://docs.crusoecloud.com/quickstart/installing-the-cli/index.html)

Each solution README will also list its own specific prerequisites.

## Solutions

### Training

[TorchTitan pre-training benchmark as a PyTorchJob for Crusoe Managed Kubernetes](./torchtitan-llama3_1-kubernetes-pytorchjob)  

TorchTitan is a widely-used reference Pytorch program for benchmarking the pretraining of Llama 3.1 and other models. This implementation is designed to be run as a PyTorchJob on CMK.

[Crusoe Managed Fine-Tuning — end-to-end](./crusoe-managed-finetuning-example/)

A runnable end-to-end example that uploads a JSONL dataset, picks a base model, launches a fine-tuning job via the OpenAI-compatible Crusoe Intelligence Foundry API, polls to completion, lists checkpoints, and downloads the best adapter. Requires a Crusoe API key.

[AMD MI355X Playpen Workload for Crusoe Managed Kubernetes](./cmk-amd-rocm-playpen/)

Deploys a StatefulSet of pods on Crusoe AMD MI355X nodes using AMD's ROCm/RCCL workload image, with passwordless SSH and an external LoadBalancer front-end for easy access. Includes scripts to launch a multi-node distributed PyTorch job over RCCL/GPU Direct RDMA and a standalone multi-node RCCL benchmark, making it a quick sandbox for validating AMD GPU and NIC connectivity on a new cluster.

[JupyterHub with Crusoe Cloud Authentication](./jupyterhub-with-crusoe-auth-helmchart/)

A Helm chart that deploys JupyterHub on a CMK cluster behind a Crusoe LoadBalancer, with optional TLS termination, letting users sign in with their existing Crusoe Cloud access key/secret credentials instead of a separate identity system. Requires Crusoe FS/SSD storage classes and the Crusoe LoadBalancer chart to already be installed on the cluster.

### Inference

[LangChain × Crusoe AI](./langchain-crusoe/)

The `langchain-crusoe` package integrates Crusoe's [Managed Inference](https://www.crusoe.ai/cloud/managed-inference) service with [LangChain](https://www.langchain.com/), providing a `ChatCrusoe` class for drop-in access to models like Llama 3.3, DeepSeek V3/R1, Qwen3, Gemma 3, and Kimi-K2 through a standard LangChain interface.

[Serving HuggingFace Models on CMK with KServe](./crusoe-kserve-example/)

Deploy open-source LLMs from HuggingFace on Crusoe Managed Kubernetes (CMK) using [KServe](https://kserve.github.io/) and [vLLM](https://docs.vllm.ai/), from a single-GPU endpoint to disaggregated prefill-decode across heterogeneous GPU pools. Supports both NVIDIA and AMD GPU clusters.

Key capabilities:

- **NVIDIA GPU serving** — single-GPU, multi-node tensor parallelism, and disaggregated prefill-decode across A100/H100 node pools
- **AMD GPU serving** — single-node and multi-node serving on MI300X using ROCm-based vLLM; supports large MoE models like MiniMax-M2
- **Model deployment** — deploy any HuggingFace model with an OpenAI-compatible `/v1/chat/completions` endpoint; large models (70B+) use persistent storage backed by the Crusoe SSD CSI driver
- **One-command setup** — `make setup` (NVIDIA) or `make setup-amd` (AMD) provisions the CMK cluster, installs the GPU operator and KServe, and creates the model namespace end-to-end

See the [crusoe-kserve-example README](./crusoe-kserve-example/README.md) for full setup instructions and usage examples.

### Storage

[Cross-Region Object Storage to Shared Disk Data Transfer for Crusoe Managed Kubernetes](./cmk-data-transfer/)

Parallel-pulls a dataset from any S3-compatible object store (OCI, AWS S3, GCS, R2, B2, MinIO/Ceph) into a VAST-backed RWX shared disk on Crusoe Managed Kubernetes, using a master pod to shard the listing and many worker pods running `rclone copy` concurrently to saturate a high-latency network path. Includes sizing/preflight tooling (`make sizing`, `make preflight`) that derives concurrency from a bandwidth-delay-product model, so it's suited for large dataset ingestion across regions where a single-stream transfer would be RTT-limited.

[Cross-Region Shared Disk to Shared Disk Data Transfer](./cross-region-shared-disk-data-transfer/)

Terraform and Ansible solution that transfers data between two Crusoe shared disks in different locations, serving files from the source disk via nginx (zero-copy `sendfile` from NFS page cache) and pulling them in parallel on the destination Crusoe Managed Kubernetes cluster using many `aria2c` worker pods with multi-connection splits. Provisions the source VMs, destination CMK cluster/nodepool, firewall rules, and CSI-backed PVC end-to-end, and includes kernel/network tuning (BBR, jumbo frames, `nconnect=16`) for high-bandwidth-delay-product cross-region paths, with optional Grafana CMK for monitoring the transfer.

### Compute

[Crusoe Slurm Custom Image Generation](./slurm-custom-image/)

An Ansible playbook that installs Slurm binaries onto a VM (which must already have NVIDIA drivers and CUDA present) so the resulting disk can be captured as a Crusoe custom image. Use this to bake a reusable base image for standing up Slurm clusters on Crusoe Cloud.

[Slurm Accounting for Crusoe Managed Slurm](./crusoe-managed-slurm-accounting/)

A Helm chart that adds Slurm accounting (slurmdbd + MariaDB) on top of a Crusoe Managed Slurm cluster, which does not provision accounting by default. Deploys a block-storage-backed MariaDB instance and a Slinky `Accounting` (slurmdbd) resource wired into the existing managed cluster's `Controller`, so `sacct`/`sacctmgr` job history and usage tracking work out of the box. Includes a full walkthrough for setting up the underlying Managed Slurm cluster (compute node pools, users) and documents several upstream/image gotchas hit along the way.

### Performance

[InfiniBand Health Probe for Crusoe Managed Kubernetes](./ib-health-probe-cmk/)

A Kubernetes-native health check for InfiniBand fabrics that runs one pod per GPU worker node, performing per-HCA `ib_write_bw` loopback tests plus single- and multi-node NCCL all_reduce, and flags any HCA running below line rate. Use it before a long training run, or to investigate a suspected straggler node, on any SKU (H200, B200, etc.) without manual configuration.

[SKU-Tuned NCCL Tests for Crusoe Managed Kubernetes](./cmk-nccltests/)

A set of ready-to-apply Kubernetes MPIJob manifests that run the `all_reduce_perf` NCCL benchmark, pre-tuned for specific Crusoe GPU SKUs (B200, B300, GB200, H100, H200) with the correct topology file and CUDA/NCCL image per SKU. Use it to quickly validate InfiniBand fabric performance on a given CMK GPU nodepool without hand-configuring NCCL test manifests from scratch.

[VM Cluster Creation with Integrated NCCL Test and Kernel Health Check](./create-vms-and-run-nccl-test/)

A combined Terraform and Ansible solution that provisions a cluster of Crusoe Cloud GPU VMs and, as part of the same apply, runs an all-reduce NCCL test plus a kernel message check (`dmesg | grep NVRM`) across all hosts. Primarily used for sanity-testing a new cluster of hosts — surfacing Xid/NVRM errors and InfiniBand performance results directly in the Terraform output — before handing it off for production workloads.

[AMD MI355X Validation Suite for Crusoe Managed Kubernetes](./cmk-amd-mi355x/)

A reproducible acceptance bundle for AMD Instinct MI355X nodepools with Pensando Pollara 400 AI NICs on CMK. It covers per-node kernel/driver/firmware verification against the deployed Crusoe software bundle, per-rail RDMA bandwidth (host-memory and GPU-direct dma-buf), a 2-node RCCL all-reduce with the Crusoe + mlcommons tuning envelope, and per-GPU compute/straggler/XGMI/ECC health — with reference pass bars from Crusoe's internal dry-run.

[Fast InfiniBand Write Testing for Multiple MI355X Nodes](./ib-write-test-mi355x/)

Tests NIC bandwidth across multiple AMD MI355X nodes using `ib_write_bw` driven in parallel from a known-good master node, then summarizes which NICs passed or failed. Parallelization keeps each node's test to a couple of seconds, making it suitable for quickly sweeping a large nodepool.

### Observability

[Self-hosted Grafana on Crusoe Managed Kubernetes](./grafana-cmk/)

A team-dedicated Grafana deployment for Crusoe Managed Kubernetes / Managed Slurm clusters. Pulls GPU, DCGM, power, and InfiniBand metrics from the Crusoe Telemetry Relay endpoint and ships pre-built dashboards (cluster GPU overview, per-node GPU detail, Xid / ECC error tracking, GPU power, and InfiniBand fabric activity). Includes a zero-dependency two-node H100 burn-in benchmark to validate the dashboards end-to-end.

[Log aggregation with Fluent Bit, Loki, and a dashboard for Self-hosted Grafana](./cmk-fluentbit-loki-logging/)

Designed to be used with the Self-hosted Grafana solution above, or any other Grafana installed on CMK. Aggregates CMK pod logs into a single data source queryable by LogQL.

### Identity & Security

[Crusoe to Splunk HEC Log Forwarder](./crusoe-splunk-hec/README.md)

Crusoe Cloud provides a 90-day history of who did what in your cloud, when, where, and with what result - also called [Crusoe Audit Logs](https://docs.crusoecloud.com/identity-and-security/audit-logs/index.html). This solution provides a sample Python tool to fetch those logs and forward them to a Splunk HTTP Event Collector (HEC). 

### Networking

[Crusoe Site-to-Site VPN (AWS / GCP)](./site-to-site-vpn/)

A hardened, redundant route-based IPsec (IKEv2) VPN terminating on one or two Ubuntu VMs running strongSwan and FRR, with BGP dynamic routing and automatic tunnel failover, provisioned entirely by Terraform from a single params file. Pairs with AWS Site-to-Site VPN or GCP HA VPN; the GCP path and dual-VM HA mode are validated end to end.

[StrongSwan Site-to-Site VPN for Crusoe Cloud](./strongswan-ipsec/)

An Ansible-managed, encrypted IPsec site-to-site VPN between a Crusoe Cloud region and a remote site — another Crusoe region, or Azure/GCP/AWS — with VMs on both sides communicating via their real (non-NAT'd) IP addresses over a GRE-over-FOU overlay. You fill in an inventory and five values, and one command preflights connectivity, installs a VAES-capable kernel where it pays, and configures gateways and clients with defaults tuned for a managed cloud peer. Measured at 2.4 Gbps with one gateway per side rising to 20.7 Gbps with five, and 8.5 Gbps through a single VM holding two tunnels; also configures managed Kubernetes nodes via a DaemonSet.

## Contributing

Adding a new solution or improving an existing one? See [CONTRIBUTING.md](./CONTRIBUTING.md) for directory conventions, README requirements, and the automated checks that run on every PR.
