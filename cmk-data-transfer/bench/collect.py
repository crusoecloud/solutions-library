#!/usr/bin/env python3
"""Throughput collector.

Polls each worker pod's rclone remote-control endpoint (core/stats) and records
cumulative bytes + instantaneous speed per pod and in aggregate to a CSV, so we
can plot the throughput-over-time curve and find the saturation knee.

Each worker runs rclone with `--rc --rc-addr localhost:5572 --rc-no-auth`, so we
query it from inside the pod:
    kubectl exec <pod> -- rclone rc core/stats --rc-addr localhost:5572

Usage:
    python3 bench/collect.py --namespace default --interval 10 \
        --out bench/results/run.csv [--max-seconds 600]
Stops when all worker pods have completed, or --max-seconds elapses.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import time

WORKER_LABEL = "cmk-data-transfer-worker"


def _kubectl(ns, *args, check=True):
    return subprocess.run(["kubectl", "-n", ns, *args],
                          capture_output=True, text=True, check=check)


def list_workers(ns: str) -> list[dict]:
    out = _kubectl(ns, "get", "pods", "-l", f"app={WORKER_LABEL}",
                   "-o", "json").stdout
    return json.loads(out).get("items", [])


def rc_port(pod: dict) -> str:
    """Each worker binds a unique rc port (RC_PORT env); default 5572."""
    for c in pod.get("spec", {}).get("containers", []):
        for e in c.get("env", []):
            if e.get("name") == "RC_PORT" and e.get("value"):
                return e["value"]
    return "5572"


def pod_stats(ns: str, pod: str, port: str) -> dict | None:
    """Return rclone core/stats dict, or None if rc not reachable yet."""
    r = _kubectl(ns, "exec", pod, "--", "rclone", "rc", "core/stats",
                 "--rc-addr", f"localhost:{port}", check=False)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--namespace", default="default")
    p.add_argument("--interval", type=int, default=10)
    p.add_argument("--out", default="bench/results/throughput.csv")
    p.add_argument("--max-seconds", type=int, default=0,
                   help="0 = run until all workers complete")
    args = p.parse_args(argv)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    t0 = time.time()
    rows = []
    peak_aggr = 0.0

    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["elapsed_s", "pod", "bytes", "speed_Bps",
                    "transfers", "errors", "aggregate_GBps"])

        while True:
            elapsed = time.time() - t0
            pods = list_workers(args.namespace)
            if not pods:
                print("no worker pods found; exiting")
                break

            active = 0
            aggr_speed = 0.0
            sample = []
            for pod in pods:
                name = pod["metadata"]["name"]
                phase = pod["status"]["phase"]
                if phase not in ("Succeeded", "Failed"):
                    active += 1
                st = pod_stats(args.namespace, name, rc_port(pod))
                if st is None:
                    continue
                speed = float(st.get("speed", 0.0))
                aggr_speed += speed
                sample.append((name, int(st.get("bytes", 0)), speed,
                               int(st.get("transfers", 0)),
                               int(st.get("errors", 0))))

            aggr_gbps = aggr_speed / 1e9
            peak_aggr = max(peak_aggr, aggr_gbps)
            for name, b, speed, tr, errs in sample:
                w.writerow([f"{elapsed:.1f}", name, b, f"{speed:.0f}",
                            tr, errs, f"{aggr_gbps:.3f}"])
                rows.append(aggr_gbps)
            fh.flush()

            print(f"[{elapsed:6.0f}s] active={active} "
                  f"aggregate={aggr_gbps:6.3f} GB/s  peak={peak_aggr:6.3f} GB/s")

            if active == 0:
                print("all workers complete")
                break
            if args.max_seconds and elapsed >= args.max_seconds:
                print("max-seconds reached")
                break
            time.sleep(args.interval)

    # summary
    sustained = sorted(rows)[len(rows) // 2] if rows else 0.0
    print("\n--- summary ---")
    print(f"  peak aggregate     : {peak_aggr:.3f} GB/s")
    print(f"  median aggregate   : {sustained:.3f} GB/s")
    print(f"  csv                : {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
