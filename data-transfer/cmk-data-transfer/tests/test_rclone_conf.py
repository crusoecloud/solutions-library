# tests/test_rclone_conf.py
"""Tests for rclone.conf generation after OCI->SRC_S3 rename."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from orchestrator.config import Config
from orchestrator.rclone_conf import build_rclone_conf


def test_source_remote_named_src():
    cfg = Config(
        src_s3_access_key_id="AKID",
        src_s3_secret_access_key="SECRET",
        src_s3_endpoint="https://s3.us-east-1.amazonaws.com",
        src_s3_region="us-east-1",
    )
    conf = build_rclone_conf(cfg)
    assert "[src]" in conf
    assert "[oci]" not in conf


def test_source_remote_contains_creds():
    cfg = Config(
        src_s3_access_key_id="AKID",
        src_s3_secret_access_key="SECRET",
        src_s3_endpoint="https://s3.us-east-1.amazonaws.com",
        src_s3_region="us-east-1",
    )
    conf = build_rclone_conf(cfg)
    assert "access_key_id = AKID" in conf
    assert "secret_access_key = SECRET" in conf
    assert "endpoint = https://s3.us-east-1.amazonaws.com" in conf
    assert "region = us-east-1" in conf


def test_source_remote_generic_s3():
    cfg = Config(
        src_s3_access_key_id="AKID",
        src_s3_secret_access_key="SECRET",
        src_s3_endpoint="https://s3.us-east-1.amazonaws.com",
    )
    conf = build_rclone_conf(cfg)
    assert "type = s3" in conf
    assert "provider = Other" in conf
    assert "force_path_style = true" in conf
    assert "no_check_bucket = true" in conf


def test_no_dest_remote_when_disk():
    cfg = Config(
        src_s3_access_key_id="AKID",
        src_s3_secret_access_key="SECRET",
        src_s3_endpoint="https://s3.us-east-1.amazonaws.com",
        dest_type="disk",
    )
    conf = build_rclone_conf(cfg)
    assert "[dest]" not in conf


def test_dest_remote_when_s3():
    cfg = Config(
        src_s3_access_key_id="AKID",
        src_s3_secret_access_key="SECRET",
        src_s3_endpoint="https://s3.us-east-1.amazonaws.com",
        dest_type="s3",
        dest_s3_access_key_id="DAKID",
        dest_s3_secret_access_key="DSECRET",
        dest_s3_endpoint="https://s3.crusoe.ai",
        dest_s3_region="us-east",
    )
    conf = build_rclone_conf(cfg)
    assert "[src]" in conf
    assert "[dest]" in conf
    # dest creds
    assert "DAKID" in conf
    assert "DSECRET" in conf
    assert "https://s3.crusoe.ai" in conf


def test_dest_remote_region_omitted_when_empty():
    cfg = Config(
        src_s3_access_key_id="AKID",
        src_s3_secret_access_key="SECRET",
        src_s3_endpoint="https://s3.us-east-1.amazonaws.com",
        dest_type="s3",
        dest_s3_access_key_id="DAKID",
        dest_s3_secret_access_key="DSECRET",
        dest_s3_endpoint="https://s3.crusoe.ai",
        dest_s3_region="",
    )
    conf = build_rclone_conf(cfg)
    # The [dest] section should NOT have a region line
    dest_section = conf[conf.index("[dest]"):]
    assert "region" not in dest_section
