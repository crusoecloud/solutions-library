#!/bin/bash
# Per-node health check. Run as root (dmesg).
#   node-health.sh <expected_gpus> <expected_hcas> <imex: true|false>
# Prints one line per check: CHECK | VALUE | PASS, WARN, FAIL or INFO.
# Exit: 0 no FAIL, 1 a check failed.
set -euo pipefail

EXPECTED_GPUS=${1:?expected GPU count}
EXPECTED_HCAS=${2:?expected HCA count}
USE_IMEX=${3:-false}
fails=0
warns=0

row() {
  printf '%-22s | %-60s | %s\n' "$1" "$2" "$3"
  case "$3" in
    FAIL) fails=$(( fails + 1 )) ;;
    WARN) warns=$(( warns + 1 )) ;;
  esac
}

if ! nvidia-smi -L >/dev/null 2>&1; then
  row nvidia-smi "nvidia-smi failed" FAIL
  echo "SUMMARY: $(hostname) FAIL ($fails failed, $warns warnings)"
  exit 1
fi

gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
row gpu_count "$gpus (expected $EXPECTED_GPUS)" "$([ "$gpus" -eq "$EXPECTED_GPUS" ] && echo PASS || echo FAIL)"

row driver "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)" INFO
row cuda "$(nvidia-smi | grep -o 'CUDA Version: [0-9.]*' | awk '{print $3}')" INFO
row nccl "$(dpkg-query -W -f='${Version}' libnccl2 2>/dev/null || echo 'libnccl2 not installed')" INFO

xids=$(dmesg | grep -c 'NVRM: Xid' || true)
row xid "$xids Xid messages in dmesg" "$([ "$xids" -eq 0 ] && echo PASS || echo FAIL)"

ecc=$(nvidia-smi --query-gpu=index,ecc.errors.uncorrected.volatile.total --format=csv,noheader,nounits \
  | awk -F', *' '$2 ~ /^[0-9]+$/ && $2 > 0 {printf "gpu%s=%s ", $1, $2}')
row ecc_uncorrected "${ecc:-0 on all GPUs}" "$([ -z "$ecc" ] && echo PASS || echo FAIL)"

if remap=$(nvidia-smi --query-remapped-rows=gpu_bus_id,remapped_rows.pending,remapped_rows.failure --format=csv,noheader 2>/dev/null); then
  bad=$(awk -F', *' 'tolower($2) == "yes" || tolower($3) == "yes" {printf "%s ", $1}' <<< "$remap")
  row row_remap "${bad:-no pending or failed remaps}" "$([ -z "$bad" ] && echo PASS || echo FAIL)"
else
  row row_remap "query not supported" INFO
fi

# Link generation drops at idle for power saving, so only the width is a pass/fail check
pcie=$(nvidia-smi --query-gpu=index,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits \
  | awk -F', *' '$2 != $3 {printf "gpu%s=x%s/x%s ", $1, $2, $3}')
row gpu_pcie_width "${pcie:-all GPUs at max width}" "$([ -z "$pcie" ] && echo PASS || echo FAIL)"

declare -A RATE
for dev in /sys/class/infiniband/*; do
  [ -e "$dev" ] || continue
  port=$dev/ports/1
  [ "$(cat "$port/link_layer" 2>/dev/null)" = "InfiniBand" ] || continue
  grep -q ACTIVE "$port/state" 2>/dev/null || continue
  RATE[$(basename "$dev")]=$(awk '{print int($1)}' "$port/rate")
done
if [ "${#RATE[@]}" -eq 0 ]; then
  row ib_hcas "no active InfiniBand HCA" FAIL
else
  max_rate=$(printf '%s\n' "${RATE[@]}" | sort -n | tail -1)
  mapfile -t hcas < <(for h in "${!RATE[@]}"; do [ "${RATE[$h]}" -eq "$max_rate" ] && echo "$h"; done | sort -V)
  row ib_hcas "${#hcas[@]} ACTIVE at ${max_rate} Gb/s (expected $EXPECTED_HCAS)" \
    "$([ "${#hcas[@]}" -ge "$EXPECTED_HCAS" ] && echo PASS || echo FAIL)"
  # A Virtual Function has no link status of its own (lspci: LnkSta Width x0), so VFs are
  # left out. A VM can also show a virtual link, so a narrow width is a warning only.
  narrow=""
  vfs=0
  for h in "${hcas[@]}"; do
    dev=/sys/class/infiniband/$h/device
    cur=$(cat "$dev/current_link_width" 2>/dev/null || echo 0)
    max=$(cat "$dev/max_link_width" 2>/dev/null || echo 0)
    if [ -e "$dev/physfn" ] || [ "$cur" = 0 ]; then
      vfs=$(( vfs + 1 ))
      continue
    fi
    [ "$cur" = "$max" ] || narrow+="$h=x$cur/x$max "
  done
  if [ -n "$narrow" ]; then
    row hca_pcie_width "$narrow" WARN
  elif [ "$vfs" -eq "${#hcas[@]}" ]; then
    row hca_pcie_width "not reported (VF)" INFO
  else
    note=""
    [ "$vfs" -eq 0 ] || note=", $vfs VFs not reported"
    row hca_pcie_width "all HCAs at max width$note" PASS
  fi
fi

if systemctl cat nvidia-fabricmanager >/dev/null 2>&1; then
  state=$(systemctl is-active nvidia-fabricmanager || true)
  row fabricmanager "$state" "$([ "$state" = active ] && echo PASS || echo FAIL)"
else
  row fabricmanager "not installed" INFO
fi

if [ "$USE_IMEX" = "true" ]; then
  state=$(systemctl is-active nvidia-imex || true)
  row imex "$state" "$([ "$state" = active ] && echo PASS || echo FAIL)"
fi

result=$([ "$fails" -eq 0 ] && echo PASS || echo FAIL)
echo "SUMMARY: $(hostname) $result ($fails failed, $warns warnings)"
[ "$fails" -eq 0 ]
