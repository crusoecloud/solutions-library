#!/usr/bin/env bash
# env_verify.sh -- per-node environment check for an MI355X RoCE VM (bundle 2.2).
#
# Runs locally on ONE node (Ansible fans it out). Read-only: changes nothing.
# Emits one line per check on stdout:
#
#     host|check|expected|actual|STATUS
#
# STATUS is PASS, FAIL, WARN (suspicious, does not fail the run unless STRICT=1)
# or INFO (no expectation configured; report-only).
# Exit code: 0 = no FAIL, 1 = at least one FAIL, 2 = usage / missing env file.
#
#   ./env_verify.sh                       # uses ./bundle-2.2.env
#   BUNDLE_ENV=/path/to/other.env ./env_verify.sh
#   STRICT=1 ./env_verify.sh              # WARN counts as FAIL
#
# Root (or passwordless sudo) is needed only for dmesg on Ubuntu (dmesg_restrict=1);
# without it the dmesg check reports WARN instead of reading the log.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_ENV="${BUNDLE_ENV:-$HERE/bundle-2.2.env}"
if [ ! -r "$BUNDLE_ENV" ]; then echo "env_verify: cannot read $BUNDLE_ENV" >&2; exit 2; fi
# shellcheck source=bundle-2.2.env
. "$BUNDLE_ENV"
export PATH="$PATH:/opt/rocm/bin:/usr/sbin:/sbin"

STRICT="${STRICT:-0}"
HOST=$(hostname -s 2>/dev/null || hostname)
FAILS=0; WARNS=0
SUDO=""
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

# ---------------------------------------------------------------- helpers ---
clean(){ printf '%s' "$*" | tr '\n|' ' /' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'; }
emit(){ # check expected actual status
  local st=$4
  [ "$st" = WARN ] && [ "$STRICT" = 1 ] && st=FAIL
  [ "$st" = FAIL ] && FAILS=$((FAILS+1))
  [ "$st" = WARN ] && WARNS=$((WARNS+1))
  printf '%s|%s|%s|%s|%s\n' "$HOST" "$1" "$(clean "$2")" "$(clean "${3:-<none>}")" "$st"
}
# whole-token version match: "7.2.0" matches "7.2.0-43" / "2.27.7.70200" but not "17.2.0"
ver_match(){ local exp re; exp=$(printf '%s' "$1" | sed 's/[.]/\\./g'); re="(^|[^0-9])${exp}([^0-9]|$)"; [[ "$2" =~ $re ]]; }
ver_check(){ # check expected actual
  if [ -z "$3" ]; then emit "$1" "${2:-any}" "not found" FAIL
  elif [ -z "$2" ]; then emit "$1" "report-only" "$3" INFO
  elif ver_match "$2" "$3"; then emit "$1" "$2" "$3" PASS
  else emit "$1" "$2" "$3" FAIL; fi
}
first_cmd(){ # print first existing executable among args (names or globs)
  local c p
  for c in "$@"; do
    p=$(command -v "$c" 2>/dev/null) && { echo "$p"; return 0; }
    for p in $c; do [ -x "$p" ] && { echo "$p"; return 0; }; done
  done
  return 1
}
dpkg_ver(){ dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }
dpkg_match(){ dpkg-query -W -f='${Package}=${Version}\n' "$1" 2>/dev/null | grep -v '=$' | tr '\n' ' '; }

# amd-smi with retry: right after boot it reports "driver not initialized" for the
# first ~2 attempts.
AMDSMI=$(first_cmd amd-smi /opt/rocm/bin/amd-smi || true)
amdsmi(){
  local i out rc
  [ -n "$AMDSMI" ] || return 127
  for i in $(seq 1 "$AMDSMI_RETRIES"); do
    out=$("$AMDSMI" "$@" 2>&1); rc=$?
    if [ $rc -eq 0 ] && ! grep -qiE 'not initiali[sz]ed|unable to initiali[sz]e|DRIVER_NOT_LOADED|AMDSMI_STATUS_INIT_ERROR' <<<"$out"; then
      printf '%s\n' "$out"; return 0
    fi
    [ "$i" -lt "$AMDSMI_RETRIES" ] && sleep "$AMDSMI_RETRY_SLEEP"
  done
  printf '%s\n' "$out"; return 1
}

# ----------------------------------------------------------------- OS/kernel -
# shellcheck disable=SC1091
osv=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
ver_check os_version_id "$OS_VERSION_ID_EXPECTED" "$osv"
ver_check kernel "$KERNEL_EXPECTED" "$(uname -r)"
emit bundle "$BUNDLE_NAME" "env file $(basename "$BUNDLE_ENV")" INFO

# --------------------------------------------------------------- versions ----
rocm=$(cat /opt/rocm/.info/version 2>/dev/null || dpkg_ver rocm-core)
ver_check rocm "$ROCM_EXPECTED" "$rocm"

ver_check amdgpu_dkms "$AMDGPU_DKMS_EXPECTED" "$(dpkg_ver amdgpu-dkms)"
ver_check amdgpu_module_loaded "$AMDGPU_MODULE_EXPECTED" "$(cat /sys/module/amdgpu/version 2>/dev/null || modinfo -F version amdgpu 2>/dev/null)"

rccl=$(dpkg_ver rccl)
[ -z "$rccl" ] && rccl=$(find /opt/rocm/lib /opt/rocm*/lib -maxdepth 1 -name 'librccl.so.*.*' 2>/dev/null | head -1)
ver_check rccl "$RCCL_EXPECTED" "$rccl"

# amd-anp (RCCL network plugin for AINIC): try dpkg first, then the install dir / library.
anp=$(dpkg_match 'amd-anp*')
if [ -z "$anp" ]; then
  anp=$(find /opt /usr/local /usr/lib -maxdepth 4 \( -iname '*anp*' -o -name 'librccl-net*.so*' \) 2>/dev/null | head -5 | tr '\n' ' ')
fi
if [ -n "$anp" ] && [ -n "$ANP_EXPECTED" ] && ! ver_match "$ANP_EXPECTED" "$anp"; then
  emit amd_anp "$ANP_EXPECTED" "present, version not in name: $anp" WARN
else
  ver_check amd_anp "$ANP_EXPECTED" "$anp"
fi

ionic_drv=$(cat /sys/module/ionic/version 2>/dev/null || modinfo -F version ionic 2>/dev/null)
ver_check ionic_driver "$IONIC_DRIVER_EXPECTED" "$ionic_drv"
emit ionic_packages "report-only" "$(dpkg_match '*ionic*')" INFO

mpirun_bin=$(first_cmd mpirun '/opt/ompi*/bin/mpirun' '/opt/openmpi*/bin/mpirun' '/usr/mpi/gcc/openmpi*/bin/mpirun' '/opt/rocm/ompi/bin/mpirun' || true)
ompi=""; [ -n "$mpirun_bin" ] && ompi="$("$mpirun_bin" --version 2>&1 | head -1) ($mpirun_bin)"
ver_check openmpi "$OPENMPI_EXPECTED" "$ompi"

ucx_bin=$(first_cmd ucx_info '/opt/ucx*/bin/ucx_info' '/opt/rocm/ucx/bin/ucx_info' || true)
ucx=""; [ -n "$ucx_bin" ] && ucx=$("$ucx_bin" -v 2>&1 | grep -m1 -iE 'version' )
ver_check ucx "$UCX_EXPECTED" "$ucx"

vast=$(dpkg_match '*vastnfs*')
[ -z "$vast" ] && command -v vastnfs-ctl >/dev/null 2>&1 && vast=$(vastnfs-ctl status 2>&1 | grep -m1 -iE 'version')
ver_check vastnfs "$VASTNFS_EXPECTED" "$vast"

# ------------------------------------------------------------------- GPUs ----
if [ -z "$AMDSMI" ]; then
  emit amdsmi_present "amd-smi in PATH" "not found" FAIL
else
  lst=$(amdsmi list); rc=$?
  ngpu=$(grep -cE '^GPU:[[:space:]]*[0-9]+' <<<"$lst")
  if [ $rc -ne 0 ]; then emit gpu_count "$GPU_COUNT_EXPECTED" "amd-smi failed after $AMDSMI_RETRIES tries: $(head -2 <<<"$lst")" FAIL
  elif [ "$ngpu" = "$GPU_COUNT_EXPECTED" ]; then emit gpu_count "$GPU_COUNT_EXPECTED" "$ngpu" PASS
  else emit gpu_count "$GPU_COUNT_EXPECTED" "$ngpu" FAIL; fi

  # GPU firmware: parse `amd-smi firmware` text per "GPU: N" block, normalise
  # leading zeros (01.25.17.10 == 1.25.17.10). Set GPU_FW_ID in bundle-2.2.env to pin one FW_ID.
  fw=$(amdsmi firmware)
  if [ -n "$GPU_FW_EXPECTED" ]; then
    res=$(awk -v want="$GPU_FW_EXPECTED" -v fid="$GPU_FW_ID" '
      function norm(v,  n,a,i,o){ n=split(v,a,"."); o=""; for(i=1;i<=n;i++){ sub(/^0+/,"",a[i]); if(a[i]=="")a[i]="0"; o=o (i>1?".":"") a[i] } return o }
      BEGIN{ split(want,_w,"."); W=norm(want) }
      /^GPU:[[:space:]]*[0-9]+/ { g=$2; gpus[g]=1; idok=(fid=="") ; next }
      fid!="" && /FW_ID/ { idok=(index($0,fid)>0) }
      { if(g=="" || !idok) next
        line=$0
        while (match(line,/[0-9]+(\.[0-9]+)+/)) { v=substr(line,RSTART,RLENGTH); if(norm(v)==W) hit[g]=1; line=substr(line,RSTART+RLENGTH) } }
      END{ n=0; h=0; miss=""; for(g in gpus){n++; if(g in hit)h++; else miss=miss " " g} printf "%d/%d%s\n", h, n, (miss!=""?" missing on GPU" miss:"") }' <<<"$fw")
    have=${res%%/*}; tot=${res#*/}; tot=${tot%% *}
    if [ "$tot" -gt 0 ] 2>/dev/null && [ "$have" = "$tot" ]; then emit gpu_fw "$GPU_FW_EXPECTED${GPU_FW_ID:+ ($GPU_FW_ID)}" "$res GPUs" PASS
    else emit gpu_fw "$GPU_FW_EXPECTED${GPU_FW_ID:+ ($GPU_FW_ID)}" "$res GPUs" FAIL; fi
  fi

  # Uncorrectable ECC must be 0 (correctable is reported, not gated).
  ecc_json=$(amdsmi metric --ecc --json)
  ecc=$(python3 - "$ecc_json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("PARSE_ERROR"); sys.exit(0)
ue = {}; ce = {}
def num(v):
    if isinstance(v, dict): v = v.get("value", 0)
    try: return int(v)
    except Exception: return 0
def walk(o, gpu):
    if isinstance(o, dict):
        if "gpu" in o and isinstance(o["gpu"], int): gpu = o["gpu"]
        for k, v in o.items():
            kl = k.lower()
            if isinstance(v, (dict, list)) and not (isinstance(v, dict) and "value" in v):
                walk(v, gpu); continue
            if "uncorrectable" in kl and "total" in kl: ue[gpu] = ue.get(gpu, 0) + num(v)
            elif "correctable" in kl and "total" in kl: ce[gpu] = ce.get(gpu, 0) + num(v)
    elif isinstance(o, list):
        for i, x in enumerate(o): walk(x, gpu if gpu is not None else i)
walk(d, None)
bad = ",".join(f"gpu{g}={n}" for g, n in sorted(ue.items(), key=lambda t: str(t[0])) if n)
print(f"{sum(ue.values())} {sum(ce.values())} {len(ue)} {bad or '-'}")
PY
)
  if [ -z "$ecc" ] || [ "${ecc%% *}" = PARSE_ERROR ]; then
    emit ecc_uncorrectable "0" "could not parse amd-smi metric --ecc --json" WARN
  else
    read -r ue_t ce_t n_g bad_g <<<"$ecc"
    if [ "$n_g" = 0 ]; then emit ecc_uncorrectable "0" "no ECC fields in amd-smi output" WARN
    elif [ "$ue_t" = 0 ]; then emit ecc_uncorrectable "0" "0 on $n_g GPUs (correctable total $ce_t)" PASS
    else emit ecc_uncorrectable "0" "$ue_t ($bad_g; correctable total $ce_t)" FAIL; fi
  fi
fi
# Second opinion from RAS sysfs (ue: lines)
ras_ue=0; ras_n=0
for f in /sys/class/drm/card*/device/ras/*_err_count; do
  [ -r "$f" ] || continue
  ras_n=$((ras_n+1)); v=$(awk '/^ue:/{print $2}' "$f" 2>/dev/null); ras_ue=$((ras_ue + ${v:-0}))
done
if [ "$ras_n" -gt 0 ]; then
  if [ "$ras_ue" = 0 ]; then emit ecc_ras_sysfs_ue "0" "0 across $ras_n counters" PASS
  else emit ecc_ras_sysfs_ue "0" "$ras_ue" FAIL; fi
fi

# GDR prerequisites: amdgpu registers P2P DMA memory per GPU; dmabuf in kernel.
if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ] || [ "$(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null)" = 0 ]; then
  DMESG=$($SUDO dmesg 2>/dev/null)
else
  DMESG=""
fi
if [ -n "$DMESG" ]; then
  p2p=$(grep -c 'added peer-to-peer DMA memory' <<<"$DMESG")
  if [ "$p2p" -ge "$GPU_COUNT_EXPECTED" ]; then emit gdr_p2p_dma "$GPU_COUNT_EXPECTED" "$p2p" PASS
  else emit gdr_p2p_dma "$GPU_COUNT_EXPECTED" "$p2p (GPU-Direct RDMA may be unavailable)" WARN; fi
fi
if [ -d /sys/class/dma_heap ] || grep -q '^CONFIG_DMA_SHARED_BUFFER=y' "/boot/config-$(uname -r)" 2>/dev/null; then
  emit dmabuf_kernel "present" "present" PASS
else emit dmabuf_kernel "present" "no /sys/class/dma_heap and no CONFIG_DMA_SHARED_BUFFER" WARN; fi

# ------------------------------------------------------------------ rails ----
RAILS=(); for p in /sys/class/infiniband/"${RAIL_PREFIX}"*; do [ -e "$p" ] && RAILS+=("${p##*/}"); done
netdev_of(){ local x; for x in /sys/class/infiniband/"$1"/device/net/*; do [ -e "$x" ] && { echo "${x##*/}"; return; }; done; }
if [ "${#RAILS[@]}" = "$RAIL_COUNT_EXPECTED" ]; then emit rail_count "$RAIL_COUNT_EXPECTED" "${#RAILS[@]}" PASS
else emit rail_count "$RAIL_COUNT_EXPECTED" "${#RAILS[@]} (${RAILS[*]:-none})" FAIL; fi

fwset=""
for d in "${RAILS[@]}"; do
  P=/sys/class/infiniband/$d/ports/1
  st=$(awk '{print $NF}' "$P/state" 2>/dev/null)
  ph=$(cut -d: -f2- "$P/phys_state" 2>/dev/null | tr -d ' ')
  if [ "$st" = ACTIVE ] && [ "$ph" = LinkUp ]; then emit "$d:port_state" "PORT_ACTIVE/LinkUp" "$st/$ph" PASS
  else emit "$d:port_state" "PORT_ACTIVE/LinkUp" "${st:-?}/${ph:-?}" FAIL; fi

  gid=$(cat "$P/gids/$GID_INDEX" 2>/dev/null)
  gty=$(cat "$P/gid_attrs/types/$GID_INDEX" 2>/dev/null)
  if [ -z "$gid" ] || [ "$gid" = "0000:0000:0000:0000:0000:0000:0000:0000" ] || [[ "$gid" == fe80:* ]]; then
    emit "$d:gid$GID_INDEX" "${GID_PREFIX_EXPECTED:-global}* ${GID_TYPE_EXPECTED}" "${gid:-missing} ${gty}" FAIL
  elif [ -n "$GID_PREFIX_EXPECTED" ] && [[ "$gid" != "$GID_PREFIX_EXPECTED"* ]]; then
    emit "$d:gid$GID_INDEX" "${GID_PREFIX_EXPECTED}* ${GID_TYPE_EXPECTED}" "$gid $gty" FAIL
  elif [ -n "$GID_TYPE_EXPECTED" ] && [ "$gty" != "$GID_TYPE_EXPECTED" ]; then
    emit "$d:gid$GID_INDEX" "${GID_PREFIX_EXPECTED:-global}* ${GID_TYPE_EXPECTED}" "$gid ${gty:-?}" FAIL
  else
    emit "$d:gid$GID_INDEX" "${GID_PREFIX_EXPECTED:-global}* ${GID_TYPE_EXPECTED}" "$gid $gty" PASS
  fi

  fwv=$(cat "/sys/class/infiniband/$d/fw_ver" 2>/dev/null)
  fwset="$fwset $fwv"
  ver_check "$d:fw_ver" "$IONIC_FW_EXPECTED" "$fwv"

  ifc=$(netdev_of "$d")
  if [ -z "$ifc" ]; then
    emit "$d:netdev" "present" "none" FAIL
  else
    mtu=$(cat "/sys/class/net/$ifc/mtu" 2>/dev/null)
    if [ -z "$RAIL_MTU_EXPECTED" ]; then emit "$d:mtu" "report-only" "$ifc mtu=$mtu" INFO
    elif [ "$mtu" = "$RAIL_MTU_EXPECTED" ]; then emit "$d:mtu" "$RAIL_MTU_EXPECTED" "$ifc mtu=$mtu" PASS
    else emit "$d:mtu" "$RAIL_MTU_EXPECTED" "$ifc mtu=$mtu" FAIL; fi
    # per-interface ndisc_notify: a netdev created before the sysctl.d file was
    # applied keeps the old value even after `sysctl --system` sets all/default.
    nd=$(cat "/proc/sys/net/ipv6/conf/$ifc/ndisc_notify" 2>/dev/null)
    if [ "$nd" = 1 ]; then emit "$d:ndisc_notify" "1" "$ifc=$nd" PASS
    else emit "$d:ndisc_notify" "1" "$ifc=${nd:-?} (flap rail or reboot after fixing sysctl.d)" WARN; fi
  fi

  # PCIe width: a rail trained at x8 caps at ~223 Gb/s; that is a hardware issue, not tuning.
  dev=/sys/class/infiniband/$d/device
  cw=$(cat "$dev/current_link_width" 2>/dev/null); mw=$(cat "$dev/max_link_width" 2>/dev/null)
  cs=$(cat "$dev/current_link_speed" 2>/dev/null); ms=$(cat "$dev/max_link_speed" 2>/dev/null)
  if [ -n "$cw" ] && [ -n "$mw" ]; then
    if [ "$cw" = "$mw" ] && [ "$cs" = "$ms" ]; then emit "$d:pcie_link" "x$mw $ms" "x$cw $cs" PASS
    elif [ "$PCIE_WIDTH_ENFORCE" = 1 ]; then emit "$d:pcie_link" "x$mw $ms" "x$cw $cs" FAIL
    else emit "$d:pcie_link" "x$mw $ms" "x$cw $cs" WARN; fi
  fi
done
nfw=$(tr ' ' '\n' <<<"$fwset" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [ "${#RAILS[@]}" -gt 0 ]; then
  if [ "$nfw" = 1 ]; then emit ionic_fw_uniform "1 version" "$(tr ' ' '\n' <<<"$fwset" | grep -v '^$' | sort -u)" PASS
  else emit ionic_fw_uniform "1 version" "$(tr ' ' '\n' <<<"$fwset" | grep -v '^$' | sort | uniq -c | tr '\n' ' ')" FAIL; fi
fi

# GPU PCIe width (via KFD topology -> BDF)
for n in /sys/class/kfd/kfd/topology/nodes/*; do
  [ "$(awk '/^simd_count/{print $2}' "$n/properties" 2>/dev/null)" -gt 0 ] 2>/dev/null || continue
  dom=$(awk '/^domain/{print $2}' "$n/properties"); loc=$(awk '/^location_id/{print $2}' "$n/properties")
  bdf=$(printf '%04x:%02x:%02x.%x' "$dom" $((loc>>8)) $(((loc>>3)&31)) $((loc&7)))
  pd=/sys/bus/pci/devices/$bdf
  cw=$(cat "$pd/current_link_width" 2>/dev/null); mw=$(cat "$pd/max_link_width" 2>/dev/null)
  [ -n "$cw" ] && [ -n "$mw" ] || continue
  if [ "$cw" = "$mw" ]; then emit "gpu_$bdf:pcie_width" "x$mw" "x$cw" PASS
  else emit "gpu_$bdf:pcie_width" "x$mw" "x$cw" WARN; fi
done

# --------------------------------------------------------------- sysctls -----
for kv in $SYSCTL_EXPECT; do
  k=${kv%%=*}; v=${kv#*=}
  live=$(sysctl -n "$k" 2>/dev/null)
  if [ "$live" = "$v" ]; then emit "sysctl:$k" "$v" "$live" PASS
  else emit "sysctl:$k" "$v" "${live:-unset}" "$SYSCTL_SEVERITY"; fi
  persisted=$(grep -lsE "^[[:space:]]*${k//./\\.}[[:space:]]*=[[:space:]]*${v}[[:space:]]*$" /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | head -1)
  if [ -n "$persisted" ]; then emit "sysctl_persisted:$k" "$v in /etc/sysctl.d" "$persisted" PASS
  else emit "sysctl_persisted:$k" "$v in /etc/sysctl.d" "not persisted (lost on reboot)" "$SYSCTL_SEVERITY"; fi
done

# ---------------------------------------------------------- RDMA userland ----
ml=$(ulimit -l)
if [ "$ml" = unlimited ]; then emit memlock "unlimited" "$ml ($(id -un))" PASS
else emit memlock "unlimited" "$ml KiB ($(id -un)) -- ibv_reg_mr may fail" WARN; fi
IBWB=$(first_cmd ib_write_bw /opt/rocm/bin/ib_write_bw || true)
if [ -z "$IBWB" ]; then emit perftest "ib_write_bw" "not found" FAIL
else
  emit perftest "ib_write_bw" "$IBWB" PASS
  h=$("$IBWB" --help 2>&1)
  if grep -q 'use_rocm' <<<"$h"; then
    emit perftest_rocm "--use_rocm" "supported$(grep -q 'use_rocm_dmabuf' <<<"$h" && echo ' (+ --use_rocm_dmabuf)')" PASS
  else emit perftest_rocm "--use_rocm" "not built with ROCm (GPU matrix unavailable)" WARN; fi
fi
if [ -r "/boot/config-$(uname -r)" ]; then emit boot_config "/boot/config-$(uname -r)" "present" PASS
else emit boot_config "/boot/config-$(uname -r)" "missing (perftest aborts before binding its port)" WARN; fi

# ------------------------------------------------------------------ dmesg ----
if [ -z "$DMESG" ]; then
  emit dmesg_errors "0 matches" "unreadable (need root or passwordless sudo)" WARN
else
  hits=$(grep -iE "$DMESG_FAIL_REGEX" <<<"$DMESG")
  [ -n "$DMESG_IGNORE_REGEX" ] && hits=$(grep -viE "$DMESG_IGNORE_REGEX" <<<"$hits")
  nh=$(grep -c . <<<"$hits")
  if [ "$nh" = 0 ]; then emit dmesg_errors "0 matches" "0" PASS
  else emit dmesg_errors "0 matches" "$nh, first: $(head -1 <<<"$hits" | cut -c1-200)" FAIL; fi
fi

# ---------------------------------------------------------------- summary ----
printf '%s|summary|0 FAIL|%d FAIL, %d WARN|%s\n' "$HOST" "$FAILS" "$WARNS" "$([ "$FAILS" = 0 ] && echo PASS || echo FAIL)"
[ "$FAILS" = 0 ]
