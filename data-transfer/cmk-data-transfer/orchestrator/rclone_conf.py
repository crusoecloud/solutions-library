"""Build the rclone.conf body for S3-compatible remotes.

The generated config is placed ONLY into a Kubernetes Secret (see k8s.py) and
mounted read-only into pods. It is never written to the repo or committed.
"""
from __future__ import annotations

from .config import Config


def build_rclone_conf(cfg: Config) -> str:
    """Build rclone.conf with a source [src] remote, and optionally a [dest]
    remote when DEST_TYPE=s3.

    provider=Other + force_path_style is the generic S3-compatible profile.
    """
    endpoint = cfg.effective_source_endpoint()
    lines = [
        "[src]",
        "type = s3",
        "provider = Other",
        f"access_key_id = {cfg.src_s3_access_key_id}",
        f"secret_access_key = {cfg.src_s3_secret_access_key}",
        f"endpoint = {endpoint}",
    ]
    if cfg.src_s3_region:
        lines.append(f"region = {cfg.src_s3_region}")
    lines += [
        "force_path_style = true",
        "no_check_bucket = true",
        "",
    ]

    if cfg.is_s3_dest():
        lines += [
            "[dest]",
            "type = s3",
            "provider = Other",
            f"access_key_id = {cfg.dest_s3_access_key_id}",
            f"secret_access_key = {cfg.dest_s3_secret_access_key}",
            f"endpoint = {cfg.dest_s3_endpoint}",
        ]
        if cfg.dest_s3_region:
            lines.append(f"region = {cfg.dest_s3_region}")
        lines += [
            "force_path_style = true",
            "no_check_bucket = true",
            "",
        ]

    return "\n".join(lines)
