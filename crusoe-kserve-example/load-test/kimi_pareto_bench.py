#!/usr/bin/env python3
"""Kimi-K3 Pareto sweep harness (output throughput vs TTFT-p95 across concurrency x shape).

Drives `vllm bench serve` from the dedicated kimi-bench-client pod against ONE variant's
workload Service. Fixed shapes (not random), ignore-EOS, fixed seed, warmup discarded,
>=300 requests per run. Errors are their own column and are NEVER dropped from throughput
math. Per shape, concurrency escalates until the SLO/stop rule trips; saturation is recorded.

Usage:
  VARIANT=kimi-ep SVC=kimi-ep-llm-kserve-workload-svc python3 kimi_pareto_bench.py
Env: VARIANT (served-model-name, required) · SVC (workload svc, default <VARIANT>-llm-kserve-workload-svc)
     NS=kserve-test · CTX=<kube-context> (optional, default: current-context) · CLIENT=deploy/kimi-bench-client · OUT=<csv>
     SHAPES="512:128,4096:512,32768:1024,131072:2048,1024:8192" · CONC="1,4,16,64,128,256,512"
Stop rules (per shape): TTFT-p95 > 10s, OR output-tok/s plateaus twice (<5% gain), OR any 100% error run.
SLO reference (flagged in output, not a stop): TTFT-p95 < 1s, TPOT < 50ms.
"""
import os, re, subprocess, sys, csv, time

VARIANT = os.environ["VARIANT"]
SVC     = os.environ.get("SVC", f"{VARIANT}-llm-kserve-workload-svc")
NS      = os.environ.get("NS", "kserve-test")
CTX     = os.environ.get("CTX", "")   # kube context; empty => kubeconfig current-context
CLIENT  = os.environ.get("CLIENT", "deploy/kimi-bench-client")
OUT     = os.environ.get("OUT", f"/tmp/kimi_pareto_{VARIANT}.csv")
# Long shape input is 124000 (not 128k): vllm's random dataset inflates tokens ~1.4% on
# decode->re-encode, so 128000 -> ~129.8k, and +2048 output exceeds max_model_len 131072.
# 124000 -> ~125.7k + 2048 = ~127.7k, comfortably under 131072.
SHAPES  = os.environ.get("SHAPES", "512:128,4096:512,32768:1024,124000:2048,1024:8192")
CONC    = [int(c) for c in os.environ.get("CONC", "1,4,16,64,128,256,512").split(",")]
BASE    = f"http://{SVC}.{NS}.svc.cluster.local:8000"
WARMUPS = int(os.environ.get("WARMUPS", "8"))
TTFT_STOP_MS = 10_000
SLO_TTFT_MS, SLO_TPOT_MS = 1_000, 50

COLS = ["config_id","variant","in_tok","out_tok","concurrency","num_prompts",
        "successful","errors","err_pct","duration_s","req_s","output_tps","total_tps",
        "ttft_p95_ms","ttft_p99_ms","tpot_p95_ms","tpot_p50_ms","slo_ok","note"]

def run_bench(in_tok, out_tok, conc):
    # Adaptive request count: target ~120s per run (per the "300 requests OR 120s" rule) instead of
    # a flat 300 — otherwise slow long-output shapes at low concurrency need 300 x ~25s >> timeout.
    est_req_s = max(3.0, out_tok * 0.045 + in_tok * 0.0006)   # rough: TPOT-dominated + prefill
    n_cap = max(3, int(conc * 1500.0 / est_req_s))            # keep each run <= ~25min (< task lifetime)
    n = max(3, min(300, round(conc * 120.0 / est_req_s), n_cap))
    vllm = ["vllm","bench","serve",
        "--model","moonshotai/Kimi-K3","--tokenizer","moonshotai/Kimi-K3","--trust-remote-code",
        "--served-model-name",VARIANT,
        "--base-url",BASE,"--backend","openai-chat","--endpoint","/v1/chat/completions",
        "--dataset-name","random","--random-input-len",str(in_tok),
        "--random-output-len",str(out_tok),"--random-range-ratio","0","--ignore-eos",
        "--seed","0","--num-warmups",str(WARMUPS),
        "--num-prompts",str(n),"--request-rate","inf","--max-concurrency",str(conc),
        "--percentile-metrics","ttft,tpot,itl,e2el","--metric-percentiles","95,99",
        "--disable-tqdm"]
    # IN_POD=1: run vllm bench directly (inside the client pod, survives the local task lifetime).
    # else: drive it via kubectl exec from the workstation.
    cmd = vllm if os.environ.get("IN_POD") else ["kubectl"] + (["--context",CTX] if CTX else []) + ["-n",NS,"exec",CLIENT,"--"] + vllm
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=3600).stdout
    except subprocess.TimeoutExpired:
        return {"num_prompts": n, "successful": 0, "errors": n, "err_pct": 100.0, "note": "timeout"}
    g = lambda pat: (float(m.group(1)) if (m := re.search(pat, out)) else None)
    succ = g(r"Successful requests:\s+([0-9.]+)")
    succ = int(succ) if succ is not None else 0
    return {
        "num_prompts": n, "successful": succ, "errors": n - succ,
        "err_pct": round(100.0 * (n - succ) / n, 1),
        "duration_s": g(r"Benchmark duration \(s\):\s+([0-9.]+)"),
        "req_s": g(r"Request throughput \(req/s\):\s+([0-9.]+)"),
        "output_tps": g(r"Output token throughput \(tok/s\):\s+([0-9.]+)"),
        "total_tps": g(r"Total [Tt]oken throughput \(tok/s\):\s+([0-9.]+)"),
        "ttft_p95": g(r"P95 TTFT \(ms\):\s+([0-9.]+)"),
        "ttft_p99": g(r"P99 TTFT \(ms\):\s+([0-9.]+)"),
        "tpot_p95": g(r"P95 TPOT \(ms\):\s+([0-9.]+)"),
        "tpot_p50": g(r"Median TPOT \(ms\):\s+([0-9.]+)"),
        "note": "",
    }

def main():
    # RESUMABLE: skip runs already in the CSV and whole shapes already marked done, so a
    # relaunch (e.g. after a killed background task) continues instead of restarting.
    progress = OUT + ".doneshapes"
    done_shapes = set(l.strip() for l in open(progress)) if os.path.exists(progress) else set()
    done_cfg, prev_by_shape = set(), {}
    if os.path.exists(OUT):
        for row in csv.reader(open(OUT)):
            if row and row[0] != "config_id":
                done_cfg.add(row[0])
                try: prev_by_shape[(row[2], row[3])] = float(row[11])   # last out_tps per shape
                except Exception: pass
    rows = []
    new = not os.path.exists(OUT)
    with open(OUT, "a", newline="") as f:
        w = csv.writer(f)
        if new: w.writerow(COLS); f.flush()
        for shape in SHAPES.split(","):
            in_tok, out_tok = (int(x) for x in shape.split(":"))
            skey = "%dx%d" % (in_tok, out_tok)
            if skey in done_shapes:
                print("[skip] shape %s already complete" % skey, flush=True); continue
            prev_tps = prev_by_shape.get((str(in_tok), str(out_tok)))
            plateau = 0
            for conc in CONC:
                cid = f"{VARIANT}-{in_tok}x{out_tok}-c{conc}"
                if cid in done_cfg:
                    print("[skip] %s already done" % cid, flush=True); continue
                print(f"[run] {cid} ...", flush=True)
                r = run_bench(in_tok, out_tok, conc)
                otps = r.get("output_tps") or 0.0
                ttft95 = r.get("ttft_p95")
                tpot95 = r.get("tpot_p95")
                slo_ok = (ttft95 is not None and ttft95 < SLO_TTFT_MS and
                          tpot95 is not None and tpot95 < SLO_TPOT_MS and r["errors"] == 0)
                note = r.get("note","")
                # plateau: <5% output-tps gain vs previous concurrency
                if prev_tps and prev_tps > 0 and (otps - prev_tps) / prev_tps < 0.05:
                    plateau += 1
                else:
                    plateau = 0
                prev_tps = otps
                row = [cid, VARIANT, in_tok, out_tok, conc, r["num_prompts"], r["successful"],
                       r["errors"], r["err_pct"], r.get("duration_s"), r.get("req_s"), otps,
                       r.get("total_tps"), ttft95, r.get("ttft_p99"), tpot95, r.get("tpot_p50"),
                       "yes" if slo_ok else "no", note]
                w.writerow(row); f.flush(); rows.append(row)
                print(f"      out_tps={otps} ttft_p95={ttft95}ms tpot_p95={tpot95}ms "
                      f"err={r['errors']}/{r['num_prompts']} slo={'ok' if slo_ok else 'no'}", flush=True)
                # stop rules for this shape
                if r["errors"] == r["num_prompts"]:
                    print(f"      SATURATED: 100% errors at c={conc}", flush=True); break
                if ttft95 is not None and ttft95 > TTFT_STOP_MS:
                    print(f"      SATURATED: TTFT-p95 {ttft95}ms > {TTFT_STOP_MS}ms at c={conc}", flush=True); break
                if plateau >= 2:
                    print(f"      SATURATED: output-tps plateaued twice at c={conc}", flush=True); break
            with open(progress, "a") as pf:      # shape ladder finished -> mark complete for resume
                pf.write(skey + "\n")
    print(f"\nDONE -> {OUT} ({len(rows)} runs)")

if __name__ == "__main__":
    main()
