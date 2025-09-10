[![Crusoe](./assets/CrusoeLogo_black.png)](https://www.crusoe.ai/)

# Crusoe Solutions Library

## Table of contents
* [Introduction](#introduction)
* [Solutions](#solutions)
* [Prerequisites](#prerequisites)

## Introduction

This repository is a curated collection of solutions designed to deploy and manage infrastructure and other applications on Crusoe Cloud. Our solutions library has the tools and resources to help you deploy complex machine learning models, manage scalable infrastructure and ensure that your AI-powered applications run smoothly.

## Solutions

### Training

### Inferences

### Identity & Security

[Crusoe to Splunk HEC Log Forwarder](./crusoe-splunk-hec/README.md)

Crusoe Cloud provides a 90-day history of  who did what in your cloud, when, where, and with what result - also called [Crusoe Audit Logs](https://docs.crusoecloud.com/identity-and-security/audit-logs/index.html). This solution provides a sample Python tool to fetch those logs and forward them to a Splunk HTTP Event Collector (HEC). 

## Prerequisites

These solutions are built for Crusoe Cloud(https://crusoe.ai/), and will require you to install some (or all) of the following tools:

- [Terraform](https://www.terraform.io/) (and the [Terraform Provider for Crusoe](https://registry.terraform.io/providers/crusoecloud/crusoe/latest))
- [Crusoe CLI](https://docs.crusoecloud.com/quickstart/installing-the-cli/index.html)

Each solution README will also list its own specific prerequisites.