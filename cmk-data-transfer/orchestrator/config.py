"""Configuration: env / .env / CLI flags -> a single Config object.

Precedence (low -> high): .env file < process env < CLI flags.
Secrets are read but never logged or written to disk in cleartext outside the
in-cluster Kubernetes Secret.
"""
from __future__ import annotations

import argparse
import os
import re
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Optional


# --- Default node hardware baseline (s2a.80x): drives the sizing model. ---
# Override per-SKU via NODE_VCPU / NODE_RAM_GIB / NODE_NIC_GBPS.
S2A_VCPU = 80
S2A_RAM_GIB = 676
S2A_NIC_GBPS = 200


KNOWN_OCI_REGION_RE = re.compile(r"^[a-z]{2,3}-[a-z]+-\d+$")  # e.g. us-phoenix-1


def _load_dotenv(path: Path) -> dict[str, str]:
    """Minimal .env parser (no dependency on python-dotenv)."""
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        # strip inline comment, but not inside quotes and not a '#' that's part
        # of the value (only treat ' #' / leading '#' / '\t#' as a comment start)
        if val and val[0] not in ("'", '"'):
            if val.startswith("#"):
                val = ""
            else:
                for sep in (" #", "\t#"):
                    idx = val.find(sep)
                    if idx != -1:
                        val = val[:idx]
        val = val.strip().strip('"').strip("'")
        if key:
            out[key] = val
    return out


@dataclass
class Config:
    # --- OCI source ---
    access_key_id: str = ""
    secret_access_key: str = ""
    namespace: str = ""
    region: str = "us-phoenix-1"
    bucket: str = ""
    prefix: str = ""
    endpoint: str = ""

    # --- Destination ---
    pvc_name: str = "cmk-data-transfer-fs"
    pvc_size: str = "1000Ti"
    storage_class: str = "crusoe-csi-driver-fs-sc"
    dest_path: str = "/data/dataset"

    # --- Import an EXISTING Crusoe shared disk (instead of dynamic provisioning).
    # Find the values with `crusoe storage disks list -f json`: use the disk's
    # `id` (volumeHandle), `name` (disk-name attribute) and `serial_number`.
    # When all three are set, the orchestrator creates a static PV (reclaim
    # policy Retain — the customer's disk is never deleted) and binds the PVC to
    # it instead of provisioning a new disk. Migrate data into an existing disk.
    existing_disk_id: str = ""       # crusoe disk `id`  -> CSI volumeHandle
    existing_disk_name: str = ""     # crusoe disk `name`-> csi.crusoe.ai/disk-name
    existing_disk_serial: str = ""   # crusoe disk `serial_number`
    existing_disk_fstype: str = "ext4"

    # --- Destination mode ---
    #   dynamic : provision a new disk via the fs CSI driver (default)
    #   import  : bind an existing disk via a CSI static PV (disk id/name/serial)
    #   nfs     : bind an existing disk via an in-tree NFS PV straight to the VAST
    #             DNS endpoint, bypassing the CSI driver. Use this where CSI mounts
    #             time out on an unroutable fallback IP (disk returns no data-path
    #             connectivity fields).
    dest_mode: str = "dynamic"
    nfs_server: str = "nfs.crusoecloudcompute.com"
    nfs_export_path: str = ""        # default: /volumes/<existing_disk_id>
    nfs_mount_options: str = (
        "vers=3,nconnect=16,spread_reads,spread_writes,remoteports=dns")

    # --- Sizing ---
    target_gbps: float = 30.0
    num_nodes: int = 4
    pods_per_node: int = 8          # multiple workers per node (more = shorter tail)
    num_pods: Optional[int] = None  # absolute override; default = nodes*per_node
    instance_class: str = "s2a"
    # Node hardware (defaults = s2a.80x); set for other SKUs/clouds.
    node_vcpu: int = S2A_VCPU
    node_ram_gib: int = S2A_RAM_GIB
    node_nic_gbps: int = S2A_NIC_GBPS
    rtt_ms: float = 150.0
    per_stream_mbps: float = 250.0
    stream_safety: float = 1.5

    # --- rclone (blank/None => auto-derive in sizing) ---
    rclone_transfers: Optional[int] = None
    rclone_multi_thread_streams: Optional[int] = None
    rclone_multi_thread_cutoff: str = "256M"
    rclone_multi_thread_chunk_size: str = "32M"   # smaller = shorter per-file tail
    rclone_checkers: Optional[int] = None
    rclone_buffer_size: str = "32M"
    rclone_s3_chunk_size: str = "64M"
    rclone_extra_flags: str = ""

    # --- Worker pod resources (blank => auto-derive from pods_per_node) ---
    worker_cpu_request: str = ""
    worker_mem_request: str = ""

    # --- K8s plumbing ---
    k8s_namespace: str = "default"
    secret_name: str = "cmk-data-transfer-oci"
    rclone_image: str = "rclone/rclone:latest"
    master_pod_name: str = "cmk-data-transfer-master"
    mount_root: str = "/data"  # shared-disk (PVC) mount path in all pods
    kubeconfig: str = ""

    def effective_num_pods(self) -> int:
        """Total worker pods across the fleet."""
        if self.num_pods:
            return self.num_pods
        return self.num_nodes * max(1, self.pods_per_node)

    def effective_pods_per_node(self) -> int:
        """Workers per node. If NUM_PODS is forced, spread it across nodes."""
        if self.num_pods:
            return max(1, -(-self.num_pods // self.num_nodes))  # ceil div
        return max(1, self.pods_per_node)

    def effective_endpoint(self) -> str:
        if self.endpoint:
            return self.endpoint
        return (
            f"https://{self.namespace}.compat.objectstorage."
            f"{self.region}.oraclecloud.com"
        )

    def remote_root(self) -> str:
        """`oci:bucket[/prefix]` for rclone."""
        root = f"oci:{self.bucket}"
        if self.prefix:
            root += "/" + self.prefix.strip("/")
        return root

    def is_import(self) -> bool:
        """Bind an existing disk via a CSI static PV."""
        return self.dest_mode == "import"

    def is_nfs(self) -> bool:
        """Bind an existing disk via an in-tree NFS PV (DNS endpoint)."""
        return self.dest_mode == "nfs"

    def static_pv_name(self) -> str:
        """Name of the static PV created for import/nfs modes."""
        return f"{self.pvc_name}-pv"

    def nfs_path(self) -> str:
        return self.nfs_export_path or f"/volumes/{self.existing_disk_id}"

    # ----------------------------------------------------------------- validate
    def validate(self, require_secrets: bool = True) -> list[str]:
        errs: list[str] = []
        if require_secrets:
            if not self.access_key_id:
                errs.append("OCI_ACCESS_KEY_ID is required")
            if not self.secret_access_key:
                errs.append("OCI_SECRET_ACCESS_KEY is required")
        if not self.namespace and not self.endpoint:
            errs.append("OCI_NAMESPACE (or explicit OCI_ENDPOINT) is required")
        if not self.bucket:
            errs.append("OCI_BUCKET is required")
        if self.num_nodes < 1:
            errs.append("NUM_NODES must be >= 1")
        if self.target_gbps <= 0:
            errs.append("TARGET_GBPS must be > 0")
        if self.pods_per_node < 1:
            errs.append("PODS_PER_NODE must be >= 1")
        if self.dest_mode not in ("dynamic", "import", "nfs"):
            errs.append(f"DEST_MODE must be dynamic|import|nfs (got "
                        f"'{self.dest_mode}')")
        if self.is_import() and not (self.existing_disk_id
                                     and self.existing_disk_name
                                     and self.existing_disk_serial):
            errs.append(
                "import mode needs EXISTING_DISK_ID, EXISTING_DISK_NAME, and "
                "EXISTING_DISK_SERIAL together (from `crusoe storage disks "
                "list -f json`: the disk's id, name, and serial_number)."
            )
        if self.is_nfs():
            if not self.existing_disk_id and not self.nfs_export_path:
                errs.append("nfs mode needs EXISTING_DISK_ID (export path "
                            "/volumes/<id>) or an explicit NFS_EXPORT_PATH")
            if not self.nfs_server:
                errs.append("nfs mode needs NFS_SERVER")
        return errs

    def warnings(self) -> list[str]:
        warns: list[str] = []
        if not self.endpoint and not KNOWN_OCI_REGION_RE.match(self.region):
            warns.append(
                f"OCI_REGION='{self.region}' does not look like an OCI region "
                "slug (expected e.g. us-phoenix-1 / us-ashburn-1). Use the OCI "
                "region where the bucket lives, not the destination/cloud region."
            )
        return warns


def _coerce(name: str, raw: str):
    """Coerce a string env value to the dataclass field type."""
    types = {f.name: f.type for f in fields(Config)}
    t = types.get(name, "str")
    if raw == "":
        return None if "Optional" in str(t) else raw
    if "int" in str(t):
        return int(raw)
    if "float" in str(t):
        return float(raw)
    return raw


# env var name -> Config field name
_ENV_MAP = {
    "OCI_ACCESS_KEY_ID": "access_key_id",
    "OCI_SECRET_ACCESS_KEY": "secret_access_key",
    "OCI_NAMESPACE": "namespace",
    "OCI_REGION": "region",
    "OCI_BUCKET": "bucket",
    "OCI_PREFIX": "prefix",
    "OCI_ENDPOINT": "endpoint",
    "PVC_NAME": "pvc_name",
    "PVC_SIZE": "pvc_size",
    "STORAGE_CLASS": "storage_class",
    "DEST_PATH": "dest_path",
    "EXISTING_DISK_ID": "existing_disk_id",
    "EXISTING_DISK_NAME": "existing_disk_name",
    "EXISTING_DISK_SERIAL": "existing_disk_serial",
    "EXISTING_DISK_FSTYPE": "existing_disk_fstype",
    "DEST_MODE": "dest_mode",
    "NFS_SERVER": "nfs_server",
    "NFS_EXPORT_PATH": "nfs_export_path",
    "NFS_MOUNT_OPTIONS": "nfs_mount_options",
    "TARGET_GBPS": "target_gbps",
    "NUM_NODES": "num_nodes",
    "PODS_PER_NODE": "pods_per_node",
    "NUM_PODS": "num_pods",
    "INSTANCE_CLASS": "instance_class",
    "NODE_VCPU": "node_vcpu",
    "NODE_RAM_GIB": "node_ram_gib",
    "NODE_NIC_GBPS": "node_nic_gbps",
    "RTT_MS": "rtt_ms",
    "PER_STREAM_MBPS": "per_stream_mbps",
    "STREAM_SAFETY": "stream_safety",
    "RCLONE_TRANSFERS": "rclone_transfers",
    "RCLONE_MULTI_THREAD_STREAMS": "rclone_multi_thread_streams",
    "RCLONE_MULTI_THREAD_CUTOFF": "rclone_multi_thread_cutoff",
    "RCLONE_MULTI_THREAD_CHUNK_SIZE": "rclone_multi_thread_chunk_size",
    "RCLONE_CHECKERS": "rclone_checkers",
    "RCLONE_BUFFER_SIZE": "rclone_buffer_size",
    "RCLONE_S3_CHUNK_SIZE": "rclone_s3_chunk_size",
    "RCLONE_EXTRA_FLAGS": "rclone_extra_flags",
    "WORKER_CPU_REQUEST": "worker_cpu_request",
    "WORKER_MEM_REQUEST": "worker_mem_request",
    "NAMESPACE": "k8s_namespace",
    "SECRET_NAME": "secret_name",
    "RCLONE_IMAGE": "rclone_image",
    "KUBECONFIG": "kubeconfig",
}


def load_config(argv: Optional[list[str]] = None):
    """Build Config from .env, process env, then CLI flags (highest).

    Returns (Config, argparse.Namespace) so callers can read run-control flags
    like --dry-run / --keep / --yes.
    """
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    env_file = Path(args.env_file or ".env")
    merged: dict[str, str] = {}
    merged.update(_load_dotenv(env_file))
    # process env overrides .env
    for env_key in _ENV_MAP:
        if env_key in os.environ:
            merged[env_key] = os.environ[env_key]

    cfg = Config()
    for env_key, field_name in _ENV_MAP.items():
        if env_key in merged:
            coerced = _coerce(field_name, merged[env_key])
            if coerced is not None:
                setattr(cfg, field_name, coerced)

    # CLI flags (highest precedence) — only those explicitly provided.
    cli_map = {
        "target_gbps": args.target_gbps,
        "num_nodes": args.num_nodes,
        "pods_per_node": args.pods_per_node,
        "num_pods": args.num_pods,
        "bucket": args.bucket,
        "prefix": args.prefix,
        "namespace": args.namespace,
        "region": args.region,
        "rtt_ms": args.rtt_ms,
        "per_stream_mbps": args.per_stream_mbps,
        "rclone_transfers": args.transfers,
        "rclone_multi_thread_streams": args.multi_thread_streams,
        "rclone_checkers": args.checkers,
        "pvc_name": args.pvc_name,
        "storage_class": args.storage_class,
        "existing_disk_id": args.import_disk_id,
        "existing_disk_name": args.import_disk_name,
        "existing_disk_serial": args.import_disk_serial,
        "dest_mode": args.dest_mode,
        "nfs_server": args.nfs_server,
    }
    for field_name, val in cli_map.items():
        if val is not None:
            setattr(cfg, field_name, val)

    if cfg.kubeconfig:
        os.environ["KUBECONFIG"] = cfg.kubeconfig

    return cfg, args


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Parallel OCI->VAST pull on Crusoe CMK, tuned for s2a.",
    )
    p.add_argument("--env-file", help="Path to .env (default: ./.env)")
    p.add_argument("--target-gbps", type=float, help="Single sizing knob")
    p.add_argument("--num-nodes", type=int)
    p.add_argument("--pods-per-node", type=int,
                   help="worker pods per node (spread evenly)")
    p.add_argument("--num-pods", type=int,
                   help="absolute total pods override (spread across nodes)")
    p.add_argument("--bucket")
    p.add_argument("--prefix")
    p.add_argument("--namespace", help="OCI Object Storage namespace")
    p.add_argument("--region", help="OCI region slug")
    p.add_argument("--rtt-ms", type=float)
    p.add_argument("--per-stream-mbps", type=float)
    p.add_argument("--transfers", type=int, help="Override rclone --transfers")
    p.add_argument("--multi-thread-streams", type=int,
                   help="Override rclone --multi-thread-streams")
    p.add_argument("--checkers", type=int, help="Override rclone --checkers")
    p.add_argument("--pvc-name")
    p.add_argument("--storage-class")
    p.add_argument("--import-disk-id",
                   help="Bind an EXISTING shared disk: its `id` (volumeHandle) "
                        "from `crusoe storage disks list`")
    p.add_argument("--import-disk-name",
                   help="Existing disk `name` (csi.crusoe.ai/disk-name)")
    p.add_argument("--import-disk-serial",
                   help="Existing disk `serial_number`")
    p.add_argument("--dest-mode", choices=("dynamic", "import", "nfs"),
                   help="destination: provision / CSI import / in-tree NFS PV")
    p.add_argument("--nfs-server", help="VAST NFS DNS endpoint (nfs mode)")
    p.add_argument("--dry-run", action="store_true",
                   help="Render plan + manifests, do not apply to the cluster")
    p.add_argument("--keep", action="store_true",
                   help="Do not tear down pods after completion")
    p.add_argument("--yes", action="store_true",
                   help="Skip the interactive confirmation before launching "
                        "worker pods (the large transfer).")
    return p
