# Crusoe Shared Volumes over NFS Driver Installation

This ansible playbook and role will help you install shared volumes over NFS driver across all the machines defined in your inventory

## Installation

1. Clone the repo and switch to the directory
```
git clone https://github.com/crusoecloud/solutions-library.git
cd solutions-library/shared-volumes-driver-setup
```
2. Identify the list of VMs you would like to setup with this driver.
3. Modify the `inventory/inventory.yml` and add the public IPs to this file in the following format
```
216.x.x.x
216.y.y.y
216.z.z.z
```
4. Run the `setup.yml` playbook
```
ansible-playbook -i inventory/inventory.yml setup.yml
```
5. Once ansible runs you can successfully mount the shared volumes using NFS.  You can find the command in the `Storage` tab of your Crusoe Web Console. The command should look like this : 

```
sudo mount -o vers=3,nconnect=16,spread_reads,spread_writes,remoteports=100.64.0.2-100.64.0.17 100.64.0.2:/volumes/b0c261f6-9794-4c81-be4a-f505f30a7eef <path/to/mount>
```