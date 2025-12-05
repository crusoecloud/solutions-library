# Multi-VM NCCL all_reduce Test
This ansible playbook will help you set up your Crusoe VMs to run a multi-node NCCL all_reduce test.

## Prerequisites

1. **Crusoe CLI** configured with the project where your VMs are provisioned.
2. **Crusoe GPU VMs** already provisioned in your Crusoe Cloud account, same GPU node type (i.e. NVIDIA H200) on the same InfiniBand Partition. They all must have the same SSH key, with the key located locally under `~/.ssh`.
3. **Ansible** and **jq** installed locally.

## Installation

1. Populate both the `hostfile` and `ips.yaml`. `hostfile` will have a column list of all of your VM's Private IPs, and `ips.yaml` will have a column list of all of your VM's Public IPs. You can extract them from Crusoe CLI.

    For example, to get the list of Private IPs, you can list and filter using your GPU type (i.e. H100):

    ```crusoe compute vms list --project-id <your crusoe cloud project id> -f json | jq -r '.[] | select(.type | contains("h100")) | .network_interfaces[0].ips[0].private_ipv4.address'```

    Similarly for Public IPs:

    ```crusoe compute vms list --project-id <your crusoe cloud project id> -f json | jq -r '.[] | select(.type | contains("h100")) | .network_interfaces[0].ips[0].public_ipv4.address'```

2. Execute the Ansible Playbook:
```
ansible-playbook -i ips.yaml ansible.yaml
```

3. Ansible will copy over all the SSH keys so that you are able to SSH from one node to another, and also remotely copy the list of hostnames (`hostname` file) and the actual all_reduce test script file.

4. SSH into one of the nodes, and then run the command  `./nccl.sh`. It will run a cross-node NCCL all_reduce test using mpirun.
