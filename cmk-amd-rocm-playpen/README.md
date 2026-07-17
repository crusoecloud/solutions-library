# Example CMK 'playpen' workload for Crusoe AMD MI355X nodes

A stateful set of pods based on AMD's `rocm/roce-workload:ubuntu24_rocm-7.0.2_rccl-7.0.2_anp-v1.2.0_ainic-1.117.1-a-63` image with a front-end SSH service on an External LoadBalancer. The pods have MPI installed and passwordless SSH configured so that MPI jobs can be easily run by the built-in clouduser account. `launch-distributed.sh` starts a simple distributed pytorch job using RCCL and GPU Direct RDMA. `launch-rccl.sh` runs a multi-node RCCL test. The scripts are configured for a 2-node (2-pod) cluster - edit them to match the size of your cluster.

**Prerequisites:**    
1 - A working CMK cluster with at least 2 AMD MI355X nodes in Ready state, CSI drivers installed, and Load Balancer Helm chart from https://github.com/crusoecloud/crusoe-load-balancer-controller-helm-charts. 

2 - Firewall rules:
  Under Networking -> Firewall Rules, create a rule that allow ingress to all TCP ports in the range 30000-39999 (so that nodeports use by the K8S ingress service work) - eiher from any source IP address or from a restricted range of public IP addresses (if you know the public IP that your ingress connections will come from)
  Create an Ingress rule that allows connections to TCP port 29500 from within the cluster itself (i.e 'Source' and 'Destination' both set to the cluster's own subnet) - this allows the PyTorch example to work.

## Quick start

From your local copy of this directory, ensure that your current Kubernetes context points at your target cluster and that its AMD MD355X nodepool is Ready.
Run `install.sh` to create the pods, copy in the local versions of the training and rccl test scripts, and run the scripts.

---

## Using the workload pods

### To SSH into a pod

Get the external IP for a pod:

```bash
kubectl get svc rocm-workload-0-ssh rocm-workload-1-ssh
```

Then connect as `clouduser`:

```bash
ssh clouduser@<EXTERNAL-IP>

#From inside a pod
./launch-rccl.sh # to run the rccl test
./launch-distributed.sh # to run the distributed PyTorch example
```
### To Verify GPU and NIC visibility

```bash
amd-smi
rocm-smi
ip a
```
You should be able to ping the ipv6 addresses of the Pollara interfaces (such as enP3p0s9) between pods.  
To confirm that all 8 AMD GPUs in the pod are visible to PyTorch:

```bash
python -c "import torch; print('Version:', torch.__version__); print('HIP:', torch.version.hip); print('GPUs:', torch.cuda.device_count())"
```
