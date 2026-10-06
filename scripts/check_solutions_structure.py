"""Enforce the repo-structure rules from CONTRIBUTING.md:

  1. Every category directory (a top-level directory) has a README.md.
  2. Every solution directory has a README.md.
  3. Every solution directory is linked from the root README.md.
  4. Every root-README link that points into a category resolves to a
     directory that actually exists.

Layout: <category>/<solution>/, or <category>/<group>/<solution>/ where
<group> is listed in GROUP_DIRS below (e.g. performance-tuning/nvidia).

Run from anywhere; paths are resolved relative to the repo root (this
script's parent's parent directory).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ROOT_README = REPO_ROOT / "README.md"

# Top-level entries that are not solution categories and are exempt from
# the README / root-README-link rules.
NON_SOLUTION_DIRS = {"assets", "scripts"}

# Directories (relative to the repo root) that group solutions one level
# below a category. Their children, not they themselves, are the solutions.
GROUP_DIRS = {
    "performance-tuning/nvidia",
    "performance-tuning/amd",
    "samples/training",
    "samples/inference",
    "samples/others",
}

LINK_RE = re.compile(r"\]\(\./([^)#]+?)/?\)")


def _subdirs(path: Path) -> list[Path]:
    return sorted(
        p
        for p in path.iterdir()
        if p.is_dir() and not p.name.startswith(".") and p.name != "__pycache__"
    )


def category_dirs() -> list[str]:
    return [p.name for p in _subdirs(REPO_ROOT) if p.name not in NON_SOLUTION_DIRS]


def solution_dirs() -> list[str]:
    """Repo-relative paths of every solution directory."""
    found = []
    for cat in category_dirs():
        for child in _subdirs(REPO_ROOT / cat):
            rel = f"{cat}/{child.name}"
            if rel in GROUP_DIRS:
                found.extend(f"{rel}/{g.name}" for g in _subdirs(child))
            else:
                found.append(rel)
    return sorted(found)


def linked_paths(readme_text: str) -> set[str]:
    """Repo-relative paths referenced by relative links in the root README,
    normalised so "foo/bar", "foo/bar/" and "foo/bar/README.md" all count as
    linking "foo/bar".
    """
    paths = set()
    for match in LINK_RE.finditer(readme_text):
        target = match.group(1)
        if (REPO_ROOT / target).is_file():
            target = str(Path(target).parent)
            if target == ".":
                continue  # root-level file, e.g. ./CONTRIBUTING.md
        paths.add(target)
    return paths


def main() -> int:
    if not ROOT_README.is_file():
        print(f"ERROR: root README not found at {ROOT_README}", file=sys.stderr)
        return 1

    linked = linked_paths(ROOT_README.read_text(encoding="utf-8"))
    errors = []

    for cat in category_dirs():
        if not (REPO_ROOT / cat / "README.md").is_file():
            errors.append(
                f"{cat}/: missing README.md — every category directory needs one "
                f"(see CONTRIBUTING.md)"
            )

    solutions = solution_dirs()
    for rel in solutions:
        if not (REPO_ROOT / rel / "README.md").is_file():
            errors.append(
                f"{rel}/: missing README.md — every solution directory needs one "
                f"(see CONTRIBUTING.md)"
            )
        if rel not in linked:
            errors.append(
                f"{rel}/: not linked from the root README.md — add an entry under "
                f"the relevant ## Solutions category (see CONTRIBUTING.md)"
            )

    # Any link into a category should resolve to a real directory.
    categories = set(category_dirs())
    for path in sorted(linked):
        if path.split("/")[0] in categories and not (REPO_ROOT / path).exists():
            errors.append(
                f"README.md links to './{path}' but no such directory exists "
                f"— fix or remove the stale link"
            )

    if errors:
        print("Solutions-library structure check failed:\n", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        print(
            f"\n{len(errors)} issue(s) found. See CONTRIBUTING.md for the rules.",
            file=sys.stderr,
        )
        return 1

    print("Solutions-library structure check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
