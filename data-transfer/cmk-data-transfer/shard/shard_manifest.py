#!/usr/bin/env python3
"""Deterministic, size-balanced keyspace sharder.

Reads a listing (TSV of "<size>\\t<path>", as produced by
`rclone lsf --recursive --files-only --format sp --separator '\\t'`) and
bin-packs the objects into N balanced shard files using the Longest-Processing-
Time (LPT) greedy multiway partition: sort objects by size descending, then
repeatedly assign the next object to the currently-smallest bin. This is the
same algorithm the Crusoe AWS-S3 reference uses, and it keeps each worker's
total byte load within a small factor of perfectly balanced.

Deterministic: same listing + same N => identical shards (ties broken by path).

Usage (standalone):
    python3 shard_manifest.py --listing listing.tsv --num 4 --out ./shards
Reads stdin if --listing is omitted.
"""
from __future__ import annotations

import argparse
import heapq
import os
import sys
from typing import Iterable, Iterator


def parse_tsv(lines: Iterable[str]) -> Iterator[tuple[int, str]]:
    """Yield (size, path) from 'size\\tpath' lines. Skips blanks/garbage."""
    for raw in lines:
        line = raw.rstrip("\n")
        if not line:
            continue
        size_str, sep, path = line.partition("\t")
        if not sep:
            # tolerate space-separated fallback
            size_str, _, path = line.partition(" ")
        path = path.strip()
        if not path:
            continue
        try:
            size = int(size_str)
        except ValueError:
            continue
        yield size, path


def bin_pack(objects: list[tuple[int, str]], num_bins: int
             ) -> tuple[list[list[str]], list[int]]:
    """LPT greedy partition. Returns (bins_of_paths, bin_total_sizes)."""
    if num_bins < 1:
        raise ValueError("num_bins must be >= 1")
    # sort by size desc, then path asc for determinism
    objects.sort(key=lambda o: (-o[0], o[1]))
    bins: list[list[str]] = [[] for _ in range(num_bins)]
    sizes = [0] * num_bins
    # min-heap of (current_size, bin_index)
    heap = [(0, i) for i in range(num_bins)]
    heapq.heapify(heap)
    for size, path in objects:
        cur, idx = heapq.heappop(heap)
        bins[idx].append(path)
        sizes[idx] = cur + size
        heapq.heappush(heap, (cur + size, idx))
    return bins, sizes


def human(n: int) -> str:
    f = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if f < 1024 or unit == "PiB":
            return f"{f:.2f} {unit}"
        f /= 1024
    return f"{f:.2f} PiB"


def write_shards(bins: list[list[str]], out_dir: str) -> list[str]:
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    for i, keys in enumerate(bins):
        fp = os.path.join(out_dir, f"shard-{i}.txt")
        with open(fp, "w") as fh:
            fh.write("\n".join(keys))
            if keys:
                fh.write("\n")
        paths.append(fp)
    return paths


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--listing", help="TSV file (default: stdin)")
    p.add_argument("--num", type=int, required=True, help="number of shards")
    p.add_argument("--out", default="./shards", help="output directory")
    args = p.parse_args(argv)

    src = open(args.listing) if args.listing else sys.stdin
    try:
        objects = list(parse_tsv(src))
    finally:
        if args.listing:
            src.close()

    if not objects:
        print("ERROR: no objects parsed from listing", file=sys.stderr)
        return 2

    bins, sizes = bin_pack(objects, args.num)
    write_shards(bins, args.out)

    total = sum(sizes)
    print(f"Sharded {len(objects)} objects ({human(total)}) into "
          f"{args.num} shards -> {args.out}")
    for i, (b, s) in enumerate(zip(bins, sizes)):
        print(f"  shard-{i}.txt: {len(b):>8} files  {human(s):>12}")
    spread = (max(sizes) - min(sizes)) / max(1, total) * 100
    print(f"  balance spread (max-min)/total: {spread:.3f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
