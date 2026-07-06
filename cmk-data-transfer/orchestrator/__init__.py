"""cmk-data-transfer orchestrator.

Parallel-pulls a dataset from OCI Object Storage (S3-compatible endpoint) to a
VAST-backed ReadWriteMany shared disk on Crusoe Managed Kubernetes, engineered
to saturate s2a worker hosts over a high-RTT intercontinental path.
"""

__version__ = "0.1.0"
