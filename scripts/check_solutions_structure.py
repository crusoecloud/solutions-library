#!/usr/bin/env python3
"""Enforce the repo-structure rules from CONTRIBUTING.md:

  1. Every top-level solution directory has a README.md.
  2. Every top-level solution directory is linked from the root README.md.
  3. Every root-README link that points at a top-level directory resolves
     to a directory that actually exists.

Run from anywhere; paths are resolved relative to the repo root (this
script's parent's parent directory).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ROOT_README = REPO_ROOT / "README.md"

# Top-level entries that are not independent solutions and are exempt from
# the "has a README" / "linked from root README" rules.
NON_SOLUTION_DIRS = {"assets", "scripts"}

# Directory names (not paths) that are known-missing from the root README
# today. New entries must NOT be added here — this is a closing door, not
# an escape hatch. Remove a name once its root-README entry is added.
GRANDFATHERED_UNLINKED: set[str] = set()

LINK_RE = re.compile(r"\]\(\./([^)#]+?)/?\)")


def top_level_solution_dirs() -> list[str]:
    return sorted(
        p.name
        for p in REPO_ROOT.iterdir()
        if p.is_dir()
        and not p.name.startswith(".")
        and p.name not in NON_SOLUTION_DIRS
    )


def linked_dir_names(readme_text: str) -> set[str]:
    """Top-level directory names referenced by relative links in the root
    README — e.g. "foo" or "foo/README.md" both count as linking "foo".
    Links straight at a root-level file ("CONTRIBUTING.md", "CODEOWNERS")
    are not directory references and are skipped.
    """
    names = set()
    for match in LINK_RE.finditer(readme_text):
        target = match.group(1)
        parts = target.split("/")
        first_segment = parts[0]
        if len(parts) == 1 and (REPO_ROOT / first_segment).is_file():
            continue  # bare root-level file link, e.g. ./CONTRIBUTING.md
        names.add(first_segment)
    return names


def main() -> int:
    if not ROOT_README.is_file():
        print(f"ERROR: root README not found at {ROOT_README}", file=sys.stderr)
        return 1

    readme_text = ROOT_README.read_text(encoding="utf-8")
    linked = linked_dir_names(readme_text)

    errors = []

    for name in top_level_solution_dirs():
        solution_dir = REPO_ROOT / name

        if not (solution_dir / "README.md").is_file():
            errors.append(
                f"{name}/: missing README.md — every solution directory needs one "
                f"(see CONTRIBUTING.md)"
            )

        if name not in linked and name not in GRANDFATHERED_UNLINKED:
            errors.append(
                f"{name}/: not linked from the root README.md — add an entry under "
                f"the relevant ## Solutions category (see CONTRIBUTING.md)"
            )

    # Any link into a top-level dir should resolve to a real directory.
    all_dirs = set(top_level_solution_dirs()) | NON_SOLUTION_DIRS
    for name in sorted(linked):
        if name not in all_dirs:
            errors.append(
                f"README.md links to './{name}' but no such top-level directory exists "
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
