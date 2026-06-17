#!/usr/bin/env python3
"""OCI -> VAST transfer experiment: measure sustained pull rate at a given
node/pod concurrency, writing to a DISTINCT destination subfolder per run.

Drives the orchestrator (secret -> PVC/master -> list -> shard -> workers) for a
chosen NUM_NODES with FIXED per-node concurrency, then polls each worker's
rclone rc core/stats to compute the aggregate transfer rate over time. Reports:
  - bytes transferred + wall-clock elapsed
  - average GB/s   (= bytes / elapsed)  <- the headline "how fast did we pull"
  - peak windowed GB/s (steady-state)
  - per-node GB/s, and any OCI throttling (429/503 SlowDown) seen in logs
Time-series + summary saved to bench/results/oci-exp-<label>-<ts>/ (git-ignored).

Each run writes to DEST_PATH=/data/dataset/<label> so it re-pulls the full data
(rclone copy would otherwise skip an already-populated dir).

Usage:
  python3 bench/oci_experiment.py --nodes 1 --label exp-1node
  python3 bench/oci_experiment.py --nodes 1 --label smoke --prefix-override <small/subdir>
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from orchestrator import manifests, run as orun          # noqa: E402
from orchestrator.config import load_config               # noqa: E402
from orchestrator.k8s import Kubectl                       # noqa: E402
from orchestrator.rclone_conf import build_s3_compat_conf  # noqa: E402
from orchestrator.sizing import compute_sizing             # noqa: E402
from bench import collect                                  # noqa: E402

WL = manifests.WORKER_LABEL
GB = 1_000_000_000


def human_gbps(bps: float) -> str:
    return f"{bps / GB:.2f} GB/s"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--nodes", type=int, required=True)
    p.add_argument("--pods-per-node", type=int, default=4)
    p.add_argument("--transfers", type=int, default=12, help="per pod (fixed)")
    p.add_argument("--mts", type=int, default=8, help="multi-thread-streams/pod")
    p.add_argument("--label", required=True, help="dest subfolder + result name")
    p.add_argument("--prefix-override", default=None,
                   help="smaller source prefix for smoke validation")
    p.add_argument("--poll", type=int, default=10)
    p.add_argument("--max-seconds", type=int, default=0,
                   help="time-box: stop after N s (0 = run to completion). "
                        "Bounds egress + skips the straggler tail.")
    p.add_argument("--ramp-seconds", type=int, default=30,
                   help="exclude the first N s from the steady-state average")
    p.add_argument("--stats-sample", type=int, default=6,
                   help="poll rclone rc on at most this many pods per tick "
                        "(bounds overhead at large fleets; 0 = phase-only)")
    p.add_argument("--safety-seconds", type=int, default=7200,
                   help="hard stop for a to-completion run so it can't hang")
    p.add_argument("--keep", action="store_true", help="don't tear down workers")
    args = p.parse_args(argv)

    cfg, _ = load_config([])
    # fixed per-node concurrency; vary only node count
    cfg.num_nodes = args.nodes
    cfg.pods_per_node = args.pods_per_node
    cfg.num_pods = None
    cfg.rclone_transfers = args.transfers
    cfg.rclone_multi_thread_streams = args.mts
    cfg.dest_path = f"{cfg.mount_root}/dataset/{args.label}"   # DISTINCT per run
    if args.prefix_override is not None:
        cfg.prefix = args.prefix_override
    errs = cfg.validate()
    if errs:
        for e in errs:
            print("ERROR:", e, file=sys.stderr)
        return 2

    sizing = compute_sizing(cfg)
    ns = cfg.k8s_namespace
    kc = Kubectl(namespace=ns)
    run_dir = tempfile.mkdtemp(prefix=f"oci-exp-{args.label}-")

    print(f"=== OCI experiment: {args.label} ===")
    print(f"  source : {cfg.remote_root()}")
    print(f"  dest   : {cfg.dest_path}  (PVC {cfg.pvc_name}, nfs)")
    print(f"  fleet  : {cfg.num_nodes} nodes x {sizing.pods_per_node} pods "
          f"= {sizing.total_pods} workers; per-pod T={sizing.transfers} "
          f"MTS={sizing.multi_thread_streams}; {sizing.in_flight_per_node} "
          f"streams/node, {sizing.in_flight_per_node * cfg.num_nodes} fleet")

    # --- setup (reuse orchestrator steps) ---
    orun.preflight(cfg, kc)
    kc.create_secret_from_files(cfg.secret_name,
                                {"rclone.conf": build_s3_compat_conf(cfg)})
    if cfg.is_nfs():
        kc.apply(manifests.nfs_pv(cfg))
    elif cfg.is_import():
        kc.apply(manifests.import_pv(cfg))
    kc.apply(manifests.pvc(cfg))
    # clean slate so a still-terminating master/worker from a prior run can't
    # collide on name when sweeping multiple runs back-to-back
    kc.delete("pod", selector=f"app={WL}", wait=True)
    kc.delete("pod", name=cfg.master_pod_name, wait=True)
    kc.apply(manifests.master_pod(cfg))
    kc.wait_ready(cfg.master_pod_name)
    orun.list_source(cfg, kc)
    expected_bytes = orun.shard_locally(cfg, kc, run_dir)

    # Pin workers to EXACTLY num_nodes specific nodes (nodeName), pods_per_node
    # each — so "node count" is controlled, not left to topology-spread across
    # all available s2a nodes.
    avail = kc.list_ready_nodes(cfg.instance_class)
    if len(avail) < cfg.num_nodes:
        print(f"ERROR: need {cfg.num_nodes} {cfg.instance_class} nodes, "
              f"have {len(avail)}", file=sys.stderr)
        return 2
    chosen = sorted(avail)[:cfg.num_nodes]
    print(f"  pinned nodes ({cfg.num_nodes}): " + ", ".join(
        n.split(".")[0] for n in chosen))
    orun.banner("Launching worker pods (pinned)")
    for i in range(sizing.total_pods):
        pod = manifests.worker_pod(cfg, sizing, i)
        pod["spec"]["nodeName"] = chosen[i % len(chosen)]      # hard pin
        pod["spec"].pop("topologySpreadConstraints", None)     # not needed
        kc.apply(pod)
    print(f"  launched {sizing.total_pods} workers "
          f"({sizing.pods_per_node}/node x {cfg.num_nodes})")

    # --- monitor + collect (byte-delta rate) ---
    out = os.path.abspath(os.path.join(
        os.path.dirname(__file__), "results", f"oci-exp-{args.label}"))
    os.makedirs(out, exist_ok=True)
    ts_csv = os.path.join(out, "timeseries.csv")
    fh = open(ts_csv, "w", newline="")
    w = csv.writer(fh)
    w.writerow(["elapsed_s", "rclone_agg_bytes", "rclone_interval_GBps",
                "nic_interval_GBps", "active_pods"])

    # --- measurement helpers ---
    # (1) rclone-reported bytes: sum core/stats across ALL pods, in parallel.
    #     No sampling/extrapolation (the old 6-pod x len(pods) estimate biased
    #     high because pods[:6] are the fast starters).
    def fleet_bytes(pods):
        names = [(p["metadata"]["name"], collect.rc_port(p)) for p in pods
                 if p["status"]["phase"] == "Running"]
        if not names:
            return 0, 0

        def one(np):
            st = collect.pod_stats(ns, np[0], np[1])
            return int(st.get("bytes", 0)) if st else None
        with ThreadPoolExecutor(max_workers=min(32, len(names))) as ex:
            vals = [v for v in ex.map(one, names) if v is not None]
        return sum(vals), len(vals)

    # (2) GROUND TRUTH: node NIC receive counters. Workers are hostNetwork, so
    #     /proc/net/dev inside a worker reports the NODE's interfaces. One worker
    #     per node; take the busiest non-virtual iface (the physical data NIC).
    _VIRT = ("lo", "veth", "cni", "flannel", "docker", "cali", "lxc", "kube",
             "dummy", "nodelocal", "ovn", "genev", "br-", "tunl", "ip6tnl")

    def node_rx(pod_name):
        try:
            r = kc.exec(pod_name, ["cat", "/proc/net/dev"])
            best = 0
            for line in (r.stdout or b"").decode().splitlines():
                if ":" not in line:
                    continue
                iface, _, rest = line.partition(":")
                if iface.strip().startswith(_VIRT):
                    continue
                cols = rest.split()
                if cols:
                    best = max(best, int(cols[0]))   # cumulative rx_bytes
            return best
        except Exception:  # noqa: BLE001
            return 0

    def fleet_nic_rx(pods):
        reps = {}
        for p in pods:
            n = p["spec"].get("nodeName")
            if n and n not in reps and p["status"]["phase"] == "Running":
                reps[n] = p["metadata"]["name"]
        if not reps:
            return 0
        with ThreadPoolExecutor(max_workers=min(16, len(reps))) as ex:
            return sum(ex.map(node_rx, reps.values()))

    t0 = time.time()
    prev_bytes, prev_t = 0, t0
    prev_nic = None            # cumulative NIC counter baseline (set on tick 1)
    peak = 0.0                 # rclone-reported peak interval
    peak_nic = 0.0             # NIC ground-truth peak interval
    agg_bytes = 0
    nic_delta_total = 0        # bytes seen on the wire since baseline
    steady_rates, nic_steady = [], []
    completed = False
    failed_pods = 0
    print("  --- transferring (rclone rc-stats ALL pods + node NIC counters) ---")
    while True:
        time.sleep(args.poll)
        now = time.time()
        elapsed = now - t0
        pods = kc.get_json("get", "pods", "-l", f"app={WL}").get("items", [])
        active = sum(1 for p in pods
                     if p["status"]["phase"] not in ("Succeeded", "Failed"))
        failed_pods = sum(1 for p in pods if p["status"]["phase"] == "Failed")

        agg_bytes, responded = fleet_bytes(pods)
        nic_now = fleet_nic_rx(pods)
        if prev_nic is None:
            prev_nic = nic_now                       # baseline (cumulative)

        dt = max(0.1, now - prev_t)
        interval_rate = (agg_bytes - prev_bytes) / dt
        nic_rate = (nic_now - prev_nic) / dt if nic_now >= prev_nic else 0.0
        peak = max(peak, interval_rate)
        peak_nic = max(peak_nic, nic_rate)
        nic_delta_total += max(0, nic_now - prev_nic)
        if elapsed >= args.ramp_seconds:
            steady_rates.append(interval_rate)
            nic_steady.append(nic_rate)
        w.writerow([f"{elapsed:.0f}", int(agg_bytes),
                    f"{interval_rate/GB:.3f}", f"{nic_rate/GB:.3f}", active])
        fh.flush()
        print(f"  [{elapsed:6.0f}s] rclone {agg_bytes/1e12:5.2f} TB  "
              f"rclone~{human_gbps(interval_rate)}  NIC~{human_gbps(nic_rate)}  "
              f"act={active}/{sizing.total_pods} resp={responded} fail={failed_pods}")
        prev_bytes, prev_nic, prev_t = agg_bytes, nic_now, now
        if active == 0 and pods:
            completed = (failed_pods == 0)
            break
        if args.max_seconds and elapsed >= args.max_seconds:
            print(f"  time-box {args.max_seconds}s reached; stopping")
            break
        if elapsed >= args.safety_seconds:
            print(f"  SAFETY cap {args.safety_seconds}s reached; stopping")
            break
    fh.close()
    elapsed = time.time() - t0

    # transferred bytes = rclone rc-stats sum across ALL pods (actual downloaded
    # bytes). NOT `rclone size`, which counts in-flight sparse multi-thread files
    # at full allocated size and overstates the total.
    total_bytes = int(agg_bytes)
    total_time = elapsed
    pct = 100.0 * total_bytes / max(1, expected_bytes)
    avg = total_bytes / max(0.1, total_time)
    steady = (sorted(steady_rates)[len(steady_rates) // 2]
              if steady_rates else avg)
    # NIC ground truth (independent of rclone's self-report)
    nic_avg = nic_delta_total / max(0.1, total_time)
    nic_steady_med = (sorted(nic_steady)[len(nic_steady) // 2]
                      if nic_steady else nic_avg)

    # throttling / errors from worker logs
    throttle = 0
    for pod in kc.get_json("get", "pods", "-l", f"app={WL}").get("items", []):
        log = kc.logs(pod["metadata"]["name"], tail=2000)
        for sig in ("SlowDown", " 429 ", " 503 ", "RequestThrottled"):
            throttle += log.count(sig)

    summary = {
        "label": args.label, "nodes": cfg.num_nodes,
        "pods_per_node": sizing.pods_per_node, "total_pods": sizing.total_pods,
        "per_pod_transfers": sizing.transfers,
        "per_pod_mts": sizing.multi_thread_streams,
        "streams_per_node": sizing.in_flight_per_node,
        "completed": completed, "failed_pods": failed_pods,
        "expected_bytes": expected_bytes, "transferred_bytes": total_bytes,
        "pct_complete": round(pct, 1),
        "total_transfer_time_s": round(total_time, 1),
        "avg_GBps": round(avg / GB, 3),                 # rclone-reported
        "avg_GBps_per_node": round(avg / GB / cfg.num_nodes, 3),
        "steady_GBps": round(steady / GB, 3),
        "peak_GBps": round(peak / GB, 3),
        "nic_avg_GBps": round(nic_avg / GB, 3),         # GROUND TRUTH: node NIC rx
        "nic_avg_GBps_per_node": round(nic_avg / GB / cfg.num_nodes, 3),
        "nic_steady_GBps": round(nic_steady_med / GB, 3),
        "nic_peak_GBps": round(peak_nic / GB, 3),
        "throttle_signals": throttle,
    }
    with open(os.path.join(out, "summary.json"), "w") as sfh:
        json.dump(summary, sfh, indent=2)

    print("\n=== RESULT ===")
    status = "COMPLETE" if completed else f"capped/partial (failed={failed_pods})"
    mins = total_time / 60
    print(f"  status            : {status}  ({pct:.1f}% of bucket on disk)")
    print(f"  TOTAL TRANSFER TIME: {total_time:.0f}s ({mins:.1f} min) for "
          f"{total_bytes/1e12:.3f} TB")
    print(f"  rclone  avg/steady/peak: {avg/GB:.2f} / {steady/GB:.2f} / "
          f"{peak/GB:.2f} GB/s")
    print(f"  NIC     avg/steady/peak: {nic_avg/GB:.2f} / {nic_steady_med/GB:.2f} / "
          f"{peak_nic/GB:.2f} GB/s  <- GROUND TRUTH "
          f"({nic_avg/GB/cfg.num_nodes:.2f} GB/s/node)")
    print(f"  OCI throttle signals: {throttle}")
    print(f"  -> {out}/summary.json , timeseries.csv")

    if not args.keep:
        kc.delete("pod", selector=f"app={WL}", wait=True)
        kc.delete("pod", name=cfg.master_pod_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
