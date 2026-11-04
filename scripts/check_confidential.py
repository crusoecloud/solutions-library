#!/usr/bin/env python3
"""Fail on deny-list matches (internal URLs, confidential markers, staff emails).

Scans the files an MR changed (BASE_SHA / CI_MERGE_REQUEST_DIFF_BASE_SHA), or the
whole tree when run outside an MR. Patterns live in confidential_denylist.txt.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

from changes import changed_files

DENYLIST = Path(__file__).with_name("confidential_denylist.txt")
# The checks themselves quote the terms they look for; CODEOWNERS reviews changes to scripts/.
SKIP_PREFIX = "scripts/"


def load_patterns(path: Path) -> list[re.Pattern]:
    lines = (ln.strip() for ln in path.read_text().splitlines())
    return [re.compile(ln, re.IGNORECASE) for ln in lines if ln and not ln.startswith("#")]


def all_files(root: Path) -> list[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        out += [str(Path(dirpath, f).relative_to(root)) for f in filenames]
    return out


def scan(root: Path, files: list[str], patterns: list[re.Pattern]) -> list[str]:
    hits = []
    for rel in files:
        path = root / rel
        if rel.startswith(SKIP_PREFIX) or not path.is_file():
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue  # binary
        for n, line in enumerate(text.splitlines(), 1):
            for pat in patterns:
                if pat.search(line):
                    hits.append(f"{rel}:{n}: matches /{pat.pattern}/")
    return hits


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args(argv)
    files = changed_files(args.root)
    hits = scan(args.root, all_files(args.root) if files is None else files, load_patterns(DENYLIST))
    for h in hits:
        print(f"FAIL {h}")
    if not hits:
        print("confidential check passed")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
