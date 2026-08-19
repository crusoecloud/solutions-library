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

[Shared Volumes NFS Setup](./shared-volumes-driver-setup/)

This solution will install all the necessary drivers, packages and configurations to enable your Crusoe Cloud VMs to mount Crusoe Shared Volumes via NFS.

[OCI Registry Cache for Google Artifact Registry](./registry-cache-gar/)

This is a working solution of an OCI Image registry, on Kubernetes, that acts as a cache for an upstream [Google Artifact Registry](https://docs.cloud.google.com/artifact-registry/docs).

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

[Multi-VM NCCL Test](./nccl-allreduce-test-vms/)

Crusoe Cloud GPU VMs are equipped with high-performance NVIDIA Mellanox InfiniBand (IB) networking. This solution will set up your VMs with necessary configurations to use the pre-loaded NCCL all_reduce test on your VMs and test InfiniBand networking performance. 

[InfiniBand Health Probe for Crusoe Managed Kubernetes](./ib-health-probe-cmk/)

A Kubernetes-native health check for InfiniBand fabrics that runs one pod per GPU worker node, performing per-HCA `ib_write_bw` loopback tests plus single- and multi-node NCCL all_reduce, and flags any HCA running below line rate. Use it before a long training run, or to investigate a suspected straggler node, on any SKU (H200, B200, etc.) without manual configuration.

[NCCL Test on B300 Nodepool via Kubeflow MPIJob for Crusoe Managed Kubernetes](./b300-nccltest-cmk-mpijob/)

An end-to-end guide and helper script for running an `all_reduce_perf` NCCL benchmark across multiple B300 GPU nodes on Crusoe Managed Kubernetes using the Kubeflow Training Operator's MPIJob API. It sweeps message sizes from 2 GB to 32 GB to characterize InfiniBand bandwidth (`busbw`) and verify correctness, useful for validating a B300 nodepool's fabric health before production use.

[SKU-Tuned NCCL Tests for Crusoe Managed Kubernetes](./cmk-nccltests/)

A set of ready-to-apply Kubernetes MPIJob manifests that run the `all_reduce_perf` NCCL benchmark, pre-tuned for specific Crusoe GPU SKUs (B200, GB200, H100, H200) with the correct topology file and CUDA/NCCL image per SKU. Use it to quickly validate InfiniBand fabric performance on a given CMK GPU nodepool without hand-configuring NCCL test manifests from scratch.

[VM Cluster Creation with Integrated NCCL Test and Kernel Health Check](./create-vms-and-run-nccl-test/)

A combined Terraform and Ansible solution that provisions a cluster of Crusoe Cloud GPU VMs and, as part of the same apply, runs an all-reduce NCCL test plus a kernel message check (`dmesg | grep NVRM`) across all hosts. Primarily used for sanity-testing a new cluster of hosts — surfacing Xid/NVRM errors and InfiniBand performance results directly in the Terraform output — before handing it off for production workloads.

[Disable Hyperthreading on Crusoe Managed Kubernetes Nodes](./cmk-disable-node-hyperthreading/)

A privileged DaemonSet that disables SMT/hyperthreading on Ubuntu-based CMK worker nodes by writing to the kernel's SMT control file and restarting kubelet, re-applying itself automatically after node reboots since it does not persist the change via grub. Intended only for specialized workloads that require hyperthreading off, since it halves the node's visible logical CPU count and requires resizing resource requests accordingly.

### Observability

[Crusoe Managed Kubernetes logs to Google Cloud Logging](./crusoe-managed-kubernetes-logs-to-gcp/)

For your applications running on Crusoe Managed Kubernetes cluster, you can collect, filter and ship logs using [Fluent Bit](https://fluentbit.io/) to send to a centralized location. This solution provides a set of Kubernetes manifest files needed to configure those logs to be sent to Google Cloud Logging using Fluent Bit.

[Self-hosted Grafana on Crusoe Managed Kubernetes](./grafana-cmk/)

A team-dedicated Grafana deployment for Crusoe Managed Kubernetes / Managed Slurm clusters. Pulls GPU, DCGM, power, and InfiniBand metrics from the Crusoe Telemetry Relay endpoint and ships pre-built dashboards (cluster GPU overview, per-node GPU detail, Xid / ECC error tracking, GPU power, and InfiniBand fabric activity). Includes a zero-dependency two-node H100 burn-in benchmark to validate the dashboards end-to-end.

[Crusoe Watch Agent Ansible Deployment](./crusoe-watch-agent/)

An Ansible playbook that installs and manages the Crusoe Watch Agent (metrics/monitoring exporter) across a fleet of VMs defined in an inventory file, using a Crusoe monitoring token. Supports single-VM or fleet-wide rollout, dry runs, and includes maintenance tasks for restarting, stopping, and checking the agent's status.

### Identity & Security

[Crusoe Bastion Host](./crusoe-bastion-host/)

A production-ready, click-to-deploy bastion host solution for secure access to private infrastructure on Crusoe Cloud. This solution provides a hardened jump server with SSH key-based authentication, session logging, automatic security updates, fail2ban intrusion prevention, and comprehensive management tools. Includes an interactive deployment script for easy setup and supports high availability configurations for production environments.

[Crusoe to Splunk HEC Log Forwarder](./crusoe-splunk-hec/README.md)

Crusoe Cloud provides a 90-day history of who did what in your cloud, when, where, and with what result - also called [Crusoe Audit Logs](https://docs.crusoecloud.com/identity-and-security/audit-logs/index.html). This solution provides a sample Python tool to fetch those logs and forward them to a Splunk HTTP Event Collector (HEC). 

[CMK as an OIDC Provider for AWS IRSA](./cmk-as-oidc-provider/)

Lets pods on Crusoe Managed Kubernetes assume AWS IAM roles directly via IRSA, using the CMK cluster's OIDC issuer as the trusted identity provider, so workloads get short-lived, per-ServiceAccount AWS credentials instead of static access keys in a Secret. Includes a sample pod manifest that writes and lists an S3 object to confirm the ServiceAccount can assume its AWS role end-to-end.

### Networking

[/etc/hosts Pin](./etchosts-pin/README.md)

A daemon that resolves a hostname on a fixed interval and keeps the resulting A/AAAA records in `/etc/hosts`. Works around undesirable TTL cache values from intermediate DNS resolvers

[IPSec Tunnel for Crusoe Managed Kubernetes](./ipsec-tunnel-cmk/)

A Helm chart that establishes a highly-available IPSec VPN between a remote site and a CMK cluster using paired StrongSwan deployments with BGP-based dynamic route sharing, so that pod, node, and service IPs on both sides are mutually reachable. Includes an example Terraform module for standing up a matching Google Cloud VPN endpoint.

[StrongSwan Site-to-Site VPN for Crusoe Cloud](./strongswan-ipsec/)

An Ansible-managed, encrypted IPsec site-to-site VPN between a Crusoe Cloud region and a remote site — another Crusoe region, or Azure/GCP/AWS — with VMs on both sides communicating via their real (non-NAT'd) IP addresses. Uses GRE-over-FOU on the Crusoe side to work around SDN port-security source-IP checks, while the remote cloud side relies on native IP-forwarding; supports adding VMs incrementally via inventory changes.

## Contributing

Adding a new solution or improving an existing one? See [CONTRIBUTING.md](./CONTRIBUTING.md) for directory conventions, README requirements, and the automated checks that run on every PR.