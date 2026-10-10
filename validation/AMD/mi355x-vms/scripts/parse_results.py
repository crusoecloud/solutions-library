#!/usr/bin/env python3
"""Summarize MI355X validation results into a markdown report.

Reads the newest results/smoke-*/ and results/multinode-*/ directories (or the ones given)
and prints a report; also writes it to <results>/report-<timestamp>.md.

Usage:
  python3 scripts/parse_results.py [RESULTS_DIR] [--smoke DIR] [--multinode DIR] [--no-write]
"""
import argparse
import csv
import datetime
import glob
import math
import os
import re
import statistics
import sys

ROW_RE = re.compile(r"^\s*(\d{6,})\s+(\d+)\s+(\w+)\s+\S+\s+-?\d+\s+(.*)$")


def newest(pattern):
    paths = sorted(p for p in glob.glob(pattern) if os.path.isdir(p))
    return paths[-1] if paths else None


def read_kv(path):
    out = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    return out


def human(nbytes):
    n = int(nbytes)
    if n >= 1 << 30:
        return f"{n / (1 << 30):g}G"
    return f"{n / (1 << 20):g}M"


def size_rows(log):
    """[(size_bytes, oop_busbw, ip_busbw, wrong)] from an rccl-tests log."""
    rows = []
    with open(log, errors="replace") as f:
        for line in f:
            m = ROW_RE.match(line)
            if not m:
                continue
            cols = line.split()
            if len(cols) < 13:
                continue
            try:
                # from the end: oop time algbw busbw #wrong | ip time algbw busbw #wrong
                oop, ip = float(cols[-6]), float(cols[-2])
                wrong = int(cols[-5]) + int(cols[-1]) if cols[-1].isdigit() else int(cols[-5])
            except ValueError:
                continue
            # bucket to the nearest power of two: all_gather / reduce_scatter round the
            # message size to a multiple of the rank count (e.g. 2G -> 2147483136 B)
            size = 1 << round(math.log2(int(cols[0])))
            rows.append((size, oop, ip, wrong))
    return rows


def smoke_section(sdir):
    path = os.path.join(sdir, "summary.csv")
    if not os.path.exists(path):
        return [f"_No summary.csv in {sdir}_"]
    with open(path) as f:
        nodes = list(csv.DictReader(f))
    out = [f"## Single-node smoke (`{os.path.basename(sdir)}`)", ""]
    n_pass = sum(1 for r in nodes if r["verdict"] == "PASS")
    out.append(f"**{n_pass}/{len(nodes)} nodes PASS**")
    out.append("")

    def stats(key):
        vals = []
        for r in nodes:
            try:
                vals.append(float(r[key]))
            except (ValueError, KeyError):
                pass
        if not vals:
            return "n/a"
        return f"min {min(vals):.1f} / median {statistics.median(vals):.1f} / max {max(vals):.1f}"

    out += [
        "| Check | Result |",
        "|---|---|",
        f"| Env verify (versions, GPUs, ECC, rails, PCIe, dmesg) | {sum(r['env'] == 'PASS' for r in nodes)}/{len(nodes)} PASS |",
        f"| Rail census | {sum('rails=8/8' in r['rails'] and 'FAIL' not in r['rails'] for r in nodes)}/{len(nodes)} with 8/8 rails active |",
        f"| GEMM (RVS GST, fp8/bf8/fp16/bf16 vs AMD targets) | {sum(r['gemm'] == 'PASS' for r in nodes)}/{len(nodes)} PASS; fp8 TFLOPS/GPU {stats('gemm_fp8_min_tflops')} |",
        f"| RCCL all_reduce, 1 node (8 GPUs) | {sum(r['rccl_1n'] == 'PASS' for r in nodes)}/{len(nodes)} PASS; busbw GB/s {stats('rccl_1n_busbw_gbps')} |",
        "",
    ]
    failing = [r for r in nodes if r["verdict"] != "PASS"]
    if failing:
        out += ["Failing nodes:", "", "| Node | VM ID | env | gemm | rccl_1n | busbw | failed checks |", "|---|---|---|---|---|---|---|"]
        for r in failing:
            out.append(f"| {r['node']} | {r['vm_id']} | {r['env']} | {r['gemm']} | {r['rccl_1n']} | {r['rccl_1n_busbw_gbps']} | {r.get('env_fail_checks', '')} |")
        out.append("")
    out += ["<details><summary>Per-node table</summary>", "",
            "| Node | VM ID | env | rails | gemm | fp8 TFLOPS | rccl_1n | busbw GB/s | verdict |",
            "|---|---|---|---|---|---|---|---|---|"]
    for r in nodes:
        out.append(f"| {r['node']} | {r['vm_id']} | {r['env']} | {r['rails']} | {r['gemm']} | {r['gemm_fp8_min_tflops']} | {r['rccl_1n']} | {r['rccl_1n_busbw_gbps']} | {r['verdict']} |")
    out += ["", "</details>", ""]
    return out


def multinode_section(mdir):
    sums = sorted(glob.glob(os.path.join(mdir, "*.summary")))
    out = [f"## Multi-node RCCL (`{os.path.basename(mdir)}`)", ""]
    if not sums:
        return out + ["_No RCCL runs found._", ""]
    runs = []
    for s in sums:
        kv = read_kv(s)
        log = kv.get("log", "")
        local_log = os.path.join(mdir, os.path.basename(log)) if log else s[:-8] + ".log"
        rows = size_rows(local_log) if os.path.exists(local_log) else []
        runs.append((kv, rows))
    runs.sort(key=lambda r: (r[0].get("collective", ""), int(r[0].get("nodes", 0) or 0)))

    out += ["| Collective | Nodes | GPUs | Avg busbw (GB/s) | Peak busbw (GB/s) @ size | Gate | #wrong | Verdict |",
            "|---|---|---|---|---|---|---|---|"]
    for kv, _ in runs:
        n = int(kv.get("nodes", 0) or 0)
        gate = f"{kv.get('gate_metric', 'avg')} >= {kv.get('gate', '?')}"
        out.append(f"| {kv.get('collective')} | {n} | {n * 8} | {kv.get('avg_busbw')} | "
                   f"{kv.get('peak_busbw', 'n/a')} @ {kv.get('peak_size', 'n/a')} | {gate} | {kv.get('wrong')} | **{kv.get('verdict')}** |")
    out.append("")

    out += ["Per-size out-of-place busbw (GB/s):", ""]
    sizes = sorted({r[0] for _, rows in runs for r in rows})
    if sizes:
        out.append("| Collective | Nodes | " + " | ".join(human(s) for s in sizes) + " |")
        out.append("|---|---|" + "---|" * len(sizes))
        for kv, rows in runs:
            by = {r[0]: r[1] for r in rows}
            out.append(f"| {kv.get('collective')} | {kv.get('nodes')} | " +
                       " | ".join(f"{by[s]:.1f}" if s in by else "-" for s in sizes) + " |")
        out.append("")

    problems = [(kv, k) for kv, _ in runs for k in ("status12", "cqe_err", "port_error", "segfault")
                if str(kv.get(k, "0")) not in ("0", "")]
    if problems:
        out += ["Fabric / runtime error signatures:", ""]
        for kv, k in problems:
            out.append(f"- {kv.get('collective')} n={kv.get('nodes')}: {k}={kv.get(k)} ({kv.get('reason', '').strip()})")
        out.append("")

    rails = os.path.join(mdir, "pair_rail.txt")
    if os.path.exists(rails):
        with open(rails) as f:
            lines = f.read().splitlines()
        overall = [l for l in lines if "pair_rail:overall" in l]
        out += ["Pair-rail ib_write_bw (anchor vs each node, per rail):", "",
                f"`{overall[-1] if overall else 'incomplete'}`", ""]
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="?", default=os.path.join(here, "..", "results"))
    ap.add_argument("--smoke", help="smoke results dir (default: newest results/smoke-*)")
    ap.add_argument("--multinode", help="multinode results dir (default: newest results/multinode-*)")
    ap.add_argument("--no-write", action="store_true", help="print only; do not write report-<ts>.md")
    a = ap.parse_args()

    res = os.path.abspath(a.results)
    sdir = a.smoke or newest(os.path.join(res, "smoke-*"))
    mdir = a.multinode or newest(os.path.join(res, "multinode-*"))
    if not sdir and not mdir:
        sys.exit(f"no smoke-* or multinode-* directories under {res}")

    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    out = [f"# MI355X validation report ({ts})", ""]
    if sdir:
        out += smoke_section(sdir)
    if mdir:
        out += multinode_section(mdir)
    text = "\n".join(out) + "\n"
    print(text)
    if not a.no_write:
        path = os.path.join(res, f"report-{ts}.md")
        with open(path, "w") as f:
            f.write(text)
        print(f"wrote {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
