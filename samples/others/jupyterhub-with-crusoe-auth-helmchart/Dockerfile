# Custom JupyterHub singleuser image with SDKs for submitting
# RayJobs, RayClusters, and PyTorchJobs from inside a notebook.
#
# Build:
#   docker build -t <registry>/crusoe-notebook:<tag> .
#
# Reference in values.yaml:
#   jupyterhub:
#     singleuser:
#       image:
#         name: <registry>/crusoe-notebook
#         tag: <tag>

FROM quay.io/jupyter/scipy-notebook:latest

# Install as root so we can pip-install system-wide packages
USER root

RUN pip install --no-cache-dir \
    # Kubernetes Python client – used directly or by the SDKs below
    kubernetes \
    # KubeRay SDK for RayJob / RayCluster submission and status polling
    kuberay-sdk \
    # Kubeflow Training Operator SDK for PyTorchJob submission
    kubeflow-training

# Drop back to the default non-root notebook user
USER ${NB_UID}
