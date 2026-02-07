## Create a cluster of VMS and run NCCL tests and kernel message checks in a single terraform op ##
This is a terraform and ansible solution which creates a cluster of your chosen host type and runs kernel message checks and an all-reduce NCCL test as part of the cluster creation process.  
The main use case is for sanity-testing a cluster of hosts prior to production delivery.

### Instructions ###

On your workstation, edit terraform.tfvars to set the location, project ID, path to your public SSH key, vpc subnet ID and IB partition ID.  
Set a suitable image for your hosts (typically the latest published official image for that compute type), along with the node type and count.  
Set imex_support to true if you are using GB200 hosts.
Set node_name_prefix to something that ensures your host names will be unique in your project (hosts are named in the format \<node_name_prefix\>-\[0-\<node_count\>\])  

Then run the usual terraform commands:
```
terraform init
terraform plan
terraform apply --auto-approve
```
Test results are displayed as part of the terraform output.  
The kernel message check output is the output of sudo dmesg |grep NVRM on all cluster hosts and allows you to spot any Xid errors.

Example of successful output
<img width="1293" height="844" alt="image" src="https://github.com/user-attachments/assets/dc71ae69-df14-48e7-b4a4-3701ead222f3" />
