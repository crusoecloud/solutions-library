"""Kubernetes manifest (dict) builders.

These dicts are the authoritative, runtime-applied manifests. Human-readable
YAML equivalents live under k8s/ for reference and manual use.

Layout on the shared RWX volume (mounted at cfg.mount_root, default /data):
    /data/shards/shard-<i>.txt     # one manifest per worker
    /data/logs/worker-<i>.log      # per-worker rclone output
    /data/dataset/...              # downloaded objects (DEST_PATH)
"""
from __future__ import annotations

from .config import Config
from .sizing import Sizing

WORKER_LABEL = "cmk-data-transfer-worker"
SHARD_SUBDIR = "shards"
LOG_SUBDIR = "logs"
BASE_RC_PORT = 5572   # worker i binds rc on BASE_RC_PORT + i (unique per pod)


def shard_dir(cfg: Config) -> str:
    return f"{cfg.mount_root}/{SHARD_SUBDIR}"


def log_dir(cfg: Config) -> str:
    return f"{cfg.mount_root}/{LOG_SUBDIR}"


def storage_class(name: str) -> dict:
    """Crusoe VAST RWX storage class (created only if absent)."""
    return {
        "apiVersion": "storage.k8s.io/v1",
        "kind": "StorageClass",
        "metadata": {"name": name},
        "provisioner": "fs.csi.crusoe.ai",
        "reclaimPolicy": "Delete",
        "volumeBindingMode": "Immediate",
        "allowVolumeExpansion": True,
    }


def import_pv(cfg: Config) -> dict:
    """Static PV that binds to an EXISTING Crusoe shared disk.

    Mirrors the PV shape the fs CSI provisioner emits for a dynamic claim, but
    points volumeHandle at the customer's existing disk and uses reclaimPolicy
    Retain so the disk (and its data) is never deleted when the PVC/PV go away.
    Pre-bound to our PVC via claimRef so nothing else can claim it.
    """
    return {
        "apiVersion": "v1",
        "kind": "PersistentVolume",
        "metadata": {"name": cfg.static_pv_name()},
        "spec": {
            "capacity": {"storage": cfg.pvc_size},
            "accessModes": ["ReadWriteMany"],
            "persistentVolumeReclaimPolicy": "Retain",
            "storageClassName": "",            # static; no dynamic provisioning
            "volumeMode": "Filesystem",
            "csi": {
                "driver": "fs.csi.crusoe.ai",
                "volumeHandle": cfg.existing_disk_id,
                "fsType": cfg.existing_disk_fstype,
                "volumeAttributes": {
                    "csi.crusoe.ai/disk-name": cfg.existing_disk_name,
                    "csi.crusoe.ai/serial-number": cfg.existing_disk_serial,
                },
            },
            "claimRef": {"namespace": cfg.k8s_namespace, "name": cfg.pvc_name},
        },
    }


def nfs_pv(cfg: Config) -> dict:
    """Static IN-TREE NFS PV bound to an existing VAST volume via the DNS
    endpoint — bypasses the CSI driver.

    Why this exists: where the fs CSI driver falls back to an unroutable IP
    (the disk returns no data-path connectivity fields) and mounts time out, the
    VAST DNS endpoint resolves to the in-VPC data IPs and mounts cleanly with
    remoteports=dns. reclaimPolicy Retain so the disk/data is never deleted.
    """
    return {
        "apiVersion": "v1",
        "kind": "PersistentVolume",
        "metadata": {"name": cfg.static_pv_name()},
        "spec": {
            "capacity": {"storage": cfg.pvc_size},
            "accessModes": ["ReadWriteMany"],
            "persistentVolumeReclaimPolicy": "Retain",
            "storageClassName": "",
            "volumeMode": "Filesystem",
            "mountOptions": cfg.nfs_mount_options.split(","),
            "nfs": {"server": cfg.nfs_server, "path": cfg.nfs_path()},
            "claimRef": {"namespace": cfg.k8s_namespace, "name": cfg.pvc_name},
        },
    }


def pvc(cfg: Config) -> dict:
    spec = {
        "accessModes": ["ReadWriteMany"],
        "resources": {"requests": {"storage": cfg.pvc_size}},
        "volumeMode": "Filesystem",
    }
    if cfg.is_import() or cfg.is_nfs():
        # bind to the static PV; empty class disables dynamic provisioning
        spec["storageClassName"] = ""
        spec["volumeName"] = cfg.static_pv_name()
    else:
        spec["storageClassName"] = cfg.storage_class
    return {
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {"name": cfg.pvc_name, "namespace": cfg.k8s_namespace},
        "spec": spec,
    }


def _shared_volume(cfg: Config) -> dict:
    return {"name": "shared",
            "persistentVolumeClaim": {"claimName": cfg.pvc_name}}


def _rclone_conf_volume(cfg: Config) -> dict:
    return {"name": "rclone-conf",
            "secret": {"secretName": cfg.secret_name,
                       "defaultMode": 0o400,
                       "items": [{"key": "rclone.conf",
                                  "path": "rclone.conf"}]}}


def master_pod(cfg: Config) -> dict:
    """Lightweight pod that mounts the shared disk; lists + shards run here.

    Pinned to the worker instance class so its in-cluster egress path to OCI
    matches the workers' (relevant for the listing pass).
    """
    init = (f"mkdir -p {shard_dir(cfg)} {log_dir(cfg)} {cfg.dest_path}; "
            "while true; do sleep 3600; done")
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": cfg.master_pod_name,
            "namespace": cfg.k8s_namespace,
            "labels": {"app": "cmk-data-transfer-master"},
        },
        "spec": {
            "restartPolicy": "Never",
            "nodeSelector": {"crusoe.ai/instance.class": cfg.instance_class},
            "containers": [
                {
                    "name": "master",
                    "image": cfg.rclone_image,
                    "command": ["/bin/sh", "-c", init],
                    "env": [{"name": "RCLONE_CONFIG",
                             "value": "/config/rclone.conf"}],
                    "volumeMounts": [
                        {"name": "shared", "mountPath": cfg.mount_root},
                        {"name": "rclone-conf", "mountPath": "/config",
                         "readOnly": True},
                    ],
                }
            ],
            "volumes": [
                _shared_volume(cfg),
                _rclone_conf_volume(cfg),
            ],
        },
    }


def _worker_command(cfg: Config, sizing: Sizing) -> list[str]:
    shard_file = f"{shard_dir(cfg)}/shard-${{SHARD_INDEX}}.txt"
    log_file = f"{log_dir(cfg)}/worker-${{SHARD_INDEX}}.log"

    rclone = [
        "rclone", "copy",
        "--files-from", shard_file,
        cfg.remote_root(), cfg.dest_path,
        "--config", "/config/rclone.conf",
        "--transfers", str(sizing.transfers),
        "--multi-thread-streams", str(sizing.multi_thread_streams),
        "--multi-thread-cutoff", cfg.rclone_multi_thread_cutoff,
        "--multi-thread-chunk-size", cfg.rclone_multi_thread_chunk_size,
    ]
    # --checkers only when explicitly set (RCLONE_CHECKERS). With --files-from
    # + --no-traverse there's little to check, and the AWS reference omits it;
    # leaving it off uses rclone's default and avoids extra HEAD latency.
    if cfg.rclone_checkers is not None:
        rclone += ["--checkers", str(sizing.checkers)]
    rclone += [
        "--no-traverse",
        "--s3-chunk-size", cfg.rclone_s3_chunk_size,
        "--buffer-size", cfg.rclone_buffer_size,
        # remote-control endpoint so the benchmark collector can poll
        # core/stats per pod. Each pod binds a UNIQUE port ($RC_PORT) because
        # hostNetwork pods share the node's netns — fixed 5572 would collide
        # when multiple workers run on the same node.
        "--rc", "--rc-addr", "localhost:$RC_PORT", "--rc-no-auth",
        "--stats", "10s", "--stats-one-line", "-v",
    ]
    if cfg.rclone_extra_flags:
        rclone += cfg.rclone_extra_flags.split()

    rclone_str = " ".join(rclone)
    script = (
        "set -eu; "
        f"mkdir -p {cfg.dest_path} {log_dir(cfg)}; "
        'echo "[worker ${SHARD_INDEX}] $(date -u) starting"; '
        f"{rclone_str} 2>&1 | tee {log_file}"
    )
    return ["/bin/sh", "-c", script]


def worker_pod(cfg: Config, sizing: Sizing, index: int) -> dict:
    name = f"cmk-data-transfer-worker-{index}"
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": name,
            "namespace": cfg.k8s_namespace,
            "labels": {"app": WORKER_LABEL, "shard": str(index)},
        },
        "spec": {
            "restartPolicy": "Never",
            "hostNetwork": True,            # bypass CNI, use node NIC directly
            "dnsPolicy": "ClusterFirstWithHostNet",
            "nodeSelector": {"crusoe.ai/instance.class": cfg.instance_class},
            # Spread workers EVENLY across nodes (maxSkew=1) so we get
            # pods_per_node on each node rather than all piling onto one. With
            # total_pods = nodes * pods_per_node, even spread => exactly
            # pods_per_node per node. Resource requests (below) enforce density.
            "topologySpreadConstraints": [
                {
                    "maxSkew": 1,
                    "topologyKey": "kubernetes.io/hostname",
                    "whenUnsatisfiable": "DoNotSchedule",
                    "labelSelector": {"matchLabels": {"app": WORKER_LABEL}},
                }
            ],
            "containers": [
                {
                    "name": "worker",
                    "image": cfg.rclone_image,
                    "command": _worker_command(cfg, sizing),
                    "env": [
                        {"name": "SHARD_INDEX", "value": str(index)},
                        # globally-unique rc port (hostNetwork shares node netns)
                        {"name": "RC_PORT", "value": str(BASE_RC_PORT + index)},
                    ],
                    "resources": {
                        "requests": {
                            "cpu": sizing.worker_cpu_request,
                            "memory": sizing.worker_mem_request,
                        }
                    },
                    "volumeMounts": [
                        {"name": "shared", "mountPath": cfg.mount_root},
                        {"name": "rclone-conf", "mountPath": "/config",
                         "readOnly": True},
                    ],
                }
            ],
            "volumes": [
                _shared_volume(cfg),
                _rclone_conf_volume(cfg),
            ],
        },
    }
