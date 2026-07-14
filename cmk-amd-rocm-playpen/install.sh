#!/bin/bash

# Create the configmap containing the startup scrupt that runs in each rocm pod
kubectl delete configmap rocm-pod-setup
kubectl create configmap rocm-pod-setup --from-file=pod-setup.sh

# Create the Shared Disk storage class - this is used for the /home persistent volume shared by all the rocm pods
kubectl apply -f https://raw.githubusercontent.com/crusoecloud/crusoe-csi-driver-helm-charts/refs/heads/release/examples/sharedfs/sc_sharedfs.yaml

# Apply the workload yaml to create PVC, SSHD configmap, and the workload pods
kubectl apply -f rocm-gpu-workload.yaml

# Wait for rocm-workload-0 to be Running and Ready before copying files
echo "==> Waiting for rocm-workload-0 to be Running and Ready..."
kubectl wait pod/rocm-workload-0 \
  --for=condition=Ready \
  --timeout=600s

#allow another 20 sec for pod-setup.sh to finish its job
sleep 20

echo "==> Copying example pytorch files to rocm-workload-0:/home/clouduser/..."
kubectl cp train.py rocm-workload-0:/home/clouduser/train.py
kubectl cp train-distributed.py rocm-workload-0:/home/clouduser/train-distributed.py
kubectl cp launch-distributed.sh rocm-workload-0:/home/clouduser/launch-distributed.sh
kubectl cp hostfile rocm-workload-0:/home/clouduser/hostfile

echo "Fixing permissions"
# fix up the ownership of the copied-in files
kubectl exec rocm-workload-0 -- chown clouduser:clouduser /home/clouduser/launch-distributed.sh /home/clouduser/hostfile /home/clouduser/train-distributed.py /home/clouduser/train.py
kubectl exec rocm-workload-0 -- chmod a+x /home/clouduser/launch-distributed.sh


echo "Installing uv"
#install uv as clouduser, only needs to be done in the first pod
EXT_IP=$(kubectl get svc rocm-workload-0-ssh -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Got ext ip of $EXT_IP"
ssh clouduser@$EXT_IP "curl -LsSf https://astral.sh/uv/install.sh | sh"

ssh clouduser@$EXT_IP "~/.local/bin/uv venv && source .venv/bin/activate && ~/.local/bin/uv pip install \"torch==2.13.0+rocm7.2\" \"torchvision==0.28.0+rocm7.2\" \"torchaudio==2.11.0+rocm7.2\" \"triton-rocm==3.7.1\" --index-url https://download-r2.pytorch.org/whl/rocm7.2"

ssh clouduser@$EXT_IP "./launch-distributed.sh"

echo "Installation is complete and example distributed workload was run across 2 pods. Run ssh clouduser@$EXT_IP to get into the pod and start using the AMD MI355X GPUs"
