#!/usr/bin/env bash
# scratch-raid.sh -- assemble (or, only if every member is blank, create) the local NVMe RAID0
# /dev/md/scratch and put XFS on it. Installed to /usr/local/sbin and run at every boot by
# scratch-raid.service, before scratch-local.mount.
#
#   * Members: every whole-disk NVMe namespace except the boot disk, by stable
#     /dev/disk/by-id/nvme-<model>_<serial> path (kernel nvmeXn1 names change between boots).
#     Works for emulated ("QEMU NVMe Ctrl") and passed-through physical drives alike.
#   * Guest reboot: the array is reassembled; data survives.
#   * VM stop/start, host reboot, migration: local NVMe comes back erased; the array and
#     filesystem are recreated empty.
#   * Never creates over a disk that has any signature (filesystem, partition table, foreign
#     md superblock): exits non-zero instead. 20-nvme-raid.yml wipes disks only on request.
#
# Exit: 0 array present (assembled or created) or no NVMe disks | 1 refused / failed
set -euo pipefail

NAME="${SCRATCH_RAID_NAME:-scratch}"
MD="/dev/md/$NAME"
CHUNK="${SCRATCH_RAID_CHUNK:-512K}"
log(){ echo "scratch-raid: $*"; }

udevadm settle || true

# One stable by-id path per NVMe namespace: nvme-<model>_<serial>; skip eui./nvme. WWID links,
# the _N namespace duplicates, partitions, and anything that is not a whole nvmeXnY disk.
declare -A seen=()
MEMBERS=()
for l in /dev/disk/by-id/nvme-*; do
  [ -e "$l" ] || continue
  case "$(basename "$l")" in nvme-eui.*|nvme-nvme.*) continue;; esac
  case "$l" in *-part[0-9]*|*_[0-9]) continue;; esac
  dev=$(readlink -f "$l")
  [[ "$(basename "$dev")" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue
  [ -n "${seen[$dev]:-}" ] && continue
  seen[$dev]=1; MEMBERS+=("$l")
done
IFS=$'\n' MEMBERS=($(printf '%s\n' "${MEMBERS[@]}" | sort -V)); unset IFS
[ "${#MEMBERS[@]}" -gt 0 ] || { log "no local NVMe disks found; nothing to do"; exit 0; }

root_dev=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
for m in "${MEMBERS[@]}"; do
  [ "$(basename "$(readlink -f "$m")")" != "$root_dev" ] || { log "refusing: $m is the root disk"; exit 1; }
done

# Already running (udev incremental assembly usually does this on a guest reboot).
if [ -e "$MD" ] && mdadm --detail "$MD" >/dev/null 2>&1; then
  log "$MD already active"
else
  # Assemble if the members carry our superblock.
  if mdadm --examine "${MEMBERS[@]}" 2>/dev/null | grep -qE "Name : ([^ ]*:)?$NAME( |$)"; then
    log "assembling $MD from ${#MEMBERS[@]} members"
    mdadm --assemble "$MD" "${MEMBERS[@]}"
  else
    # Create only when every member is blank (fresh or erased local NVMe).
    for m in "${MEMBERS[@]}"; do
      rc=0; blkid -p "$m" >/dev/null 2>&1 || rc=$?
      if [ "$rc" != 2 ]; then
        log "refusing to create: $m ($(readlink -f "$m")) is not blank: $(blkid -p -o export "$m" 2>/dev/null | tr '\n' ' ')"
        exit 1
      fi
    done
    log "creating RAID0 $MD over ${#MEMBERS[@]} disks, chunk $CHUNK"
    mdadm --create "$MD" --run --level=0 --raid-devices="${#MEMBERS[@]}" --chunk="$CHUNK" \
      --metadata=1.2 --name="$NAME" --homehost=any "${MEMBERS[@]}"
  fi
  udevadm settle || true
fi

# Filesystem: XFS (picks up the md stripe geometry; mkfs is instant). Only on a blank array.
rc=0; blkid -p "$MD" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then
  log "creating XFS on $MD"
  mkfs.xfs -q -K -L "$NAME" "$MD"
elif [ "$rc" = 0 ]; then
  log "$MD has $(blkid -p -s TYPE -o value "$MD") filesystem; keeping it"
else
  log "blkid failed on $MD (rc=$rc)"; exit 1
fi
