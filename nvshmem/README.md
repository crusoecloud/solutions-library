To deploy this, populate inventory/inventory.yml with the public IP addresses of the Crusoe compute hosts you want to install nvshmem on, then run:
```
ansible playbook -i inventory/inventory.yml nvshmem.yml
```
