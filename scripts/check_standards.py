#!/usr/bin/env python3
"""Per-solution standards from STANDARDS.md, on top of check_solutions_structure.py.

Violations a solution already had when the baseline was written are tolerated
until the solution is touched by an MR; then every violation must be fixed.
New solutions get no grace. Repo-level files are always required.

  check_standards.py                  check (uses BASE_SHA / CI_MERGE_REQUEST_DIFF_BASE_SHA)
  check_standards.py --write-baseline record today's violations as grandfathered
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

import check_solutions_structure as layout
from changes import changed_files

ROOT_FILES = ("LICENSE", "CONTRIBUTING.md", "README.md")
BANNED_FILES = {"claude.md", "agents.md", "gemini.md", ".cursorrules", ".windsurfrules", "copilot-instructions.md"}
BANNED_DIRS = {".claude", ".cursor"}
# Section name -> H2 titles that satisfy it (lowercased).
REQUIRED_SECTIONS = {
    "prerequisites": {"prerequisites", "requirements"},
    "quick start": {"quick start", "quickstart", "usage", "installation", "getting started"},
}
NON_ARTIFACT_SUFFIXES = {".md", ".png", ".jpg", ".jpeg", ".gif", ".svg"}
H2_RE = re.compile(r"^##\s+(.+?)\s*#*\s*$", re.MULTILINE)
BASELINE = Path(__file__).with_name("standards_baseline.json")


def touched_solutions(changed: list[str], solutions: list[str]) -> set[str]:
    return {s for s in solutions if any(p.startswith(s + "/") for p in changed)}


def solution_violations(sol: Path) -> set[str]:
    found: set[str] = set()
    has_artifact = False
    for dirpath, dirnames, filenames in os.walk(sol):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for d in dirnames:
            if d.lower() in BANNED_DIRS:
                found.add(f"banned-file:{Path(dirpath, d).relative_to(sol)}/")
        for f in filenames:
            rel = Path(dirpath, f).relative_to(sol)
            if f.lower() in BANNED_FILES:
                found.add(f"banned-file:{rel}")
            # shortcut: any non-markdown file counts, so one stub file passes; add a size/type floor if abused.
            elif Path(f).suffix.lower() not in NON_ARTIFACT_SUFFIXES and f not in {"LICENSE", ".gitignore"}:
                has_artifact = True
    if not has_artifact:
        found.add("no-artifacts")
    readme = sol / "README.md"
    if not readme.is_file():
        found.add("missing-readme")
    else:
        titles = {t.lower() for t in H2_RE.findall(readme.read_text(errors="replace"))}
        for name, accepted in REQUIRED_SECTIONS.items():
            if not titles & accepted:
                found.add(f"missing-section:{name}")
    return found


def enforced(name: str, found: set[str], baseline: dict[str, list[str]], touched: set[str]) -> set[str]:
    if name in baseline and name not in touched:
        return found - set(baseline[name])
    return found


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write-baseline", action="store_true")
    args = ap.parse_args(argv)
    root = layout.REPO_ROOT

    solutions = layout.solution_dirs()
    all_found = {s: solution_violations(root / s) for s in solutions}
    if args.write_baseline:
        BASELINE.write_text(json.dumps({k: sorted(v) for k, v in all_found.items() if v}, indent=2) + "\n")
        print(f"wrote {BASELINE} ({sum(1 for v in all_found.values() if v)} solutions grandfathered)")
        return 0

    baseline = json.loads(BASELINE.read_text()) if BASELINE.is_file() else {}
    changed = changed_files(root)
    touched = touched_solutions(changed or [], solutions)

    errors = [f"{f}: missing repo-level file" for f in ROOT_FILES if not (root / f).is_file()]
    for name, found in all_found.items():
        for v in sorted(enforced(name, found, baseline, touched)):
            errors.append(f"{name}: {v}" + (" (grandfathered, but this MR touches it)" if name in baseline and name in touched else ""))
    for e in errors:
        print(f"FAIL {e}")
    if not errors:
        print("standards check passed")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
