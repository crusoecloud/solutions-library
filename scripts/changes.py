"""Files changed by the current MR, shared by the standards checks."""
import os
import subprocess
from pathlib import Path


def changed_files(root: Path) -> list[str] | None:
    """Repo-relative paths changed since the MR base, or None outside an MR."""
    base = os.environ.get("CI_MERGE_REQUEST_DIFF_BASE_SHA") or os.environ.get("BASE_SHA")
    if not base:
        return None
    out = subprocess.run(
        ["git", "-C", str(root), "diff", "-z", "--name-only", base, "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout
    # -z: git C-quotes non-ASCII paths otherwise, and those files would silently skip the checks.
    return [p for p in out.split("\0") if p]
