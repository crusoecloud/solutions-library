#!/usr/bin/env python3
"""Distributed gateway load generator (pure stdlib — runs on any python:3.x image).

One pod runs CONCURRENCY worker threads, each holding a PERSISTENT keep-alive
connection to the target gateway and firing OpenAI chat-completions back-to-back
for DURATION seconds. Persistent connections are deliberate: the client->Envoy
leg stays keep-alive (so a single pod never churns through ephemeral ports), yet
Envoy still L7-load-balances every *request* across all upstream replicas. That
lets each pod sustain a high, stable concurrency; scale total offered load by the
number of pods (parallelism), not by hammering one pod until its sockets exhaust.

Emits one line `RESULT_JSON {...}` at the end; the Makefile sums these across pods.
Always exits 0 so the Job completes and logs are collectible.
"""
import os, sys, time, json, threading, http.client, urllib.parse
from concurrent.futures import ThreadPoolExecutor

TARGET   = os.environ["TARGET_URL"].rstrip("/")     # e.g. http://<VIP>/kserve-test/qwen3-llm
MODEL    = os.environ.get("MODEL", "qwen3")
CONC     = int(os.environ.get("CONCURRENCY", "256"))
DURATION = int(os.environ.get("DURATION", "60"))
IN_LEN   = int(os.environ.get("INPUT_LEN", "512"))
OUT_LEN  = int(os.environ.get("OUTPUT_LEN", "150"))
POD      = os.environ.get("POD_NAME", "loadgen")

u        = urllib.parse.urlparse(TARGET)
HOST     = u.hostname
PORT     = u.port or (443 if u.scheme == "https" else 80)
IS_TLS   = u.scheme == "https"
ENDPOINT = (u.path or "") + "/v1/chat/completions"
HEADERS  = {"Content-Type": "application/json", "Connection": "keep-alive"}

# Fixed payload. min_tokens + ignore_eos force exactly OUT_LEN output tokens so
# throughput is comparable run to run (mirrors `vllm bench serve --ignore-eos`).
# The prompt is padded to ~IN_LEN tokens (1 short word ~ 1 token — close enough for load).
PROMPT = " ".join(["word"] * IN_LEN)
BODY = json.dumps({
    "model": MODEL,
    "messages": [{"role": "user", "content": PROMPT}],
    "max_tokens": OUT_LEN, "min_tokens": OUT_LEN, "ignore_eos": True,
    "temperature": 0.0, "stream": True, "stream_options": {"include_usage": True},
}).encode()

_lock = threading.Lock()
_stats = {"success": 0, "fail": 0, "out_tokens": 0}
_ttfts, _latencies = [], []
_stop_at = 0.0


def _new_conn():
    cls = http.client.HTTPSConnection if IS_TLS else http.client.HTTPConnection
    return cls(HOST, PORT, timeout=180)


def _completion_tokens(buf):
    """Prefer usage.completion_tokens from the final SSE chunk; else count content deltas."""
    usage_ct, delta_ct = None, 0
    for line in buf.split(b"\n"):
        line = line.strip()
        if not line.startswith(b"data: "):
            continue
        payload = line[6:]
        if payload == b"[DONE]":
            continue
        try:
            d = json.loads(payload)
        except Exception:
            continue
        usg = d.get("usage")
        if usg and usg.get("completion_tokens"):
            usage_ct = usg["completion_tokens"]
        ch = d.get("choices") or []
        if ch and (ch[0].get("delta") or {}).get("content"):
            delta_ct += 1
    return usage_ct if usage_ct is not None else delta_ct


def worker():
    conn = None
    while time.time() < _stop_at:
        try:
            if conn is None:
                conn = _new_conn()
            t0 = time.time()
            conn.request("POST", ENDPOINT, body=BODY, headers=HEADERS)
            resp = conn.getresponse()
            if resp.status != 200:
                resp.read()  # drain so the keep-alive connection stays reusable
                with _lock:
                    _stats["fail"] += 1
                continue
            ttft, buf = None, b""
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                if ttft is None:
                    ttft = (time.time() - t0) * 1000.0
                buf += chunk
            total = (time.time() - t0) * 1000.0
            ct = _completion_tokens(buf)
            with _lock:
                _stats["success"] += 1
                _stats["out_tokens"] += ct
                if ttft is not None:
                    _ttfts.append(ttft)
                _latencies.append(total)
        except Exception:
            with _lock:
                _stats["fail"] += 1
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            conn = None  # reconnect on next iteration


def _pct(a, p):
    if not a:
        return 0.0
    a = sorted(a)
    return round(a[min(len(a) - 1, int(len(a) * p / 100.0))], 1)


def main():
    global _stop_at
    print(f"[{POD}] target={TARGET} conc={CONC} duration={DURATION}s "
          f"in={IN_LEN} out={OUT_LEN} model={MODEL}", flush=True)
    start = time.time()
    _stop_at = start + DURATION
    with ThreadPoolExecutor(max_workers=CONC) as ex:
        for f in [ex.submit(worker) for _ in range(CONC)]:
            f.result()
    elapsed = max(time.time() - start, 1e-6)
    result = {
        "pod": POD, "elapsed_s": round(elapsed, 2), "concurrency": CONC,
        "success": _stats["success"], "fail": _stats["fail"],
        "out_tokens": _stats["out_tokens"],
        "out_tok_s": round(_stats["out_tokens"] / elapsed, 1),
        "req_s": round(_stats["success"] / elapsed, 2),
        "ttft_ms_median": _pct(_ttfts, 50), "ttft_ms_p99": _pct(_ttfts, 99),
        "latency_ms_median": _pct(_latencies, 50),
    }
    print("RESULT_JSON " + json.dumps(result), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never fail the Job — emit what we have
        print(f"RESULT_JSON {json.dumps({'pod': POD, 'error': str(e)[:200], 'success': 0, 'fail': 0, 'out_tok_s': 0, 'req_s': 0})}", flush=True)
    sys.exit(0)
