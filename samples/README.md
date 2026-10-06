# Samples

Reference implementations and developer examples for training, inference and other workloads on Crusoe.

Solutions are grouped into `training/`, `inference/` and `others/`.

| Solution | Description |
|---|---|
| [crusoe-managed-finetuning-example](./training/crusoe-managed-finetuning-example/) | Managed fine-tuning end to end |
| [torchtitan-llama3_1-kubernetes-pytorchjob](./training/torchtitan-llama3_1-kubernetes-pytorchjob/) | TorchTitan Llama 3.1 PyTorchJob benchmark |
| [crusoe-kserve-example](./inference/crusoe-kserve-example/) | Serve Hugging Face models with KServe and vLLM |
| [cmk-amd-rocm-playpen](./others/cmk-amd-rocm-playpen/) | AMD ROCm playpen on CMK |
| [create-vms-and-run-nccl-test](./others/create-vms-and-run-nccl-test/) | Provision VMs and run an NCCL test with Terraform and Ansible |
| [jupyterhub-with-crusoe-auth-helmchart](./others/jupyterhub-with-crusoe-auth-helmchart/) | JupyterHub with Crusoe authentication |
| [langchain-crusoe](./others/langchain-crusoe/) | LangChain integration for Crusoe Managed Inference |
