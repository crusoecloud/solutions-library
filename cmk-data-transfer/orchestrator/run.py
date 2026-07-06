"""Orchestrator entrypoint.

Pipeline:
  1. load config + compute sizing (BDP-grounded)               [always]
  2. preflight: kubectl reachable, enough s2a nodes, StorageClass present
  3. create K8s Secret (rclone.conf) — creds only live in-cluster
  4. apply PVC (RWX VAST) + master pod
  5. list source via `rclone lsf` (in master pod) -> /data/listing.tsv
  6. pull listing, shard locally (LPT bin-pack), push shard files back
  7. CONFIRM, then launch N pinned worker pods (the large transfer)
  8. monitor to completion
  9. teardown (unless --keep)

Run:  python -m orchestrator.run   [flags]
"""
from __future__ import annotations

import os
import sys
import tempfile
import time

# allow `from shard import shard_manifest` when run from repo root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from shard import shard_manifest  # noqa: E402

from . import manifests  # noqa: E402
from .config import load_config  # noqa: E402
from .k8s import Kubectl, die  # noqa: E402
from .rclone_conf import build_s3_compat_conf  # noqa: E402
from .sizing import compute_sizing  # noqa: E402


LISTING_REMOTE = "{root}/listing.tsv"


def banner(msg: str) -> None:
    print(f"\n=== {msg} ===")


def confirm(prompt: str) -> bool:
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def preflight(cfg, kc: Kubectl) -> None:
    banner("Preflight")
    # kubectl reachable (queries the API server; non-zero if unreachable)
    try:
        kc.get_json_cluster("version")
    except Exception as e:  # noqa: BLE001
        die(f"kubectl cannot reach the cluster: {e}")

    # enough schedulable s2a nodes?
    nodes = kc.list_ready_nodes(cfg.instance_class)
    print(f"  schedulable {cfg.instance_class} nodes: {len(nodes)} "
          f"(need {cfg.num_nodes})")
    for n in nodes:
        print(f"    - {n}")
    if len(nodes) < cfg.num_nodes:
        die(f"only {len(nodes)} schedulable {cfg.instance_class} nodes; "
            f"NUM_NODES={cfg.num_nodes}. Lower NUM_NODES or add nodes.")

    if cfg.is_nfs():
        print(f"  destination: NFS in-tree PV -> {cfg.nfs_server}:"
              f"{cfg.nfs_path()} (bypasses CSI; reclaimPolicy=Retain)")
        return
    if cfg.is_import():
        # Import mode binds a static PV; no StorageClass needed.
        print(f"  destination: IMPORT existing disk id={cfg.existing_disk_id} "
              f"serial={cfg.existing_disk_serial} (reclaimPolicy=Retain)")
        return

    # StorageClass present? (this cluster ships fs CSI but not the SC object)
    if kc.cluster_exists("storageclass", cfg.storage_class):
        print(f"  StorageClass {cfg.storage_class}: present")
    else:
        print(f"  StorageClass {cfg.storage_class}: ABSENT — creating "
              "(fs.csi.crusoe.ai)")
        kc.apply_cluster(manifests.storage_class(cfg.storage_class))


def list_source(cfg, kc: Kubectl) -> None:
    banner("Listing source (rclone lsf in master pod)")
    listing = LISTING_REMOTE.format(root=cfg.mount_root)
    # SEP is a real TAB byte (printf), so rclone and the local TSV parser agree.
    # --format sp puts size first; the parser splits on the first TAB, so a TAB
    # inside an object key (rare) stays part of the path.
    lsf = (
        "SEP=$(printf '\\t'); "
        "rclone lsf --recursive --files-only --format sp --separator \"$SEP\" "
        f"--config /config/rclone.conf {cfg.remote_root()} > {listing} && "
        f"wc -l {listing}"
    )
    print(f"  {cfg.remote_root()}  ->  {listing}")
    res = kc.exec(cfg.master_pod_name, ["/bin/sh", "-c", lsf])
    if res.stdout:
        print("  " + res.stdout.decode(errors="replace").strip())


def shard_locally(cfg, kc: Kubectl, run_dir: str) -> int:
    banner("Sharding (local LPT bin-pack)")
    listing = LISTING_REMOTE.format(root=cfg.mount_root)
    local_listing = os.path.join(run_dir, "listing.tsv")

    if not kc.dry_run:
        with open(local_listing, "wb") as fh:
            res = kc.exec(cfg.master_pod_name, ["cat", listing])
            fh.write(res.stdout or b"")
        with open(local_listing) as fh:
            objects = list(shard_manifest.parse_tsv(fh))
        if not objects:
            die("listing is empty — check bucket/prefix/credentials")
        n = cfg.effective_num_pods()
        bins, sizes = shard_manifest.bin_pack(objects, n)
        local_shard_dir = os.path.join(run_dir, "shards")
        shard_files = shard_manifest.write_shards(bins, local_shard_dir)
        total = sum(sizes)
        print(f"  {len(objects)} objects, {shard_manifest.human(total)} "
              f"-> {n} shards")
        for i, s in enumerate(sizes):
            print(f"    shard-{i}.txt: {len(bins[i])} files "
                  f"{shard_manifest.human(s)}")
        # push shards back to the shared disk
        for fp in shard_files:
            dest = f"{manifests.shard_dir(cfg)}/{os.path.basename(fp)}"
            kc.cp_to(cfg.master_pod_name, fp, dest)
        print(f"  pushed {len(shard_files)} shard files to "
              f"{manifests.shard_dir(cfg)}/")
        return total
    else:
        print("  [dry-run] would list, bin-pack, and push shard files")
        return 0


def launch_workers(cfg, kc: Kubectl, sizing) -> list[str]:
    banner("Launching worker pods")
    # Honor NUM_NODES for PLACEMENT: pin workers to exactly num_nodes nodes
    # (round-robin via nodeName) so "N nodes x K pods/node" lands as N x K,
    # instead of topology-spreading across every schedulable s2a node. nodeName
    # bypasses the scheduler, so the manifest's spread constraint is inert here.
    chosen = sorted(kc.list_ready_nodes(cfg.instance_class))[:cfg.num_nodes]
    if len(chosen) < cfg.num_nodes:
        die(f"only {len(chosen)} schedulable {cfg.instance_class} nodes; "
            f"need NUM_NODES={cfg.num_nodes}.")
    print(f"  pinning {cfg.effective_num_pods()} workers to {len(chosen)} "
          f"node(s): " + ", ".join(n.split('.')[0] for n in chosen))
    names = []
    for i in range(cfg.effective_num_pods()):
        pod = manifests.worker_pod(cfg, sizing, i)
        pod["spec"]["nodeName"] = chosen[i % len(chosen)]   # hard pin
        kc.apply(pod)
        names.append(pod["metadata"]["name"])
    print(f"  launched {len(names)} workers "
          f"({cfg.effective_pods_per_node()}/node x {len(chosen)})")
    return names


def monitor(cfg, kc: Kubectl, poll: int = 15) -> None:
    banner("Monitoring workers")
    if kc.dry_run:
        print("  [dry-run] skipping monitor")
        return
    sel = f"app={manifests.WORKER_LABEL}"
    while True:
        data = kc.get_json("get", "pods", "-l", sel)
        items = data.get("items", [])
        phases = {}
        running = []
        for p in items:
            ph = p["status"]["phase"]
            phases[ph] = phases.get(ph, 0) + 1
            if ph not in ("Succeeded", "Failed"):
                running.append(p["metadata"]["name"])
        summary = ", ".join(f"{k}={v}" for k, v in sorted(phases.items()))
        print(f"  [{time.strftime('%H:%M:%S')}] {summary}")
        if not running:
            break
        time.sleep(poll)
    # report failures
    for p in items:
        if p["status"]["phase"] == "Failed":
            name = p["metadata"]["name"]
            print(f"  !! {name} FAILED; last log lines:")
            print("    " + kc.logs(name, tail=10).replace("\n", "\n    "))


def teardown(cfg, kc: Kubectl) -> None:
    banner("Teardown")
    kc.delete("pod", selector=f"app={manifests.WORKER_LABEL}")
    kc.delete("pod", name=cfg.master_pod_name)
    print("  worker + master pods deleted (PVC, Secret, StorageClass kept)")


def main(argv: list[str] | None = None) -> int:
    cfg, args = load_config(argv)

    errs = cfg.validate(require_secrets=not args.dry_run)
    for w in cfg.warnings():
        print(f"WARNING: {w}", file=sys.stderr)
    if errs:
        for e in errs:
            print(f"ERROR: {e}", file=sys.stderr)
        return 2

    sizing = compute_sizing(cfg)
    banner("Plan")
    print(f"  source : {cfg.remote_root()}")
    print(f"  via    : {cfg.effective_endpoint()}")
    if cfg.is_nfs():
        print(f"  dest   : PVC {cfg.pvc_name} -> NFS {cfg.nfs_server}:"
              f"{cfg.nfs_path()} (in-tree PV, Retain) -> {cfg.dest_path}")
    elif cfg.is_import():
        print(f"  dest   : PVC {cfg.pvc_name} -> IMPORTED disk "
              f"{cfg.existing_disk_id} (CSI static PV, Retain) -> {cfg.dest_path}")
    else:
        print(f"  dest   : PVC {cfg.pvc_name} ({cfg.storage_class}, dynamic) "
              f"-> {cfg.dest_path}")
    print()
    print(sizing.explain())

    kc = Kubectl(namespace=cfg.k8s_namespace, dry_run=args.dry_run)

    if args.dry_run:
        banner("Dry-run: rendering manifests to ./generated")
        _render_generated(cfg, sizing)
        preflight(cfg, kc)
        print("\nDry-run complete. No transfer launched.")
        return 0

    run_dir = tempfile.mkdtemp(prefix="cmk-data-transfer-")
    print(f"\n  run dir: {run_dir}")

    preflight(cfg, kc)

    banner("Creating Secret (rclone.conf) — creds stay in-cluster")
    kc.create_secret_from_files(
        cfg.secret_name, {"rclone.conf": build_s3_compat_conf(cfg)})
    print(f"  secret/{cfg.secret_name} applied")

    banner("Applying PVC + master pod")
    if cfg.is_nfs():
        kc.apply(manifests.nfs_pv(cfg))
        print(f"  static NFS PV {cfg.static_pv_name()} -> {cfg.nfs_server}:"
              f"{cfg.nfs_path()}")
    elif cfg.is_import():
        kc.apply(manifests.import_pv(cfg))
        print(f"  static PV {cfg.static_pv_name()} -> disk {cfg.existing_disk_id}")
    kc.apply(manifests.pvc(cfg))
    kc.apply(manifests.master_pod(cfg))
    kc.wait_ready(cfg.master_pod_name)
    print(f"  pod/{cfg.master_pod_name} ready")

    list_source(cfg, kc)
    total_bytes = shard_locally(cfg, kc, run_dir)

    banner("Ready to launch the transfer")
    print(f"  {sizing.total_pods} worker pods "
          f"({sizing.pods_per_node}/node x {cfg.num_nodes} {cfg.instance_class} "
          f"nodes), {sizing.in_flight_per_node} in-flight streams/node.")
    if total_bytes:
        print(f"  dataset size: {shard_manifest.human(total_bytes)}")
    if not args.yes and not confirm(
            "Launch the worker pods now (starts the large download)?"):
        print("Aborted before launch. Master pod + shards left in place "
              "(re-run with --yes to launch).")
        return 0

    launch_workers(cfg, kc, sizing)
    monitor(cfg, kc)

    if args.keep:
        print("\n--keep set: leaving pods running for inspection.")
    else:
        teardown(cfg, kc)

    banner("Done")
    print(f"  dataset on PVC {cfg.pvc_name} at {cfg.dest_path}")
    print(f"  per-worker logs: {manifests.log_dir(cfg)}/worker-<i>.log")
    return 0


def _render_generated(cfg, sizing) -> None:
    import json
    out = os.path.join(os.getcwd(), "generated")
    os.makedirs(out, exist_ok=True)
    docs = {
        "pvc.json": manifests.pvc(cfg),
        "master-pod.json": manifests.master_pod(cfg),
        "worker-pod-0.json": manifests.worker_pod(cfg, sizing, 0),
    }
    if cfg.is_nfs():
        docs["nfs-pv.json"] = manifests.nfs_pv(cfg)
    elif cfg.is_import():
        docs["import-pv.json"] = manifests.import_pv(cfg)
    else:
        docs["storageclass.json"] = manifests.storage_class(cfg.storage_class)
    for fname, doc in docs.items():
        with open(os.path.join(out, fname), "w") as fh:
            json.dump(doc, fh, indent=2)
        print(f"  wrote generated/{fname}")
    print("  (Secret intentionally NOT rendered — contains credentials)")


if __name__ == "__main__":
    raise SystemExit(main())
