#!/usr/bin/env bash
# run_fio.sh -- storage smoke benchmark: the local NVMe RAID0 (/scratch/local) vs the OS disk.
# Every file fio writes lives in a per-run directory that is removed when each job ends
# (unlink=1) and again on exit, including on Ctrl-C / errors, so no space is left behind.
#
# Jobs (each time-based, direct I/O, libaio):
#   large_read_16M    sequential read, 16 MiB blocks       (model-weight style loads)
#   seq_read_1M       sequential read, 1 MiB blocks
#   seq_write_1M      sequential write, 1 MiB blocks
#   rand_read_4k      random read, 4 KiB, QD64
#   rand_write_4k     random write, 4 KiB, QD64
#   mixed_70r30w_4k   random 70% read / 30% write, 4 KiB
#   small_files_write many 16 KiB-1 MiB files written (metadata + small I/O)
#   small_files_read  the same files read back
#
# Usage: run_fio.sh [-t name:path]... [-r SECONDS] [-o RESULTS_DIR]
#   default targets: scratch:/scratch/local (only if it is a mount point)  os:/var/tmp
#   -r runtime per job (default 20)
# Env: FIO_JOBS (numjobs, 4), FIO_SIZE_GB (per-job file size on scratch, 8; capped on small
#   targets to 20% of free space), FIO_SMALL_FILES (files per job, 2000)
#
# Output: FIO|<host>|<target>|<job>|read_MBps|write_MBps|read_iops|write_iops|read_p99_us|write_p99_us
# Exit: 0 ran | 2 fio missing / no usable target
set -uo pipefail

RUNTIME=20; RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"; TARGETS=()
while getopts "t:r:o:h" o; do
  case "$o" in t) TARGETS+=("$OPTARG");; r) RUNTIME="$OPTARG";; o) RESULTS_DIR="$OPTARG";; *) sed -n '2,26p' "$0"; exit 0;; esac
done
command -v fio >/dev/null || { echo "FIO_ERROR|$(hostname -s)|fio not installed"; exit 2; }
if [ "${#TARGETS[@]}" -eq 0 ]; then
  mountpoint -q /scratch/local && TARGETS+=("scratch:/scratch/local")
  TARGETS+=("os:/var/tmp")
fi

HOST=$(hostname -s); NJ="${FIO_JOBS:-4}"; SMALLN="${FIO_SMALL_FILES:-2000}"
mkdir -p "$RESULTS_DIR"
WORKDIRS=()
cleanup(){ for d in "${WORKDIRS[@]:-}"; do [ -n "$d" ] && rm -rf -- "$d"; done; }
trap cleanup EXIT INT TERM

for t in "${TARGETS[@]}"; do
  name="${t%%:*}"; path="${t#*:}"
  [ -d "$path" ] && [ -w "$path" ] || { echo "FIO_ERROR|$HOST|$name|$path not writable"; continue; }
  wd="$path/fio-smoke-$HOST-$$"; mkdir -p "$wd"; WORKDIRS+=("$wd")

  # Per-job file size: FIO_SIZE_GB, capped so NJ files use <= 20% of the target's free space.
  free_gb=$(df -BG --output=avail "$path" | tail -1 | tr -dc '0-9')
  size_gb="${FIO_SIZE_GB:-8}"
  cap=$(( free_gb / 5 / NJ )); [ "$cap" -lt 1 ] && cap=1
  [ "$size_gb" -gt "$cap" ] && size_gb=$cap
  dev=$(findmnt -n -o SOURCE --target "$path")
  echo "== $HOST $name: $path on $dev, ${NJ} jobs x ${size_gb}G, ${RUNTIME}s per job"

  common=(--directory="$wd" --direct=1 --ioengine=libaio --group_reporting --numjobs="$NJ"
          --time_based --runtime="$RUNTIME" --ramp_time=3 --unlink=1 --output-format=json)
  run(){  # run <job> <fio args...>
    local job="$1"; shift
    local out="$RESULTS_DIR/fio-$HOST-$name-$job.json"
    fio --name="$job" "${common[@]}" "$@" > "$out" 2> "$out.err" || { echo "FIO_ERROR|$HOST|$name|$job failed: $(head -c 200 "$out.err")"; return; }
    python3 - "$out" "$HOST" "$name" "$job" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); j = d["jobs"][0]
def side(k):
    s = j[k]; p = s.get("clat_ns", {}).get("percentile", {})
    p99 = p.get("99.000000", 0) / 1000.0
    return s["bw_bytes"] / 1e6, s["iops"], p99
r, w = side("read"), side("write")
print(f"FIO|{sys.argv[2]}|{sys.argv[3]}|{sys.argv[4]}|{r[0]:.0f}|{w[0]:.0f}|{r[1]:.0f}|{w[1]:.0f}|{r[2]:.0f}|{w[2]:.0f}")
PY
  }
  S="--size=${size_gb}G"
  run large_read_16M   --rw=read      --bs=16M --iodepth=16 "$S"
  run seq_read_1M      --rw=read      --bs=1M  --iodepth=32 "$S"
  run seq_write_1M     --rw=write     --bs=1M  --iodepth=32 "$S"
  run rand_read_4k     --rw=randread  --bs=4k  --iodepth=64 "$S"
  run rand_write_4k    --rw=randwrite --bs=4k  --iodepth=64 "$S"
  run mixed_70r30w_4k  --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 "$S"
  # Small files: SMALLN files per job of 16 KiB-1 MiB; written, then read back (not time-based).
  smallc=(--directory="$wd/small" --direct=1 --ioengine=libaio --group_reporting --numjobs="$NJ"
          --nrfiles="$SMALLN" --filesize=16k-1m --bs=64k --iodepth=8 --file_service_type=random
          --openfiles=64 --output-format=json)
  mkdir -p "$wd/small"
  for j in small_files_write small_files_read; do
    rw=write; [ "$j" = small_files_read ] && rw=read
    out="$RESULTS_DIR/fio-$HOST-$name-$j.json"
    extra=(); [ "$rw" = read ] && extra=(--unlink=1)
    if fio --name=small "${smallc[@]}" --rw="$rw" "${extra[@]}" > "$out" 2> "$out.err"; then
      python3 - "$out" "$HOST" "$name" "$j" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))["jobs"][0]
def side(k):
    s = j[k]; p = s.get("clat_ns", {}).get("percentile", {})
    return s["bw_bytes"] / 1e6, s["iops"], p.get("99.000000", 0) / 1000.0
r, w = side("read"), side("write")
print(f"FIO|{sys.argv[2]}|{sys.argv[3]}|{sys.argv[4]}|{r[0]:.0f}|{w[0]:.0f}|{r[1]:.0f}|{w[1]:.0f}|{r[2]:.0f}|{w[2]:.0f}")
PY
    else
      echo "FIO_ERROR|$HOST|$name|$j failed: $(head -c 200 "$out.err")"
    fi
  done
  rm -rf -- "$wd"
done
# Belt and braces: nothing left behind.
for d in "${WORKDIRS[@]:-}"; do [ -e "$d" ] && echo "FIO_ERROR|$HOST|leftover $d (removing)"; done
