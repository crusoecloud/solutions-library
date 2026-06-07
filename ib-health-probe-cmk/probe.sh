#!/usr/bin/env bash
# IB Health Probe — per-HCA loopback bandwidth + single-node NCCL.
# Designed to be SKU-agnostic: discovers HCAs at runtime, infers line rate from
# sysfs, groups by NUMA, pairs within group, and exercises each HCA as both
# endpoint roles. Output is pipe-delimited so it can be grepped out of
# `kubectl logs -l job-name=ib-probe`.
#
# Env vars (all optional):
#   IB_THRESHOLD_PCT  default 90   — pass/fail floor as % of detected line rate
#   IB_DURATION       default 15   — ib_write_bw runtime (seconds) per direction
#   IB_MSG_SIZE       default 8388608 (8 MiB) — message size for bandwidth test
#   NCCL_THRESHOLD    default 350  — single-node all_reduce_perf busbw floor (GB/s)
#   IB_EXPECTED_HCAS  default 8    — expected number of active top-rate HCAs; 0 = skip count check
#   SKIP_NCCL         default 0    — set to 1 to skip the NCCL step
#   SKIP_APT          default 0    — set to 1 if perftest+numactl are already baked in

set -uo pipefail

HOST=$(hostname -s)
THRESHOLD_PCT=${IB_THRESHOLD_PCT:-90}
EXPECTED_HCAS=${IB_EXPECTED_HCAS:-8}
DURATION=${IB_DURATION:-15}
MSG_SIZE=${IB_MSG_SIZE:-8388608}
NCCL_THRESHOLD=${NCCL_THRESHOLD:-350}
SKIP_NCCL=${SKIP_NCCL:-0}
SKIP_APT=${SKIP_APT:-0}

log() { printf "INFO|%s|%s\n" "$HOST" "$*"; }
fail() { printf "ERROR|%s|%s\n" "$HOST" "$*"; }

# ---------- 1. Discover active IB HCAs ----------
declare -a HCAS
declare -A HCA_NUMA HCA_RATE
for hca_path in /sys/class/infiniband/*; do
    [ -d "$hca_path" ] || continue
    hca=$(basename "$hca_path")
    port_dir="$hca_path/ports/1"
    [ -d "$port_dir" ] || continue

    link_layer=$(cat "$port_dir/link_layer" 2>/dev/null || echo "")
    [ "$link_layer" = "InfiniBand" ] || continue

    state_num=$(awk '{print $1}' "$port_dir/state" 2>/dev/null | tr -d ':')
    [ "$state_num" = "4" ] || continue

    rate=$(awk '{print $1}' "$port_dir/rate" 2>/dev/null)
    [ -z "$rate" ] && continue

    numa=$(cat "$hca_path/device/numa_node" 2>/dev/null || echo "0")
    [ "$numa" = "-1" ] && numa=0

    HCAS+=("$hca")
    HCA_NUMA[$hca]=$numa
    HCA_RATE[$hca]=$rate
done

if [ ${#HCAS[@]} -eq 0 ]; then
    fail "no active InfiniBand HCAs found in /sys/class/infiniband"
    exit 1
fi

# Filter to the compute fabric: highest-rate HCAs only.
# On some Crusoe B200 builds, mlx5_0..3 are 100 Gbps storage/OOB IB endpoints
# that coexist with the 8x NDR400 compute HCAs. Testing those would either
# (a) skew the bandwidth verdict, or (b) hang NCCL if pinned via NCCL_IB_HCA.
# Top-rate filter is SKU-agnostic — works for NDR400 today and any future rate.
MAX_RATE=0
for h in "${HCAS[@]}"; do
    [ "${HCA_RATE[$h]}" -gt "$MAX_RATE" ] && MAX_RATE=${HCA_RATE[$h]}
done
declare -a HCAS_FILTERED HCAS_DROPPED=()
for h in "${HCAS[@]}"; do
    if [ "${HCA_RATE[$h]}" -eq "$MAX_RATE" ]; then
        HCAS_FILTERED+=("$h")
    else
        HCAS_DROPPED+=("$h@${HCA_RATE[$h]}Gbps")
    fi
done
HCAS=("${HCAS_FILTERED[@]}")

# Initialize here so the HCA count check and NCCL block below can both set it.
ANY_FAIL=0

if [ "$EXPECTED_HCAS" -gt 0 ] && [ "${#HCAS[@]}" -ne "$EXPECTED_HCAS" ]; then
    fail "HCA count mismatch: found ${#HCAS[@]} active top-rate HCAs, expected ${EXPECTED_HCAS}"
    ANY_FAIL=1
fi

log "discovered ${#HCAS[@]} active IB HCAs at top rate (${MAX_RATE} Gbps): ${HCAS[*]}"
for h in "${HCAS[@]}"; do
    log "  $h  numa=${HCA_NUMA[$h]}  rate=${HCA_RATE[$h]} Gbps"
done
if [ ${#HCAS_DROPPED[@]} -gt 0 ]; then
    log "skipping ${#HCAS_DROPPED[@]} HCAs at sub-top rate (assumed non-compute fabric): ${HCAS_DROPPED[*]}"
fi

# ---------- 2. Group by NUMA, pair within group ----------
declare -A NUMA_GROUPS
for h in "${HCAS[@]}"; do
    NUMA_GROUPS[${HCA_NUMA[$h]}]="${NUMA_GROUPS[${HCA_NUMA[$h]}]:-} $h"
done

declare -a PAIRS    # entries: "numa:hcaA:hcaB"
for numa in "${!NUMA_GROUPS[@]}"; do
    # shellcheck disable=SC2206
    group=( ${NUMA_GROUPS[$numa]} )
    n=${#group[@]}
    for ((i=0; i+1 < n; i+=2)); do
        PAIRS+=("${numa}:${group[$i]}:${group[$((i+1))]}")
    done
    if (( n % 2 == 1 )); then
        # odd HCA left in this NUMA — pair it with itself (loopback on same port).
        # This exercises the local PCIe + HCA but not a cross-HCA path.
        last=${group[$((n-1))]}
        PAIRS+=("${numa}:${last}:${last}")
    fi
done

log "discovered ${#PAIRS[@]} loopback pairs"

# ---------- 3. Single-node NCCL FIRST ----------
# Run NCCL before apt-get install, because installing perftest triggers ldconfig
# and pulls in librdmacm1t64 (Ubuntu) that replaces MLNX-OFED's librdmacm1 —
# the side effects break the CUDA runtime ↔ driver linkage. NCCL is independent
# of the IB tests and runs over NVLink anyway, so order doesn't affect results.
nccl_status="SKIPPED"
nccl_busbw="0"
ngpu=0
if [ "$SKIP_NCCL" != "1" ] && [ -x /opt/nccl-tests/build/all_reduce_perf ]; then
    ngpu=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
    if [ -z "$ngpu" ] || [ "$ngpu" -eq 0 ]; then
        log "nvidia-smi reported no GPUs — skipping NCCL"
        nccl_status="FAIL: no GPUs visible"
        ANY_FAIL=1
    else
        log "running single-node NCCL all_reduce_perf on $ngpu GPUs over NVLink"
        # KEEP NCCL_TOPO_FILE (set by the Job manifest) — on cloud-hypervisor
        # VMs the XML is needed to tell NCCL the GPU↔PCIe layout that the
        # virtualized DMI hides. Auto-discovery has been seen to hang here.
        #
        # PIN NCCL_IB_HCA to the *filtered* top-rate HCAs only — the discovery
        # step above already dropped storage/OOB endpoints, so the list here is
        # the real compute fabric. Without this pin, NCCL has previously
        # auto-picked low-rate IB endpoints (mlx5_4 Ethernet on H200, the 100G
        # storage HCAs on B200) and hung at init.
        NCCL_HCA_LIST=$(printf '%s:1,' "${HCAS[@]}" | sed 's/,$//')
        UCX_HCA_LIST=$(printf '%s:1,' "${HCAS[@]}" | sed 's/,$//')
        export NCCL_IB_HCA="$NCCL_HCA_LIST"
        # UCX auto-discovers HCAs independently of NCCL — if it picks a low-rate
        # storage HCA (mlx5_0..3 @ 100G on this build), it can hang during teardown
        # with "wireup message size exceeds max bcopy" errors. Pin UCX too.
        export UCX_NET_DEVICES="$UCX_HCA_LIST"
        export NCCL_IB_PCI_RELAXED_ORDERING=1
        export NCCL_IB_QPS_PER_CONNECTION=2
        export NCCL_IB_SPLIT_DATA_ON_QPS=0
        export NCCL_IB_MERGE_VFS=0
        export NCCL_DEBUG=WARN

        log "  NCCL_TOPO_FILE=${NCCL_TOPO_FILE:-(unset)}"
        log "  NCCL_IB_HCA=$NCCL_IB_HCA"
        log "  UCX_NET_DEVICES=$UCX_NET_DEVICES"

        # Mktemp before the IB-test mktemp lower down
        NCCL_TMPDIR=$(mktemp -d)
        nccl_log="$NCCL_TMPDIR/nccl.log"

        /opt/nccl-tests/build/all_reduce_perf \
            -b 1G -e 4G -f 2 -g "$ngpu" -n 5 -c 0 \
            >"$nccl_log" 2>&1
        nccl_rc=$?

        nccl_busbw=$(awk '
            /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+(float|half|int32|int64|double)/ {
                if ($8+0 > max) max=$8+0
            }
            END {printf "%.2f", max+0}
        ' "$nccl_log")

        if [ "$nccl_rc" != "0" ] || [ -z "$nccl_busbw" ] || \
           [ "$(awk -v b="$nccl_busbw" -v t="$NCCL_THRESHOLD" 'BEGIN{print (b<t)?1:0}')" = "1" ]; then
            # Classify common failure modes from the NCCL output for actionable reporting
            if grep -q 'system not yet initialized' "$nccl_log" 2>/dev/null; then
                # Cross-check with nvidia-smi fabric.state to confirm
                fab_state=$(nvidia-smi --query-gpu=fabric.state --format=csv,noheader 2>/dev/null | sort -u | head -1)
                nccl_status="FAIL: NVSwitch Fabric Manager not ready (fabric.state=${fab_state:-?}); run 'systemctl restart nvidia-fabricmanager' on host"
            elif grep -q 'driver version is insufficient' "$nccl_log" 2>/dev/null; then
                nccl_status="FAIL: CUDA driver/runtime version mismatch (ldconfig disturbed by apt? probe.sh must run NCCL before apt install)"
            elif grep -qE 'NCCL.*error|Connection refused|peer.*not found' "$nccl_log" 2>/dev/null; then
                nccl_status="FAIL: rc=$nccl_rc NCCL communication error"
            else
                nccl_status="FAIL: rc=$nccl_rc busbw=${nccl_busbw:-0} < ${NCCL_THRESHOLD} GB/s"
            fi
            ANY_FAIL=1
            log "NCCL FAILED — dumping last 15 lines:"
            tail -15 "$nccl_log" | while IFS= read -r line; do log "  $line"; done
        else
            nccl_status="OK"
        fi
        rm -rf "$NCCL_TMPDIR"
    fi
fi
# NCCLHEALTH line emitted at end of summary, after IB tests, for ordering consistency.

# ---------- 4. Install perftest + numactl if missing ----------
# (deferred until after NCCL because it disturbs the CUDA stack)
if [ "$SKIP_APT" != "1" ] && { ! command -v ib_write_bw >/dev/null 2>&1 || ! command -v numactl >/dev/null 2>&1; }; then
    log "installing perftest + numactl (post-NCCL, one-time per pod)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -o Acquire::Retries=2 2>/dev/null || true
    if ! apt-get install -y --no-install-recommends perftest numactl >/dev/null 2>&1; then
        fail "apt-get install perftest numactl failed"
        exit 2
    fi
fi

# ---------- 5. Per-pair ib_write_bw ----------
RESULTS_DIR=$(mktemp -d)
PORT_BASE=18515

run_loopback() {
    # $1=numa $2=server $3=client $4=run_id
    local numa=$1 srv=$2 cli=$3 run=$4
    local port=$((PORT_BASE + run * 4))
    local server_rate=${HCA_RATE[$srv]}
    local expected
    expected=$(awk -v r="$server_rate" -v p="$THRESHOLD_PCT" 'BEGIN{printf "%.1f", r*p/100}')

    # Self-loop is supported but uses different invocation
    local srv_log="$RESULTS_DIR/srv_${srv}_${cli}_${run}.log"
    local cli_log="$RESULTS_DIR/cli_${srv}_${cli}_${run}.log"

    # Server
    numactl --cpunodebind="$numa" --membind="$numa" \
        ib_write_bw -d "$srv" -F -p "$port" \
            --report_gbits -s "$MSG_SIZE" -D "$DURATION" -q 4 \
            >"$srv_log" 2>&1 &
    local srv_pid=$!
    sleep 2   # give server time to bind

    # Client
    numactl --cpunodebind="$numa" --membind="$numa" \
        ib_write_bw -d "$cli" -F -p "$port" \
            --report_gbits -s "$MSG_SIZE" -D "$DURATION" -q 4 \
            localhost \
            >"$cli_log" 2>&1

    wait "$srv_pid" 2>/dev/null || true

    # Parse: the data line in --report_gbits mode is
    #   <size> <iters> <BW_peak> <BW_avg> <MsgRate>
    # We take BW_avg (column 4) from the last data line.
    local bw
    bw=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+/ {bw=$4} END {printf "%.2f", bw+0}' "$cli_log")

    local status="OK"
    if [ -z "$bw" ] || [ "$bw" = "0.00" ]; then
        status="FAIL: no bandwidth reported (client log: $(tail -1 "$cli_log" | tr -d '\n' | cut -c1-80))"
        ANY_FAIL=1
    elif [ "$(awk -v b="$bw" -v e="$expected" 'BEGIN{print (b<e)?1:0}')" = "1" ]; then
        status="FAIL: ${bw} < ${expected} Gbps (${THRESHOLD_PCT}% of ${server_rate})"
        ANY_FAIL=1
    fi

    # role indicates which HCA the bandwidth applies to (the client measures end-to-end)
    printf "IBHEALTH|%s|%s->%s|numa=%s|%s|%s|%s\n" \
        "$HOST" "$cli" "$srv" "$numa" "$bw" "$server_rate" "$status"
}

# Run pairs across NUMA groups in parallel (one concurrent test per NUMA);
# within a NUMA group, run sequentially to avoid PCIe contention skewing results.
declare -A NUMA_QUEUE
for entry in "${PAIRS[@]}"; do
    IFS=: read -r numa _ _ <<<"$entry"
    NUMA_QUEUE[$numa]="${NUMA_QUEUE[$numa]:-} $entry"
done

run_id=0
PIDS=()
for numa in "${!NUMA_QUEUE[@]}"; do
    (
        for entry in ${NUMA_QUEUE[$numa]}; do
            IFS=: read -r n a b <<<"$entry"
            run_loopback "$n" "$a" "$b" "$run_id"
            # also reverse-direction so each HCA serves once
            if [ "$a" != "$b" ]; then
                run_loopback "$n" "$b" "$a" "$((run_id+50))"
            fi
            run_id=$((run_id+1))
        done
    ) &
    PIDS+=($!)
    run_id=$((run_id+10))
done
for p in "${PIDS[@]}"; do wait "$p"; done

# ---------- 6. Emit NCCL result (collected earlier, before apt) ----------
printf "NCCLHEALTH|%s|%s|%s|%s\n" "$HOST" "$ngpu" "$nccl_busbw" "$nccl_status"

# ---------- 7. Summary ----------
if [ "$ANY_FAIL" = "0" ]; then
    printf "SUMMARY|%s|HEALTHY|hcas=%d|pairs=%d\n" "$HOST" "${#HCAS[@]}" "${#PAIRS[@]}"
else
    printf "SUMMARY|%s|UNHEALTHY|hcas=%d|pairs=%d\n" "$HOST" "${#HCAS[@]}" "${#PAIRS[@]}"
fi

rm -rf "$RESULTS_DIR"
# IMPORTANT: always exit 0 so the K8s Job marks Complete and lets every pod
# in an Indexed/parallel Job finish. Health is reported via the FAIL/OK lines
# above — parse-results.sh sets a nonzero exit code if any FAIL is seen.
exit 0
