"""Concurrency sizing, grounded in the discovered s2a hardware and the 150 ms
bandwidth-delay product (BDP).

THE CORE IDEA
-------------
Over a >150 ms intercontinental path, a single TCP stream is window-limited:

    per_stream_throughput  ~=  tcp_window / RTT

With a typical autotuned window (a few MB) that is only a few hundred Mbps,
*regardless of file size*. So aggregate throughput must come from running many
streams in parallel to fill the BDP of each node's NIC:

    streams_to_fill_NIC  =  NIC_bps * RTT / window_bits          (the BDP, in streams)

We fill that budget with MULTIPLE worker pods per node (pods_per_node), each an
independent rclone process — independent processes avoid a single rclone's
internal ceilings (one http.Transport, GC, lock contention) and saturate the
shared NIC better than one process. Within each pod, two rclone levers multiply:

    --transfers              : number of files copied in parallel
    --multi-thread-streams   : ranged-GET streams per file (files > cutoff)

So:  in-flight streams per node  ~=  pods_per_node * transfers * multi_thread_streams.
We size per-node from the target+BDP, divide across pods, then clamp to the
node's CPU (split across pods) and the NIC line rate.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from .config import Config

# leave this many vCPUs per node for the kubelet / CSI / system daemons
SYSTEM_CPU_HEADROOM = 8


@dataclass
class Sizing:
    # inputs echoed for the plan
    target_gbps: float
    num_nodes: int
    pods_per_node: int
    total_pods: int
    rtt_ms: float
    per_stream_mbps: float
    nic_gbps: int
    vcpu: int
    ram_gib: int

    # derived
    per_node_gbps: float
    per_node_gbps_capped: float
    bdp_bytes_per_node: float
    streams_needed_per_node: int
    per_pod_streams: int
    transfers: int                 # per pod
    multi_thread_streams: int      # per pod
    checkers: int                  # per pod
    checkers_explicit: bool        # whether --checkers is actually passed
    in_flight_per_pod: int
    in_flight_per_node: int
    worker_cpu_request: str
    worker_mem_request: str
    est_mem_gib_per_pod: float
    est_mem_gib_per_node: float

    def explain(self) -> str:
        lines = [
            "Sizing plan (grounded in s2a hardware + 150 ms BDP)",
            "-" * 62,
            f"  TARGET_GBPS (total)        : {self.target_gbps:.2f} GB/s",
            f"  nodes x pods/node          : {self.num_nodes} x "
            f"{self.pods_per_node}  = {self.total_pods} worker pods",
            f"  per-node target            : {self.per_node_gbps:.2f} GB/s "
            f"({self.per_node_gbps * 8:.1f} Gbps)",
            f"  per-node NIC line rate     : {self.nic_gbps} Gbps "
            f"({self.nic_gbps / 8:.1f} GB/s)  [90% usable cap applied]",
            f"  per-node target (capped)   : {self.per_node_gbps_capped:.2f} "
            f"GB/s ({self.per_node_gbps_capped * 8:.1f} Gbps)",
            f"  RTT                        : {self.rtt_ms:.0f} ms",
            f"  per-stream assumption      : {self.per_stream_mbps:.0f} Mbps "
            "(untuned intercontinental TCP)",
            f"  BDP per node               : "
            f"{self.bdp_bytes_per_node / 1e9:.2f} GB in flight to fill NIC",
            f"  streams needed / node      : {self.streams_needed_per_node} "
            "(incl. safety factor)",
            f"  streams / pod              : {self.per_pod_streams} "
            f"(split across {self.pods_per_node} pods)",
            "",
            "  => rclone PER POD:",
            f"       --transfers              {self.transfers}",
            f"       --multi-thread-streams   {self.multi_thread_streams}",
            (f"       --checkers               {self.checkers}"
             if self.checkers_explicit
             else "       --checkers               (applied only if "
                  "RCLONE_CHECKERS is set)"),
            f"     in-flight streams / pod    {self.in_flight_per_pod} "
            "(transfers x streams)",
            f"     pod requests               cpu={self.worker_cpu_request} "
            f"mem={self.worker_mem_request}  (~{self.est_mem_gib_per_pod:.1f} "
            "GiB actual)",
            "-" * 62,
            f"  per-node in-flight streams   : {self.in_flight_per_node} "
            f"(of {self.vcpu} vCPU, {self.ram_gib} GiB)",
            f"  fleet in-flight streams      : "
            f"{self.in_flight_per_node * self.num_nodes}",
            f"  fleet worker pods            : {self.total_pods}",
        ]
        return "\n".join(lines)


def _parse_size_to_bytes(s: str) -> int:
    s = s.strip().upper().rstrip("B")
    mult = 1
    if s.endswith("K"):
        mult, s = 1024, s[:-1]
    elif s.endswith("M"):
        mult, s = 1024 ** 2, s[:-1]
    elif s.endswith("G"):
        mult, s = 1024 ** 3, s[:-1]
    return int(float(s) * mult)


def compute_sizing(cfg: Config) -> Sizing:
    pods_per_node = cfg.effective_pods_per_node()
    total_pods = cfg.effective_num_pods()
    nic_gbps = cfg.node_nic_gbps
    vcpu = cfg.node_vcpu

    # 1) split the target across nodes, cap at 90% of NIC line rate (GB/s)
    per_node_gbps = cfg.target_gbps / cfg.num_nodes
    nic_gbps_bytes = nic_gbps / 8.0
    per_node_gbps_capped = min(per_node_gbps, 0.9 * nic_gbps_bytes)

    # 2) BDP in bytes to fill the NIC at this RTT (informational)
    rtt_s = cfg.rtt_ms / 1000.0
    bdp_bytes_per_node = (nic_gbps * 1e9 / 8.0) * rtt_s

    # 3) streams needed/node = required throughput / per-stream, * safety
    per_node_target_mbps = per_node_gbps_capped * 8 * 1000
    raw_streams = per_node_target_mbps / cfg.per_stream_mbps
    streams_needed = max(1, math.ceil(raw_streams * cfg.stream_safety))

    # 4) divide the per-node stream budget across pods
    per_pod_streams = max(1, math.ceil(streams_needed / pods_per_node))

    # 5) split per-pod streams into transfers x multi_thread_streams
    if cfg.rclone_multi_thread_streams is not None:
        mts = cfg.rclone_multi_thread_streams
    else:
        mts = min(8, max(4, per_pod_streams))

    if cfg.rclone_transfers is not None:
        transfers = cfg.rclone_transfers
    else:
        transfers = max(1, math.ceil(per_pod_streams / mts))
        # CPU clamp: transfers are I/O bound; allow ~2x oversub of the cores
        # available to THIS pod (node cores split across pods_per_node).
        cores_per_pod = max(1, vcpu // pods_per_node)
        transfers = min(transfers, 2 * cores_per_pod)

    if cfg.rclone_checkers is not None:
        checkers = cfg.rclone_checkers
    else:
        checkers = min(2 * transfers, 256)

    in_flight_per_pod = transfers * mts
    in_flight_per_node = in_flight_per_pod * pods_per_node

    # 6) memory estimate per pod: active multi-thread streams buffer ~chunk-size,
    #    plus per-transfer --buffer-size.
    chunk_b = _parse_size_to_bytes(cfg.rclone_multi_thread_chunk_size)
    buf_b = _parse_size_to_bytes(cfg.rclone_buffer_size)
    est_mem_per_pod = (in_flight_per_pod * chunk_b + transfers * buf_b) / (1024 ** 3)
    est_mem_per_node = est_mem_per_pod * pods_per_node

    # 7) resource requests (force even, dense packing): blank cfg => derive so
    #    exactly pods_per_node fit, with system headroom.
    if cfg.worker_cpu_request:
        cpu_req = cfg.worker_cpu_request
    else:
        cpu_req = str(max(1, (vcpu - SYSTEM_CPU_HEADROOM) // pods_per_node))
    if cfg.worker_mem_request:
        mem_req = cfg.worker_mem_request
    else:
        mem_req = f"{max(8, math.ceil(est_mem_per_pod * 1.5))}Gi"

    return Sizing(
        target_gbps=cfg.target_gbps,
        num_nodes=cfg.num_nodes,
        pods_per_node=pods_per_node,
        total_pods=total_pods,
        rtt_ms=cfg.rtt_ms,
        per_stream_mbps=cfg.per_stream_mbps,
        nic_gbps=nic_gbps,
        vcpu=vcpu,
        ram_gib=cfg.node_ram_gib,
        per_node_gbps=per_node_gbps,
        per_node_gbps_capped=per_node_gbps_capped,
        bdp_bytes_per_node=bdp_bytes_per_node,
        streams_needed_per_node=streams_needed,
        per_pod_streams=per_pod_streams,
        transfers=transfers,
        multi_thread_streams=mts,
        checkers=checkers,
        checkers_explicit=cfg.rclone_checkers is not None,
        in_flight_per_pod=in_flight_per_pod,
        in_flight_per_node=in_flight_per_node,
        worker_cpu_request=cpu_req,
        worker_mem_request=mem_req,
        est_mem_gib_per_pod=est_mem_per_pod,
        est_mem_gib_per_node=est_mem_per_node,
    )


if __name__ == "__main__":  # quick manual check: python -m orchestrator.sizing
    from .config import load_config
    c, _ = load_config([])
    print(compute_sizing(c).explain())
