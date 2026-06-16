"""Build the rclone.conf body for the OCI remote.

Primary path: S3-compatible backend pointed at OCI's S3-compat endpoint, using
the customer's Access Key / Secret Key (OCI "Customer Secret Key"). 

The generated config is placed ONLY into a Kubernetes Secret (see k8s.py) and
mounted read-only into pods. It is never written to the repo or committed.
"""
from __future__ import annotations

from .config import Config


def build_s3_compat_conf(cfg: Config) -> str:
    """rclone remote named `oci` using the s3 backend against OCI S3-compat.

    provider=Other + force_path_style is the generic S3-compatible profile;
    OCI's S3-compat endpoint is path-style and validates region in the v4
    signature, so we set region explicitly.
    """
    endpoint = cfg.effective_endpoint()
    return "\n".join(
        [
            "[oci]",
            "type = s3",
            "provider = Other",
            f"access_key_id = {cfg.access_key_id}",
            f"secret_access_key = {cfg.secret_access_key}",
            f"endpoint = {endpoint}",
            f"region = {cfg.region}",
            "force_path_style = true",
            # OCI S3-compat does not implement bucket-create/HEAD-bucket the way
            # AWS does; skip it so copy doesn't error on a read-only key.
            "no_check_bucket = true",
            "",
        ]
    )


def native_oracle_conf_example(cfg: Config) -> str:
    """Documented ALTERNATIVE: native oracleobjectstorage backend.

    Uses OCI IAM (user/instance/resource principal), NOT the S3 access/secret
    key. Shown for completeness; not the default path.
    """
    return "\n".join(
        [
            "[oci-native]",
            "type = oracleobjectstorage",
            f"namespace = {cfg.namespace or '<namespace>'}",
            f"region = {cfg.region}",
            "provider = user_principal_auth",
            "config_file = /root/.oci/config",
            "config_profile = DEFAULT",
            "# compartment = ocid1.compartment.oc1..<...>   # for bucket listing",
            "",
        ]
    )
