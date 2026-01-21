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

### Inference

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

### Identity & Security

[Crusoe Bastion Host](./crusoe-bastion-host/)

A production-ready, click-to-deploy bastion host solution for secure access to private infrastructure on Crusoe Cloud. This solution provides a hardened jump server with SSH key-based authentication, session logging, automatic security updates, fail2ban intrusion prevention, and comprehensive management tools. Includes an interactive deployment script for easy setup and supports high availability configurations for production environments.

[Crusoe to Splunk HEC Log Forwarder](./crusoe-splunk-hec/README.md)

Crusoe Cloud provides a 90-day history of who did what in your cloud, when, where, and with what result - also called [Crusoe Audit Logs](https://docs.crusoecloud.com/identity-and-security/audit-logs/index.html). This solution provides a sample Python tool to fetch those logs and forward them to a Splunk HTTP Event Collector (HEC). 