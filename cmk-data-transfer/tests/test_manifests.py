# tests/test_manifests.py
"""Tests for manifest generation with S3 destination support."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from orchestrator.config import Config
from orchestrator.sizing import compute_sizing
from orchestrator import manifests


def _s3_dest_config() -> Config:
    return Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src-bucket",
        src_s3_prefix="data/",
        dest_type="s3", dest_s3_access_key_id="dk", dest_s3_secret_access_key="ds",
        dest_s3_endpoint="https://s3.crusoe.ai", dest_s3_bucket="dest-bucket",
        dest_s3_prefix="output/",
        num_nodes=1, pods_per_node=2,
    )


def _disk_dest_config() -> Config:
    return Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src-bucket",
        dest_type="disk",
        num_nodes=1, pods_per_node=2,
    )


def test_worker_command_s3_dest():
    cfg = _s3_dest_config()
    sizing = compute_sizing(cfg)
    pod = manifests.worker_pod(cfg, sizing, 0)
    cmd = pod["spec"]["containers"][0]["command"][-1]  # the shell script
    assert "src:src-bucket/data" in cmd
    assert "dest:dest-bucket/output" in cmd
    assert "/data/dataset" not in cmd  # should NOT write to local disk


def test_worker_command_disk_dest():
    cfg = _disk_dest_config()
    sizing = compute_sizing(cfg)
    pod = manifests.worker_pod(cfg, sizing, 0)
    cmd = pod["spec"]["containers"][0]["command"][-1]
    assert "src:src-bucket" in cmd
    assert "/data/dataset" in cmd
    assert "dest:" not in cmd


def test_pvc_size_s3_dest():
    cfg = _s3_dest_config()
    p = manifests.pvc(cfg)
    assert p["spec"]["resources"]["requests"]["storage"] == "1Ti"


def test_pvc_size_disk_dest():
    cfg = _disk_dest_config()
    p = manifests.pvc(cfg)
    assert p["spec"]["resources"]["requests"]["storage"] == "1000Ti"


def test_master_pod_no_dest_mkdir_s3():
    """When dest is S3, master pod should not mkdir DEST_PATH (no data on disk)."""
    cfg = _s3_dest_config()
    pod = manifests.master_pod(cfg)
    init_cmd = pod["spec"]["containers"][0]["command"][-1]
    assert "/data/dataset" not in init_cmd
    # But shard and log dirs should still be created
    assert "/data/shards" in init_cmd
    assert "/data/logs" in init_cmd
