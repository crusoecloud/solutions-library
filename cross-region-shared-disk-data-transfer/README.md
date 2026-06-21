# Cross-Region Shared Disk Data Transfer

Transfer data from a Crusoe shared disk in one location to a Crusoe shared disk in another location using nginx (source) and aria2c on Kubernetes (destination).

## Architecture

```
Source Location                        Destination Location
┌─────────────────────────┐            ┌──────────────────────────────────────┐
│  nginx-server-0         │            │  Kubernetes Cluster (CMK)            │
│  nginx-server-1   :8080 │──internet──│  ┌────────────────────────────────┐  │
│  ...                    │            │  │  aria2c-worker pods (×NUM_PODS)│  │
│                         │            │  │  downloading in parallel       │  │
│  [Source Shared Disk]   │            │  └────────────────────────────────┘  │
│  mounted at /vast       │            │                                      │
└─────────────────────────┘            │  [Destination Shared Disk]           │
                                       │  mounted as PVC at /vast             │
                                       └──────────────────────────────────────┘
```

nginx serves files from the source VAST NFS share using `sendfile()` for zero-copy
transfers directly from NFS page cache to TCP sockets. aria2c workers on the
destination cluster download files in parallel with multi-connection splits.

## Prerequisites

- Terraform >= 1.5
- Ansible >= 2.14 with collections: `ansible.posix`, `community.general`
- `crusoe` CLI installed and authenticated
- `kubectl` and `helm` installed (for Grafana CMK step)
- SSH key pair available locally

## Step 1: Configure terraform.tfvars

Copy the example and fill in your values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Key values to set:
- `source_server_location`, `source_server_project_id`, `source_server_vpc_subnet_id` — source location
- `source_server_groups` — list of `{ vm_type, vm_count }` objects; add multiple entries to mix instance types
- `source_disk_id` — UUID of the source shared disk
- `http_user`, `http_password` — credentials for HTTP basic auth
- `destination_location`, `destination_project_id`, `cluster_subnet_id`
- `cluster_version`, `nodepool_version`, `nodepool_groups` — list of `{ vm_type, vm_count }` for destination node pools
- `destination_disk_id` — UUID of the pre-existing destination shared disk

Find your subnet IDs and disk UUIDs:
```bash
crusoe vpc subnets list
crusoe storage disks list
```

## Step 2: Provision infrastructure with Terraform

```bash
terraform init
terraform plan
terraform apply
```

This provisions:
- Source server VMs with static public IPs (nginx installed via Ansible)
- Firewall rules allowing port 8080 access from destination nodepool VMs
- Kubernetes cluster with Crusoe CSI driver addon in the destination location
- aria2c node pool for parallel downloads

And automatically runs Ansible to:
- Install and configure nginx on source VMs with `sendfile`, `aio threads`, and HTTP basic auth
- Mount the source VAST NFS share with `nconnect=16` and kernel tuning
- Generate `downloads.txt` (the file manifest with rotated mirror URLs for load balancing)
- Configure `aria2c-download.py` with values derived from Terraform
- Apply the StorageClass, PersistentVolume, and PersistentVolumeClaim for the destination disk
- Install Grafana CMK on the destination cluster (if `grafana_monitoring_token` is set)

Note useful Terraform outputs:
```bash
terraform output source_server_public_ips   # source server IPs
terraform output aria2c_num_pods            # recommended NUM_PODS for aria2c
terraform output get_kubeconfig_command     # command to get kubeconfig
```

## Step 3: Run aria2c-download.py

`terraform apply` automatically configures `aria2c-download.py` via Ansible:

| Variable | Source |
|---|---|
| `NUM_PODS` | total VMs across `nodepool_groups` × 8 |
| `DATA_MOUNT` | `destination_disk_mount_path` |
| `HTTP_USER` | `http_user` |
| `HTTP_PASSWD` | `http_password` |

The only value to set manually is `PVC_NAME` — update it to match the PVC name (default: `"aria2c-vast-csi-import"`).

Ensure `downloads.txt` is in the current directory (Ansible generated it automatically).

Set your kubeconfig:
```bash
export KUBECONFIG=$(pwd)/kubeconfig-$(terraform output -raw destination_cluster_id)
```

Run the download:
```bash
python3 aria2c-download.py
```

This will:
1. Split `downloads.txt` into shards (one per worker pod)
2. Launch a master pod to stage the shards on the PVC
3. Launch `NUM_PODS` aria2c worker pods across the nodepool VMs
4. Wait for all downloads to complete
5. Clean up pods and report results

## Step 4: Verify the transfer

```bash
# Check that files were written to the destination disk
kubectl run verify --image=busybox --rm -it --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"pvc","persistentVolumeClaim":{"claimName":"aria2c-vast-csi-import"}}],"containers":[{"name":"verify","image":"busybox","command":["sh","-c","ls /vast && du -sh /vast"],"volumeMounts":[{"mountPath":"/vast","name":"pvc"}]}]}}'
```

## Step 5: Grafana CMK (optional)

If you set `grafana_monitoring_token` in `terraform.tfvars`, Grafana was installed automatically by Ansible. To access it:

Get the admin password:
```bash
kubectl get secret grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

Port forward to the service:
```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000
```

Access Grafana at http://127.0.0.1:3000 with user `admin` and the password from above.

## Cleanup

```bash
# Destroy all infrastructure (PV/PVC are deleted automatically)
terraform destroy
```

## Troubleshooting

**aria2c pods can't reach source servers:**
- Verify firewall rules exist: `crusoe vpc firewall-rules list` (should see `source-http-*` rules)
- Test from a pod: `kubectl exec -it aria2c-master -- wget -q --user=<user> --password=<pass> http://<server-ip>:8080/`

**nginx not running on source VMs:**
- SSH to a source server: `ssh ubuntu@<public-ip>`
- Check status: `sudo systemctl status nginx`
- Check logs: `sudo journalctl -u nginx -n 50`
- Test config: `sudo nginx -t`

**PVC stuck in Pending:**
- Verify the storage class: `kubectl get storageclass`
- Check CSI driver: `kubectl get pods -n kube-system | grep csi`
- Describe the PVC: `kubectl describe pvc aria2c-vast-csi-import`

**downloads.txt not generated:**
- Run Ansible manually: `ansible-playbook -i ansible/inventory/inventory.yml ansible/playbook.yml`
- Or SSH to a source server and run `/tmp/download-links.sh` manually

**PV/PVC not applied or disk details fetch failed:**
- Run Ansible manually: `ansible-playbook -i ansible/inventory/inventory.yml ansible/playbook.yml`
- Verify the disk exists: `crusoe storage disks list --project-id <destination_project_id> -f json`
- Confirm that `destination_disk_id` in `terraform.tfvars` matches the `id` field in the output above

## Performance Tuning

The source servers include the following optimizations configured via Ansible:

- **nginx with `sendfile`** — zero-copy file serving directly from NFS page cache to TCP socket
- **`aio threads`** — async NFS I/O prevents worker blocking
- **`nconnect=16`** — 16 parallel NFS TCP connections to VAST
- **BBR congestion control** — optimized for high-BDP cross-region paths
- **Jumbo frames (MTU 9000)** — reduces per-packet overhead
- **NFS read-ahead (16 MB)** — reduces round trips for sequential reads
- **NFS RPC slot table (512)** — allows up to 16,384 concurrent RPCs (32 connections x 512 slots)
- **Socket buffer tuning** — 256 MB max buffers for high-bandwidth links
- **Mirror URL rotation** — `downloads.txt` rotates server order per file to balance load

The aria2c workers include:
- **`--max-concurrent-downloads=64`** — 64 files downloading simultaneously per worker
- **`--disk-cache=64M`** — reduces write syscall frequency
- **BBR + socket tuning** — same kernel tuning as source servers
