#!/usr/bin/env python3
"""Async high-density gateway load generator (pure stdlib asyncio).

Holds CONCURRENCY persistent keep-alive connections per pod, each looping OpenAI
chat-completions back-to-back for DURATION seconds. One asyncio task per
connection (~20 KB each), so a single pod holds thousands of in-flight requests
on a fraction of a CPU — built to stress the Envoy gateway's connection handling
at very high concurrency. Scale total offered concurrency by pod count (fan-out).

Raw HTTP/1.1 over asyncio streams (no pip deps). Prints a heartbeat every 15 s and
a final RESULT_JSON line the Makefile sums across pods. Always exits 0.

Env: TARGET_URL MODEL CONCURRENCY DURATION INPUT_LEN OUTPUT_LEN RAMP_SECONDS
     REQ_TIMEOUT POD_NAME
Note: the container must raise its fd limit (ulimit -n) above CONCURRENCY.
"""
import asyncio, os, sys, json, time, urllib.parse

TARGET   = os.environ["TARGET_URL"].rstrip("/")
MODEL    = os.environ.get("MODEL", "qwen3")
CONC     = int(os.environ.get("CONCURRENCY", "4000"))
DURATION = int(os.environ.get("DURATION", "120"))
IN_LEN   = int(os.environ.get("INPUT_LEN", "512"))
OUT_LEN  = int(os.environ.get("OUTPUT_LEN", "150"))
RAMP     = float(os.environ.get("RAMP_SECONDS", "15"))
TIMEOUT  = float(os.environ.get("REQ_TIMEOUT", "300"))
POD      = os.environ.get("POD_NAME", "loadgen")

u    = urllib.parse.urlparse(TARGET)
HOST = u.hostname
PORT = u.port or (443 if u.scheme == "https" else 80)
TLS  = u.scheme == "https"
EP   = (u.path or "") + "/v1/chat/completions"

PROMPT = " ".join(["word"] * IN_LEN)
BODY = json.dumps({
    "model": MODEL, "messages": [{"role": "user", "content": PROMPT}],
    "max_tokens": OUT_LEN, "min_tokens": OUT_LEN, "ignore_eos": True,
    "temperature": 0.0, "stream": True, "stream_options": {"include_usage": True},
}).encode()
REQ = (("POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\n"
        "Content-Length: %d\r\nConnection: keep-alive\r\n\r\n"
        % (EP, HOST, len(BODY))).encode()) + BODY

S = {"established": 0, "active": 0, "peak_active": 0, "success": 0, "fail": 0,
     "conn_err": 0, "http_err": 0, "out_tokens": 0}
TT, LAT = [], []
stop_at = 0.0


async def _read_headers(reader):
    line = await reader.readuntil(b"\r\n")
    parts = line.split(b" ", 2)
    status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
    headers = {}
    while True:
        h = await reader.readuntil(b"\r\n")
        if h == b"\r\n":
            break
        if b":" in h:
            k, v = h.split(b":", 1)
            headers[k.strip().lower()] = v.strip()
    return status, headers


async def _read_body(reader, headers):
    """Return (body_bytes, ttft_seconds_or_None). Handles chunked + content-length."""
    if headers.get(b"transfer-encoding", b"").lower() == b"chunked":
        body = b""; ttft = None; t0 = time.monotonic()
        while True:
            size_line = await reader.readuntil(b"\r\n")
            try:
                size = int(size_line.strip().split(b";")[0], 16)
            except ValueError:
                raise IOError("bad chunk size")
            if size == 0:
                await reader.readuntil(b"\r\n")
                break
            chunk = await reader.readexactly(size + 2)  # data + trailing CRLF
            if ttft is None:
                ttft = time.monotonic() - t0
            body += chunk[:-2]
        return body, ttft
    n = int(headers.get(b"content-length", b"0"))
    return (await reader.readexactly(n) if n else b""), None


def _count_tokens(body):
    usage, deltas = None, 0
    for line in body.split(b"\n"):
        line = line.strip()
        if not line.startswith(b"data: "):
            continue
        p = line[6:]
        if p == b"[DONE]":
            continue
        try:
            d = json.loads(p)
        except Exception:
            continue
        us = d.get("usage")
        if us and us.get("completion_tokens"):
            usage = us["completion_tokens"]
        ch = d.get("choices") or []
        if ch and (ch[0].get("delta") or {}).get("content"):
            deltas += 1
    return usage if usage is not None else deltas


async def _conn_loop(idx):
    await asyncio.sleep(RAMP * idx / max(CONC, 1))  # stagger connection opens
    reader = writer = None
    while time.monotonic() < stop_at:
        try:
            if writer is None:
                reader, writer = await asyncio.wait_for(
                    asyncio.open_connection(HOST, PORT, ssl=TLS), timeout=30)
                S["established"] += 1
            t0 = time.monotonic()
            writer.write(REQ)
            await writer.drain()
            S["active"] += 1
            if S["active"] > S["peak_active"]:
                S["peak_active"] = S["active"]
            status, headers = await asyncio.wait_for(_read_headers(reader), TIMEOUT)
            body, ttft = await asyncio.wait_for(_read_body(reader, headers), TIMEOUT)
            S["active"] -= 1
            if status == 200:
                S["success"] += 1
                S["out_tokens"] += _count_tokens(body)
                if ttft is not None:
                    TT.append(ttft * 1000)
                LAT.append((time.monotonic() - t0) * 1000)
            else:
                S["fail"] += 1; S["http_err"] += 1
            if headers.get(b"connection", b"").lower() == b"close":
                writer.close(); reader = writer = None
        except Exception:
            S["fail"] += 1; S["conn_err"] += 1
            if S["active"] > 0:
                S["active"] -= 1
            try:
                if writer:
                    writer.close()
            except Exception:
                pass
            reader = writer = None
            await asyncio.sleep(0.5)
    try:
        if writer:
            writer.close()
    except Exception:
        pass


async def _heartbeat():
    while time.monotonic() < stop_at:
        await asyncio.sleep(15)
        print("[%s] est=%d active=%d peak=%d ok=%d fail=%d(conn=%d,http=%d) tok=%d"
              % (POD, S["established"], S["active"], S["peak_active"], S["success"],
                 S["fail"], S["conn_err"], S["http_err"], S["out_tokens"]), flush=True)


async def main():
    global stop_at
    print("[%s] async target=%s conc=%d dur=%ds ramp=%ss in=%d out=%d"
          % (POD, TARGET, CONC, DURATION, RAMP, IN_LEN, OUT_LEN), flush=True)
    start = time.monotonic()
    stop_at = start + RAMP + DURATION
    hb = asyncio.create_task(_heartbeat())
    await asyncio.gather(*[asyncio.create_task(_conn_loop(i)) for i in range(CONC)],
                         return_exceptions=True)
    hb.cancel()
    elapsed = max(time.monotonic() - start, 1e-6)

    def pct(a, p):
        if not a:
            return 0.0
        a = sorted(a)
        return round(a[min(len(a) - 1, int(len(a) * p / 100))], 1)

    r = {"pod": POD, "elapsed_s": round(elapsed, 1), "target_conc": CONC,
         "established": S["established"], "peak_active": S["peak_active"],
         "success": S["success"], "fail": S["fail"], "conn_err": S["conn_err"],
         "http_err": S["http_err"], "out_tokens": S["out_tokens"],
         "out_tok_s": round(S["out_tokens"] / elapsed, 1),
         "req_s": round(S["success"] / elapsed, 2),
         "ttft_ms_p50": pct(TT, 50), "ttft_ms_p99": pct(TT, 99),
         "lat_ms_p50": pct(LAT, 50)}
    print("RESULT_JSON " + json.dumps(r), flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        print("RESULT_JSON " + json.dumps(
            {"pod": POD, "error": str(e)[:200], "success": 0, "fail": 0, "out_tok_s": 0}),
            flush=True)
    sys.exit(0)
