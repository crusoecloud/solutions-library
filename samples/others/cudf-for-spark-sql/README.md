# cuDF for Apache Spark SQL — TPC-DS Benchmarking on Crusoe Cloud

This solution demonstrates the performance gains achievable by accelerating Apache Spark SQL workloads using the [NVIDIA cuDF Spark plugin](https://nvidia.github.io/cudf-spark/) (Rapids) on GPU nodes provided by Crusoe Cloud. It uses the retail industry-standard [TPC-DS ('Decision Support') benchmark](https://www.tpc.org/tpcds/default5.asp) to generate realistic, large-scale synthetic retail data and runs two classes of workload — CSV-to-Parquet transcoding and the TPC-DS Power benchmark — with and without GPU acceleration so that the difference in throughput is directly measurable. To make adoption as easy as possible, the cuDF plugin accelerates Spark SQL execution on the GPU **with no changes to the Spark job code itself**. At the Kubernetes level, the spark application specs are tailored to the GPU or CPU use case as applicable - e.g for the GPU case, each Spark executor can only use a single GPU. so we specify 8 pods per node, whereas in the CPU use case the pods-per-node is determined by the optimum amount of host vCPU and memory for the task at hand.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Crusoe Managed Kubernetes (CMK) cluster with GPU nodes | H100, H200 and B200 will all work; examples are tuned for H100 |
| Ephemeral storage (`containerd`) set to `false` on the GPU node pool | The node's NVMe drives will be raided and used for Spark's local storage, including shuffle |
| [Crusoe Shared Disk storage class](https://github.com/crusoecloud/crusoe-csi-driver) installed | Used for the data and spark logging PVCs |
| NVMe RAID 0 on all GPU nodes | Apply `raid0-ds.yaml` from this directory; see also [How To Setup RAID0 Storage on CMK](https://support.crusoecloud.com/hc/en-us/articles/35590026497563-How-To-Setup-Raid0-Storage-on-Crusoe-Managed-Kubernetes-CMK) |
| Spark Operator for Kubernetes | See installation command below |
| _(Recommended)_ Grafana observability stack | Deploy the `grafana-cmk` solution from this solutions library to observe GPU utilisation during benchmark runs |

**Install Spark Operator:**

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update spark-operator
helm install spark-operator spark-operator/spark-operator \
  --namespace spark-operator --create-namespace --wait
```

---

## Solution Overview

```
cudf-for-spark-sql/
├── image/
│   ├── Dockerfile.cuda          # Multi-stage build: compiles TPC-DS tools, bundles Spark + cuDF plugin
│   └── getGpusResources.sh      # GPU discovery script used by Spark executors
├── pvcs.yaml                    # data-disk (50 TiB) and spark-logs-pvc (1 TiB) PVCs
├── utility-pod.yaml             # Pod for inspecting PVC contents and running tools from the NDS repo
├── raid0-ds.yaml                # DaemonSet to RAID 0 NVMe drives on GPU nodes
├── spark-history-server.yaml    # Spark History Server deployment + LoadBalancer service
├── nds-data-gen-job.yaml        # Job: generate synthetic TPC-DS CSV data
├── nds-transcode-gpu.yaml       # SparkApplication: CSV → Parquet with cuDF (GPU)
├── nds-transcode-cpu.yaml       # SparkApplication: CSV → Parquet without cuDF (CPU only)
├── nds-power-gpu.yaml           # SparkApplication: TPC-DS Power benchmark with cuDF (GPU)
└── nds-power-cpu.yaml           # SparkApplication: TPC-DS Power benchmark without cuDF (CPU only)
```

---

## Step 1 — Build and Push the Container Image

The single container image bundles Apache Spark, the cuDF Rapids plugin, the NDS benchmark scripts, and the compiled TPC-DS data-generation tools. Unfortunately we cannot provide a pre-built version of this image because of the TPC-DS licensing terms, but the download is free and the build process is quick.

Collect the following into the `image/` directory before building:

| Artifact | Source |
|---|---|
| Apache Spark 4.2.0 source (extracted as `spark/`) | https://spark.apache.org/downloads.html |
| NDS benchmark code (adapted to build in our chosen base image) | https://github.com/datadoc24/cudf-spark-benchmarks |
| cuDF Rapids plugin JAR (`rapids-4-spark_2.13-*.jar`) | https://nvidia.github.io/cudf-spark/docs/download.html |
| TPC-DS DSGen 4.0.0 tools (extracted as `DSGen-software-code-4.0.0/`) | Complete the download form at https://www.tpc.org/TPC_Documents_Current_Versions/download_programs/tools-download-request5.asp?bm_type=TPC-DS&bm_vers=4.0.0&mode=CURRENT-ONLY |


Once all artifacts are in place, build using docker, podman etc and push the image:

```bash
cd image/
docker build -f Dockerfile.cuda -t <your-registry>/spark-cudf:latest .
docker push <your-registry>/spark-cudf:latest
```

Update the `image:` field in each YAML file to point to your registry and tag before proceeding.

---

## Step 2 — Create PVCs and Utility Pod

```bash
kubectl apply -f pvcs.yaml
kubectl apply -f utility-pod.yaml
```

- `data-disk` (50 TiB, `ReadWriteMany`) — stores generated CSV data and transcoded Parquet output.
- `spark-logs-pvc` (1 TiB, `ReadWriteMany`) — stores Spark event logs, shared with the History Server.

The utility pod mounts both PVCs and can be used to inspect their contents at any point:

```bash
kubectl exec -it utility-pod -- ls /data
```

---

## Step 3 — Deploy the Spark History Server

```bash
kubectl apply -f spark-history-server.yaml
kubectl wait --for=condition=Ready pod -l app=spark-history-server --timeout=120s
```

> **Note:** `spark-history-server.yaml` uses a node affinity rule to schedule on CPU-only nodes. If your cluster has no CPU-only nodes, remove the `affinity` section from the Deployment spec before applying.

The History Server web UI is exposed on port `18080`. Access it with:

```bash
# Via port-forward:
kubectl port-forward svc/spark-history-server 18080:18080

# Or retrieve the external IP if using LoadBalancer:
kubectl get svc spark-history-server
```

Completed SparkApplications will appear here with full stage timelines, allowing direct comparison of GPU vs. CPU run durations.

---

## Step 4 — Generate Synthetic TPC-DS Data and the benchmark query streams

Edit `nds-data-gen-job.yaml` to set the scale factor (data volume). The relevant arguments are:

```yaml
command:
  - python3
  - /opt/spark-benchmarks/nds/nds_gen_data.py
  - "local"
  - "3000"      # <-- scale factor in GB (e.g. 3000 = ~3 TB, 30000 = ~30 TB)
  - "100"       # number of parallel partitions
  - "/data/tpcds-sf3000"   # output path on the PVC — update to match your scale factor
  - "--overwrite_output"
```

Start with a smaller scale factor (e.g. `1000` for ~1 TB) to validate the pipeline end-to-end before running at full scale.

Apply the job and monitor its progress:

```bash
kubectl apply -f nds-data-gen-job.yaml
kubectl logs -f job/nds-data-generation
```

Use the utility pod to verify data is being written to the PVC:

```bash
kubectl exec -it utility-pod -- ls /data/tpcds-sf3000/
```

Generate the NDS query streams, which is a list of 100 complex SQL queries whose execution times against the generated dataset are measured to produce the TPC-DS benchmark result


```bash
kubectl exec -it utility-pod -- python /opt/spark-benchmarks/nds/nds_gen_query_stream.py /opt/query-templates 1000 /home/query_streams --streams 1
```

---

## Step 5 — Run the Transcoding Benchmark

This benchmark transcodes the generated CSV data to Parquet format. Run the GPU-accelerated version first, then the CPU-only version, and compare their durations in the Spark History Server.

```bash
# GPU-accelerated (cuDF enabled)
kubectl apply -f nds-transcode-gpu.yaml

# After it completes, run the CPU-only version
kubectl apply -f nds-transcode-cpu.yaml
```

Monitor status:

```bash
kubectl get sparkapplication
kubectl describe sparkapplication nds-transcode-gpu
```

Once both complete, open the Spark History Server UI and compare the total application duration for `nds-transcode-gpu` vs. `nds-transcode-cpu`.

---

## Step 6 — Run the TPC-DS Power Benchmark

The Power benchmark executes the full suite of TPC-DS analytical SQL queries against the Parquet dataset. This is the primary benchmark for comparing query engine performance.

```bash
# GPU-accelerated (cuDF enabled)
kubectl apply -f nds-power-gpu.yaml

# After it completes, run the CPU-only version
kubectl apply -f nds-power-cpu.yaml
```

Each run produces a timing CSV report on the data PVC (e.g. `/data/mytime-3.csv`) containing per-query durations. Review this report alongside the Spark History Server to see the speedup delivered by cuDF on a query-by-query basis.

---

## Step 7 — Review Results

**Spark History Server** — compare total application duration and per-stage timings between GPU and CPU runs for both the transcoding and Power benchmark jobs.

**Grafana dashboards** — if the `grafana-cmk` observability stack is deployed on your cluster, use the GPU utilisation dashboards to confirm that the cuDF plugin is fully exercising the Crusoe Cloud GPU nodes during the benchmark runs. High, sustained GPU utilisation during the GPU benchmark runs (and its absence during CPU runs) is a direct visual indicator of the acceleration in action.

---

## Key Notes

- **No code changes required.** The cuDF Spark plugin operates transparently at the SQL execution layer. The same Python benchmark scripts (`nds_transcode.py`, `nds_power.py`) are used for both GPU and CPU runs — the only difference is the presence or absence of the `spark.plugins: com.nvidia.spark.SQLPlugin` configuration.
- **RAID 0 scratch storage.** The Power benchmark (`nds-power-gpu.yaml`) uses the NVMe RAID 0 array at `/mnt/raid0/spark-local` as Spark's local scratch directory. This is important at large scale factors where shuffle data can exceed available memory.
- **Scale factor and resource sizing.** The example YAMLs are configured for large-scale runs (e.g. 16 executor instances, H100 GPUs). Adjust `instances`, `cores`, `memory`, and the scale factor in `nds-data-gen-job.yaml` to match your cluster size and available GPU nodes.
