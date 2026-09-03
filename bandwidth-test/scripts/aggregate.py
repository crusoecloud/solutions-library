#!/usr/bin/env python3
"""Summarise the server-side iperf3 results.

Reads the JSON each iperf3 SERVER wrote for its own flow. The receiver is the
authoritative measurement - it counts what actually arrived, which is what you
want when the path in between is a managed gateway you do not control.

  aggregate.py [results-dir]
"""
import glob, json, os, sys

d = sys.argv[1] if len(sys.argv) > 1 else "results"
files = sorted(f for f in glob.glob(os.path.join(d, "flow-*.json"))
                if not os.path.basename(f).startswith("client-"))
if not files:
    sys.exit(f"no results in {d}/ - did the servers run?")

# retransmits are a sender-side counter, so they come from the client's file
# when one was collected; throughput always comes from the server's
client = {}
for cf in glob.glob(os.path.join(d, "client-flow-*.json")):
    try:
        cj = json.load(open(cf))
        key = os.path.basename(cf)[len("client-"):-5]
        client[key] = (cj.get("end", {}).get("sum_sent") or {}).get("retransmits")
    except Exception:
        pass

rows, bad = [], []
for f in files:
    name = os.path.basename(f)[:-5]
    try:
        j = json.load(open(f))
    except Exception as e:
        bad.append(f"{name}: unreadable ({e})")
        continue
    if "error" in j:
        bad.append(f"{name}: {j['error']}")
        continue
    end = j.get("end", {})
    # UDP reports under sum; TCP under sum_received on the server side
    s = end.get("sum_received") or end.get("sum") or {}
    if not s:
        bad.append(f"{name}: no summary in the server's JSON")
        continue
    rows.append({
        "flow": name.replace("flow-", ""),
        "gbps": s.get("bits_per_second", 0) / 1e9,
        "seconds": s.get("seconds", 0),
        "retrans": client.get(os.path.basename(f)[:-5]),
        "lost_pct": s.get("lost_percent"),
        "jitter_ms": s.get("jitter_ms"),
    })

rows.sort(key=lambda r: r["flow"])
udp = any(r["lost_pct"] is not None for r in rows)

print("=" * 74)
print(f"BANDWIDTH TEST - {len(rows)} flow(s) measured at the receiver")
print("=" * 74)
hdr = f"  {'flow':<34}{'Gbps':>8}{'secs':>7}"
hdr += f"{'loss %':>9}{'jitter ms':>11}" if udp else f"{'retrans':>10}"
print(hdr)
for r in rows:
    line = f"  {r['flow'][:34]:<34}{r['gbps']:>8.2f}{r['seconds']:>7.1f}"
    if udp:
        line += f"{(r['lost_pct'] or 0):>9.2f}{(r['jitter_ms'] or 0):>11.3f}"
    else:
        line += f"{r['retrans'] if r['retrans'] is not None else 'n/a':>10}"
    print(line)

total = sum(r["gbps"] for r in rows)
print("-" * 74)
print(f"  {'TOTAL':<34}{total:>8.2f} Gbps across {len(rows)} flow(s)")
if rows:
    print(f"  {'mean per flow':<34}{total/len(rows):>8.2f} Gbps")
if not udp:
    rt = [r["retrans"] for r in rows if r["retrans"] is not None]
    if rt:
        print(f"  {'total retransmits':<34}{sum(rt):>8,}")
    else:
        print("  retransmits: n/a (no client-side results collected)")
        print("  Retransmits are the efficiency signal: a large number means the")
        print("  path is being driven past its knee, even if throughput looks good.")
if bad:
    print()
    print(f"  {len(bad)} flow(s) produced no result:")
    for b in bad:
        print(f"    {b}")
