#!/usr/bin/env python3
"""VAST write-ceiling preflight.

Launches one fio pod per s2a node (anti-affinity on hostname), each doing a
sequential buffered write to the shared RWX PVC, then sums per-pod write
bandwidth into an aggregate. This establishes the destination write ceiling so a
later download plateau can be attributed correctly (VAST vs NIC vs OCI).

Safe to run before the big pull — it only writes to /data/fio and is cleaned up.

Usage:
    python3 preflight/run_fio.py --nodes 4 --size 20G --jobs 8 --bs 4M
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from orchestrator.config import load_config  # noqa: E402

LABEL = "cmk-data-transfer-fio"


def kc(ns, *args, check=True, capture=True):
    return subprocess.run(["kubectl", "-n", ns, *args],
                          capture_output=capture, text=True, check=check)


def fio_pod(cfg, index, size, jobs, bs, direct):
    # direct=1 (O_DIRECT) bypasses the page cache so we measure the real VAST
    # write path, not RAM. end_fsync=1 forces a flush so the reported bandwidth
    # reflects bytes durably on VAST. If the mount rejects O_DIRECT, rerun with
    # --direct 0 (buffered) and a size well above node RAM.
    cmd = (
        "apk add --no-cache fio >/dev/null && "
        "mkdir -p /data/fio/$(hostname) && "
        f"fio --name=vastwrite --directory=/data/fio/$(hostname) "
        f"--rw=write --bs={bs} --size={size} --numjobs={jobs} "
        f"--ioengine=libaio --iodepth=32 --direct={direct} --end_fsync=1 "
        "--group_reporting --output-format=json"
    )
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": f"{LABEL}-{index}", "namespace": cfg.k8s_namespace,
                     "labels": {"app": LABEL}},
        "spec": {
            "restartPolicy": "Never",
            "nodeSelector": {"crusoe.ai/instance.class": cfg.instance_class},
            "affinity": {"podAntiAffinity": {
                "requiredDuringSchedulingIgnoredDuringExecution": [{
                    "labelSelector": {"matchLabels": {"app": LABEL}},
                    "topologyKey": "kubernetes.io/hostname"}]}},
            "containers": [{
                "name": "fio", "image": "alpine:3.20",
                "command": ["/bin/sh", "-c", cmd],
                "volumeMounts": [{"name": "shared", "mountPath": "/data"}],
            }],
            "volumes": [{"name": "shared",
                         "persistentVolumeClaim": {"claimName": cfg.pvc_name}}],
        },
    }


def parse_write_bw_bytes(log: str) -> float:
    """Extract aggregate write bw (bytes/s) from fio --output-format=json."""
    # fio may emit apk noise before JSON; find the JSON object.
    start = log.find("{")
    if start < 0:
        return 0.0
    try:
        data = json.loads(log[start:])
    except json.JSONDecodeError:
        return 0.0
    bw = 0.0
    for job in data.get("jobs", []):
        # bw is in KiB/s in fio json
        bw += float(job.get("write", {}).get("bw", 0.0)) * 1024
    return bw


def main(argv=None) -> int:
    # Config from env/.env; this tool owns its own CLI flags.
    cfg, _ = load_config([])
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--nodes", type=int, default=None,
                   help="number of fio pods (default: NUM_NODES)")
    p.add_argument("--size", default="20G", help="per-job file size")
    p.add_argument("--jobs", type=int, default=8, help="fio numjobs per pod")
    p.add_argument("--bs", default="4M", help="block size")
    p.add_argument("--direct", type=int, default=1, choices=(0, 1),
                   help="1=O_DIRECT (true ceiling); 0=buffered (fallback)")
    p.add_argument("--timeout", default="900s")
    args, _ = p.parse_known_args(argv)

    n = args.nodes or cfg.num_nodes
    ns = cfg.k8s_namespace
    print(f"Launching {n} fio pods on {cfg.instance_class} "
          f"(size={args.size} jobs={args.jobs} bs={args.bs} "
          f"direct={args.direct})")

    for i in range(n):
        body = json.dumps(fio_pod(cfg, i, args.size, args.jobs, args.bs,
                                  args.direct))
        subprocess.run(["kubectl", "-n", ns, "apply", "-f", "-"],
                       input=body, text=True, check=True)

    # wait for all to complete (Succeeded/Failed)
    print("waiting for fio pods to finish...")
    while True:
        pods = json.loads(kc(ns, "get", "pods", "-l", f"app={LABEL}",
                             "-o", "json").stdout)["items"]
        pending = [p["metadata"]["name"] for p in pods
                   if p["status"]["phase"] not in ("Succeeded", "Failed")]
        if not pending:
            break
        time.sleep(10)

    total = 0.0
    print("\n--- per-node write bandwidth ---")
    for p in pods:
        name = p["metadata"]["name"]
        log = kc(ns, "logs", name, check=False).stdout or ""
        bw = parse_write_bw_bytes(log)
        total += bw
        print(f"  {name}: {bw/1e9:.2f} GB/s")
    print(f"\nVAST aggregate write ceiling (this fleet): {total/1e9:.2f} GB/s")
    print(f"  => download throughput cannot durably exceed this. Compare to "
          f"TARGET_GBPS={cfg.target_gbps}.")

    # cleanup
    subprocess.run(["kubectl", "-n", ns, "delete", "pod", "-l",
                    f"app={LABEL}", "--ignore-not-found"], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
