#!/usr/bin/env python3
"""Parameter sweep over (transfers, multi-thread-streams, pods).

For each grid point it launches the worker fleet with those rclone settings
against a BOUNDED sample of the source, records the throughput curve via
collect.py, tears the fleet down, and appends peak/median aggregate GB/s to a
results CSV. The goal is to find the saturation knee and identify the binding
constraint (network vs VAST write ceiling vs OCI request throttling).

COST WARNING: each grid point re-downloads the sample (OCI egress is billed).
Keep --sample-prefix small and --max-seconds short. Requires --yes.

Prereqs: run the main orchestrator once (or this with --do-list) so the Secret,
PVC, and master pod exist and the sample is listed+sharded.

Usage:
    python3 bench/sweep.py --yes \
        --sample-prefix smoke-set/ \
        --transfers-grid 16,32,48 \
        --mts-grid 4,8 \
        --pods-grid 4 \
        --max-seconds 120 \
        --out bench/results/sweep.csv
"""
from __future__ import annotations

import argparse
import copy
import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from shard import shard_manifest                       # noqa: E402
from orchestrator import manifests                      # noqa: E402
from orchestrator.config import load_config             # noqa: E402
from orchestrator.k8s import Kubectl                     # noqa: E402
from orchestrator.rclone_conf import build_s3_compat_conf  # noqa: E402
from orchestrator.sizing import compute_sizing           # noqa: E402

from bench import collect  # noqa: E402


def _grid(s: str) -> list[int]:
    return [int(x) for x in s.split(",") if x.strip()]


def ensure_base(cfg, kc: Kubectl, do_list: bool) -> None:
    """Make sure Secret / PVC / master pod exist; optionally (re)list+shard."""
    kc.create_secret_from_files(
        cfg.secret_name, {"rclone.conf": build_s3_compat_conf(cfg)})
    kc.apply(manifests.pvc(cfg))
    if not kc.exists("pod", cfg.master_pod_name):
        kc.apply(manifests.master_pod(cfg))
        kc.wait_ready(cfg.master_pod_name)
    if do_list:
        listing = f"{cfg.mount_root}/listing.tsv"
        lsf = ("SEP=$(printf '\\t'); rclone lsf --recursive --files-only "
               "--format sp --separator \"$SEP\" --config /config/rclone.conf "
               f"{cfg.remote_root()} > {listing}")
        kc.exec(cfg.master_pod_name, ["/bin/sh", "-c", lsf])


def reshard(cfg, kc: Kubectl, num_pods: int, run_dir: str) -> None:
    """Re-bin-pack the existing listing into num_pods shards and push them."""
    listing = f"{cfg.mount_root}/listing.tsv"
    local = os.path.join(run_dir, "listing.tsv")
    with open(local, "wb") as fh:
        fh.write(kc.exec(cfg.master_pod_name, ["cat", listing]).stdout or b"")
    with open(local) as fh:
        objects = list(shard_manifest.parse_tsv(fh))
    bins, _ = shard_manifest.bin_pack(objects, num_pods)
    files = shard_manifest.write_shards(bins, os.path.join(run_dir, "shards"))
    # clear old shards then push new
    kc.exec(cfg.master_pod_name,
            ["/bin/sh", "-c", f"rm -f {manifests.shard_dir(cfg)}/shard-*.txt"])
    for fp in files:
        kc.cp_to(cfg.master_pod_name, fp,
                 f"{manifests.shard_dir(cfg)}/{os.path.basename(fp)}")


def run_point(cfg, kc, transfers, mts, ppn, dest, max_seconds, csv_path):
    c = copy.deepcopy(cfg)
    c.rclone_transfers = transfers
    c.rclone_multi_thread_streams = mts
    c.pods_per_node = ppn
    c.num_pods = None
    c.dest_path = dest
    sizing = compute_sizing(c)
    total = sizing.total_pods

    print(f"\n>>> point T={transfers} MTS={mts} pods/node={ppn} "
          f"({total} pods) dest={dest}")
    for i in range(total):
        kc.apply(manifests.worker_pod(c, sizing, i))

    # collect throughput for this point
    pt_csv = csv_path.replace(".csv", f".T{transfers}_s{mts}_ppn{ppn}.csv")
    collect.main([
        "--namespace", c.k8s_namespace,
        "--interval", "10",
        "--out", pt_csv,
        "--max-seconds", str(max_seconds),
    ])

    # parse peak/median from the per-point csv
    peak, vals = 0.0, []
    with open(pt_csv) as fh:
        for row in csv.DictReader(fh):
            g = float(row["aggregate_GBps"])
            peak = max(peak, g)
            vals.append(g)
    median = sorted(vals)[len(vals) // 2] if vals else 0.0

    kc.delete("pod", selector=f"app={manifests.WORKER_LABEL}", wait=True)
    return peak, median, sizing.in_flight_per_node * c.num_nodes


def main(argv=None) -> int:
    # Config comes from env/.env; this tool owns its own CLI grid flags, so we
    # do NOT route argv through the orchestrator's strict parser.
    cfg, _ = load_config([])
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--transfers-grid", default="16,32,48")
    p.add_argument("--mts-grid", default="4,8")
    p.add_argument("--pods-per-node-grid", default="2,4,8",
                   help="sweep workers-per-node (the new throughput lever)")
    p.add_argument("--sample-prefix", default=None,
                   help="override OCI_PREFIX with a small sample subdir")
    p.add_argument("--max-seconds", type=int, default=120)
    p.add_argument("--out", default="bench/results/sweep.csv")
    p.add_argument("--do-list", action="store_true",
                   help="(re)list the source before sweeping")
    p.add_argument("--yes", action="store_true")
    # parse only our flags; cfg already built from env/.env
    args, _unknown = p.parse_known_args(argv)

    if not args.yes:
        print("Refusing to run without --yes (each point bills OCI egress).")
        return 2
    if args.sample_prefix is not None:
        cfg.prefix = args.sample_prefix

    import tempfile
    run_dir = tempfile.mkdtemp(prefix="cmk-sweep-")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    kc = Kubectl(namespace=cfg.k8s_namespace, dry_run=False)

    ensure_base(cfg, kc, do_list=args.do_list)

    results = []
    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["transfers", "mts", "pods_per_node", "total_pods",
                    "fleet_streams", "peak_GBps", "median_GBps"])
        for ppn in _grid(args.pods_per_node_grid):
            total = cfg.num_nodes * ppn
            reshard(cfg, kc, total, run_dir)
            for mts in _grid(args.mts_grid):
                for t in _grid(args.transfers_grid):
                    dest = f"{cfg.mount_root}/sweep/T{t}_s{mts}_ppn{ppn}"
                    peak, med, streams = run_point(
                        cfg, kc, t, mts, ppn, dest, args.max_seconds, args.out)
                    w.writerow([t, mts, ppn, total, streams,
                                f"{peak:.3f}", f"{med:.3f}"])
                    fh.flush()
                    results.append((t, mts, ppn, peak))
                    print(f"    => peak {peak:.3f} GB/s, median {med:.3f} GB/s")
                    time.sleep(5)

    results.sort(key=lambda r: r[3], reverse=True)
    print("\n--- sweep summary (top by peak) ---")
    for t, mts, ppn, peak in results[:5]:
        print(f"  T={t:>3} MTS={mts:>2} pods/node={ppn:>2}  peak {peak:.3f} GB/s")
    print(f"  full results: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
