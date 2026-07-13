#!/bin/bash

# install Crusoe Load Balancer helm chart if not already installed on cluster
#

# Create the configmap containing the startup scrupt that runs in each rocm pod
kubectl create configmap rocm-pod-setup --from-file=pod-setup.sh

# Create the Shared Disk storage class - this is used for the /home persistent volume shared by all the rocm pods
kubectl apply -f https://raw.githubusercontent.com/crusoecloud/crusoe-csi-driver-helm-charts/refs/heads/release/examples/sharedfs/sc_sharedfs.yaml

# Apply the worload yaml to create PVC, SSHD configmap, and the workload pods
kubectl apply -f rocm-gpu-workload.yaml

# Wait for rocm-workload-0 to be Running and Ready before copying files
echo "==> Waiting for rocm-workload-0 to be Running and Ready..."
kubectl wait pod/rocm-workload-0 \
  --for=condition=Ready \
  --timeout=600s

echo "==> Copying train.py to rocm-workload-0:/home/clouduser/..."
kubectl cp train.py rocm-workload-0:/home/clouduser/train.py
