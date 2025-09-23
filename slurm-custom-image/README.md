# Crusoe Slurm Image Generation Ansible

This ansible playbook and role will help you generate a custom image with Slurm binaries installed

## Installation

1. Install ansible nvidia.enroot
```
ansible-galaxy role install nvidia.enroot
```
2. Clone the repo and switch to the directory
```
git clone https://github.com/crusoecloud/solutions-library.git
cd solutions-library
```

3. Create a VM using your desired base image
4. Once the public IP is assigned, modify the `inventory/inventory.yml` and add the public IP
5. Run the `slurm.yml` playbook
```
ansible-playbook -i inventory/inventory.yml slurm.yml
```
6. Once ansible runs, stop the VM
7. Create a custom image using the stopped VM as the source
