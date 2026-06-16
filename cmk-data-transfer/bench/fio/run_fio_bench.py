#!/usr/bin/env python3
"""Drive the fio disk benchmark across every s2a node and save results.

Renders bench/fio/fio-bench-job.yaml (one fio pod per node via hostname
anti-affinity), applies it, waits for completion, then pulls each pod's fio JSON
and a parsed summary into bench/results/fio-<timestamp>/ (git-ignored).

Usage:
    python3 bench/fio/run_fio_bench.py [--pvc cmk-data-transfer-nfs]
        [--size 10G] [--jobs 4] [--direct 1] [--instance-class s2a]
        [--namespace default] [--image alpine:3.20] [--timeout 1200]

Safe: writes only under /data/_fiobench/<node>/ on the PVC and cleans up. No OCI
egress (VAST I/O is in-region).
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import time

LABEL = "cmk-fio-bench"
JOB = "cmk-fio-bench"
HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "fio-bench-job.yaml")
RESULTS_ROOT = os.path.join(HERE, "..", "results")


def kubectl(ns, *args, check=True, input_str=None):
    return subprocess.run(["kubectl", "-n", ns, *args], capture_output=True,
                          text=True, check=check, input=input_str)


def schedulable_nodes(instance_class: str) -> list[str]:
    out = subprocess.run(
        ["kubectl", "get", "nodes", "-l",
         f"crusoe.ai/instance.class={instance_class}", "-o", "json"],
        capture_output=True, text=True, check=True).stdout
    names = []
    for n in json.loads(out).get("items", []):
        conds = {c["type"]: c["status"] for c in
                 n.get("status", {}).get("conditions", [])}
        if conds.get("Ready") == "True" and not n["spec"].get("unschedulable"):
            names.append(n["metadata"]["name"])
    return names


def render(values: dict) -> str:
    text = open(MANIFEST).read()
    for k, v in values.items():
        text = text.replace("${%s}" % k, str(v))  # braced placeholders only
    return text


def parse_fio(blob: str) -> list[dict]:
    """Return per-profile rows from one pod's fio JSON."""
    start = blob.find("{")
    if start < 0:
        return []
    try:
        data = json.loads(blob[start:])
    except json.JSONDecodeError:
        return []
    rows = []
    for job in data.get("jobs", []):
        name = job.get("jobname", "?")
        side = job.get("write" if "write" in name else "read", {})
        bw_bytes = side.get("bw_bytes") or (side.get("bw", 0) * 1024)
        rows.append({
            "profile": name,
            "bw_MBps": round(bw_bytes / 1e6, 1),
            "iops": round(side.get("iops", 0.0)),
            "lat_ms": round(side.get("lat_ns", {}).get("mean", 0) / 1e6, 3),
        })
    return rows


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--pvc", default="cmk-data-transfer-nfs")
    p.add_argument("--size", default="4G", help="fio file size PER JOB")
    p.add_argument("--jobs", default="16", help="fio parallel jobs per node "
                   "(raise to saturate the NIC)")
    p.add_argument("--iodepth", default="32", help="async queue depth per job")
    p.add_argument("--runtime", default="30", help="seconds per phase (time_based)")
    p.add_argument("--direct", default="1", choices=("0", "1"))
    p.add_argument("--instance-class", default="s2a")
    p.add_argument("--namespace", default="default")
    p.add_argument("--image", default="alpine:3.20")
    p.add_argument("--timeout", type=int, default=1200)
    p.add_argument("--stuck-grace", type=int, default=240,
                   help="once running pods finish, wait this long for stuck "
                        "(Pending/FailedMount) pods before collecting anyway")
    p.add_argument("--collect-only", action="store_true",
                   help="skip apply/wait; just collect from the existing job")
    args = p.parse_args(argv)
    ns = args.namespace

    nodes = schedulable_nodes(args.instance_class)
    if not nodes:
        print(f"no schedulable {args.instance_class} nodes", file=sys.stderr)
        return 2
    n = len(nodes)
    print(f"Benchmarking {n} {args.instance_class} nodes against PVC "
          f"{args.pvc} (jobs={args.jobs} iodepth={args.iodepth} "
          f"size/job={args.size} runtime={args.runtime}s direct={args.direct})")
    for nd in nodes:
        print(f"  - {nd}")

    manifest = render({
        "INSTANCE_CLASS": args.instance_class, "PVC_NAME": args.pvc,
        "COMPLETIONS": n, "PARALLELISM": n, "IMAGE": args.image,
        "FIO_SIZE": args.size, "FIO_JOBS": args.jobs,
        "FIO_IODEPTH": args.iodepth, "FIO_RUNTIME": args.runtime,
        "FIO_DIRECT": args.direct,
    })

    final = "collect-only"
    if not args.collect_only:
        kubectl(ns, "delete", "job", JOB, "--ignore-not-found", "--now",
                check=False)
        kubectl(ns, "apply", "-f", "-", input_str=manifest)
        print("job applied; waiting for completion (fio runs 4 profiles/node)...")
        # Poll pod phases. Break when all pods are terminal, or when the only
        # non-terminal pods are stuck (Pending, e.g. FailedMount) and nothing is
        # still running — so one bad node can't hang the whole benchmark.
        t0 = time.time()
        final = None
        while time.time() - t0 < args.timeout:
            pods = json.loads(kubectl(ns, "get", "pods", "-l",
                              f"app={LABEL}", "-o", "json").stdout)["items"]
            ph = [p["status"]["phase"] for p in pods]
            succ = ph.count("Succeeded")
            fail = ph.count("Failed")
            running = ph.count("Running")
            pending = ph.count("Pending")
            el = int(time.time() - t0)
            print(f"  [{el:4d}s] succeeded={succ}/{n} running={running} "
                  f"pending={pending} failed={fail}")
            if succ + fail >= n and len(pods) >= n:
                final = "complete" if succ >= n else "partial"
                break
            if (running == 0 and pending > 0 and succ + fail > 0
                    and el > args.stuck_grace):
                final = "partial"
                print(f"  {pending} pod(s) stuck (likely FailedMount); "
                      "collecting the rest")
                break
            time.sleep(15)
        if final is None:
            final = "timeout"
            print("timed out waiting for job", file=sys.stderr)

    # collect results
    ts = time.strftime("%Y%m%d-%H%M%S")
    outdir = os.path.abspath(os.path.join(RESULTS_ROOT, f"fio-{ts}"))
    os.makedirs(outdir, exist_ok=True)
    pods = json.loads(kubectl(ns, "get", "pods", "-l", f"app={LABEL}",
                              "-o", "json").stdout)["items"]
    summary = []
    for pod in pods:
        name = pod["metadata"]["name"]
        node = pod["spec"].get("nodeName", "?")
        blob = kubectl(ns, "logs", name, check=False).stdout or ""
        with open(os.path.join(outdir, f"{node}.json"), "w") as fh:
            fh.write(blob)
        for row in parse_fio(blob):
            row["node"] = node
            summary.append(row)

    # write summary CSV
    csv_path = os.path.join(outdir, "summary.csv")
    with open(csv_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["node", "profile", "bw_MBps",
                                           "iops", "lat_ms"])
        w.writeheader()
        for r in sorted(summary, key=lambda x: (x["profile"], x["node"])):
            w.writerow({k: r[k] for k in w.fieldnames})

    # aggregate + print
    print(f"\n=== results -> {outdir} ===")
    if not summary:
        print("  no fio output parsed (check the per-node .json files)")
        return 1
    profiles = ["seqwrite", "seqread", "randwrite", "randread"]
    print(f"  {'profile':10}  {'aggregate':>14}  {'per-node avg':>14}  nodes")
    for prof in profiles:
        rows = [r for r in summary if r["profile"] == prof]
        if not rows:
            continue
        if prof.startswith("seq"):
            agg = sum(r["bw_MBps"] for r in rows) / 1000.0  # GB/s
            avg = agg / len(rows)
            print(f"  {prof:10}  {agg:9.2f} GB/s  {avg:9.2f} GB/s  {len(rows)}")
        else:
            agg = sum(r["iops"] for r in rows)
            avg = agg / len(rows)
            print(f"  {prof:10}  {agg:11.0f} IOPS  {avg:11.0f} IOPS  {len(rows)}")
    covered = {r["node"] for r in summary}
    missing = [nd for nd in nodes if nd not in covered]
    print(f"\n  nodes with results: {len(covered)}/{n}")
    if missing:
        print("  MISSING (mount/run failed — see describe/CSI logs):")
        for nd in missing:
            print(f"    - {nd}")
    print(f"  per-node detail + raw fio JSON in {outdir}")
    print(f"  summary CSV: {csv_path}")

    if not args.collect_only:
        kubectl(ns, "delete", "job", JOB, "--ignore-not-found", "--now",
                check=False)
    return 0 if final == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
