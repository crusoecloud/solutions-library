# tests/test_config.py
"""Tests for orchestrator.config after OCI->SRC_S3 rename."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from orchestrator.config import Config


def test_source_remote_root_bucket_only():
    cfg = Config(src_s3_bucket="my-bucket")
    assert cfg.source_remote_root() == "src:my-bucket"


def test_source_remote_root_with_prefix():
    cfg = Config(src_s3_bucket="my-bucket", src_s3_prefix="data/sub/")
    assert cfg.source_remote_root() == "src:my-bucket/data/sub"


def test_effective_source_endpoint_explicit():
    cfg = Config(src_s3_endpoint="https://s3.us-east-1.amazonaws.com")
    assert cfg.effective_source_endpoint() == "https://s3.us-east-1.amazonaws.com"


def test_effective_source_endpoint_empty():
    cfg = Config(src_s3_endpoint="")
    # With no endpoint set, should return empty string (no OCI auto-build anymore)
    assert cfg.effective_source_endpoint() == ""


def test_validate_requires_src_s3_access_key():
    cfg = Config(src_s3_access_key_id="", src_s3_secret_access_key="secret",
                 src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="b")
    errs = cfg.validate()
    assert any("SRC_S3_ACCESS_KEY_ID" in e for e in errs)


def test_validate_requires_src_s3_secret_key():
    cfg = Config(src_s3_access_key_id="key", src_s3_secret_access_key="",
                 src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="b")
    errs = cfg.validate()
    assert any("SRC_S3_SECRET_ACCESS_KEY" in e for e in errs)


def test_validate_requires_src_s3_endpoint():
    cfg = Config(src_s3_access_key_id="key", src_s3_secret_access_key="secret",
                 src_s3_endpoint="", src_s3_bucket="b")
    errs = cfg.validate()
    assert any("SRC_S3_ENDPOINT" in e for e in errs)


def test_validate_requires_src_s3_bucket():
    cfg = Config(src_s3_access_key_id="key", src_s3_secret_access_key="secret",
                 src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="")
    errs = cfg.validate()
    assert any("SRC_S3_BUCKET" in e for e in errs)


def test_validate_passes_with_all_required():
    cfg = Config(src_s3_access_key_id="key", src_s3_secret_access_key="secret",
                 src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="b")
    errs = cfg.validate()
    assert errs == []


def test_env_map_has_src_s3_keys():
    from orchestrator.config import _ENV_MAP
    assert "SRC_S3_ACCESS_KEY_ID" in _ENV_MAP
    assert "SRC_S3_SECRET_ACCESS_KEY" in _ENV_MAP
    assert "SRC_S3_ENDPOINT" in _ENV_MAP
    assert "SRC_S3_BUCKET" in _ENV_MAP
    assert "SRC_S3_PREFIX" in _ENV_MAP
    assert "SRC_S3_REGION" in _ENV_MAP
    # OCI keys must be gone
    assert "OCI_ACCESS_KEY_ID" not in _ENV_MAP
    assert "OCI_NAMESPACE" not in _ENV_MAP


def test_dest_type_defaults_to_disk():
    cfg = Config()
    assert cfg.dest_type == "disk"


def test_is_s3_dest():
    cfg = Config(dest_type="s3")
    assert cfg.is_s3_dest()


def test_is_not_s3_dest():
    cfg = Config(dest_type="disk")
    assert not cfg.is_s3_dest()


def test_dest_remote_root_bucket_only():
    cfg = Config(dest_type="s3", dest_s3_bucket="dest-bucket")
    assert cfg.dest_remote_root() == "dest:dest-bucket"


def test_dest_remote_root_with_prefix():
    cfg = Config(dest_type="s3", dest_s3_bucket="dest-bucket",
                 dest_s3_prefix="output/path/")
    assert cfg.dest_remote_root() == "dest:dest-bucket/output/path"


def test_validate_s3_dest_requires_creds():
    cfg = Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src",
        dest_type="s3", dest_s3_bucket="dest",
        dest_s3_endpoint="https://s3.crusoe.ai",
    )
    errs = cfg.validate()
    assert any("DEST_S3_ACCESS_KEY_ID" in e for e in errs)


def test_validate_s3_dest_requires_bucket():
    cfg = Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src",
        dest_type="s3", dest_s3_access_key_id="dk", dest_s3_secret_access_key="ds",
        dest_s3_endpoint="https://s3.crusoe.ai", dest_s3_bucket="",
    )
    errs = cfg.validate()
    assert any("DEST_S3_BUCKET" in e for e in errs)


def test_validate_s3_dest_requires_endpoint():
    cfg = Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src",
        dest_type="s3", dest_s3_access_key_id="dk", dest_s3_secret_access_key="ds",
        dest_s3_endpoint="", dest_s3_bucket="dest",
    )
    errs = cfg.validate()
    assert any("DEST_S3_ENDPOINT" in e for e in errs)


def test_validate_s3_dest_passes():
    cfg = Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src",
        dest_type="s3", dest_s3_access_key_id="dk", dest_s3_secret_access_key="ds",
        dest_s3_endpoint="https://s3.crusoe.ai", dest_s3_bucket="dest",
    )
    errs = cfg.validate()
    assert errs == []


def test_validate_s3_dest_skips_disk_checks():
    """When dest_type=s3, DEST_MODE validation for import/nfs is irrelevant."""
    cfg = Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src",
        dest_type="s3", dest_s3_access_key_id="dk", dest_s3_secret_access_key="ds",
        dest_s3_endpoint="https://s3.crusoe.ai", dest_s3_bucket="dest",
        dest_mode="import",  # should NOT trigger import validation
    )
    errs = cfg.validate()
    assert not any("EXISTING_DISK" in e for e in errs)


def test_validate_disk_dest_unchanged():
    """When dest_type=disk, existing DEST_MODE validation still works."""
    cfg = Config(
        src_s3_access_key_id="key", src_s3_secret_access_key="secret",
        src_s3_endpoint="https://s3.amazonaws.com", src_s3_bucket="src",
        dest_type="disk", dest_mode="import",
    )
    errs = cfg.validate()
    assert any("EXISTING_DISK" in e for e in errs)


def test_env_map_has_dest_s3_keys():
    from orchestrator.config import _ENV_MAP
    assert "DEST_TYPE" in _ENV_MAP
    assert "DEST_S3_ACCESS_KEY_ID" in _ENV_MAP
    assert "DEST_S3_SECRET_ACCESS_KEY" in _ENV_MAP
    assert "DEST_S3_ENDPOINT" in _ENV_MAP
    assert "DEST_S3_BUCKET" in _ENV_MAP
    assert "DEST_S3_PREFIX" in _ENV_MAP
    assert "DEST_S3_REGION" in _ENV_MAP
