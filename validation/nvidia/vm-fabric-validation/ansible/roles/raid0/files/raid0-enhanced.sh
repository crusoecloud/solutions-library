#!/bin/bash
set -euo pipefail
# Runs as root from raid0.service (early boot) or Ansible with become, so no sudo.
# Never re-creates an existing array: --create runs only when every NVMe disk is blank.
# In the worst case /raid0 is left unmounted with an error; no disk is overwritten.

MD=/dev/md/ephemeral

# nvme-* links under /dev/disk/by-id (no partitions), one per backing device
find_nvme() {
    nvme_devices=()
    local -A seen=()
    local symlink target
    for symlink in /dev/disk/by-id/nvme-*; do
        [ -e "$symlink" ] || continue
        [[ $symlink =~ (_[0-9]+|part[0-9]+)$ ]] && continue
        target=$(readlink -f "$symlink")
        [ -n "${seen[$target]:-}" ] && continue
        seen[$target]=1
        nvme_devices+=("$symlink")
    done
}

# Let udev finish the device links and its own md auto-assembly before deciding anything
udevadm settle --timeout=120 || echo "warning: udevadm settle timed out"

# Wait up to 60 s until NVMe links exist and their count is stable across two checks
prev=-1
for _ in $(seq 1 30); do
    find_nvme
    if [ "${#nvme_devices[@]}" -gt 0 ] && [ "${#nvme_devices[@]}" -eq "$prev" ]; then
        break
    fi
    prev=${#nvme_devices[@]}
    sleep 2
    udevadm settle --timeout=10 || true
done

num_nvme=${#nvme_devices[@]}
if [ "$num_nvme" -eq 0 ]; then
    echo "error: no NVMe drives were detected under /dev/disk/by-id/. Exiting."
    exit 1
fi
echo "info: found $num_nvme NVMe drive(s): ${nvme_devices[*]}"

if [ -b "$MD" ]; then
    echo "info: $MD already exists"
else
    # Disks with any signature: md member, file system or partition table
    not_blank=()
    for dev in "${nvme_devices[@]}"; do
        if blkid -p "$dev" >/dev/null 2>&1; then
            not_blank+=("$dev")
        fi
    done

    if [ "${#not_blank[@]}" -gt 0 ]; then
        echo "info: $MD is missing and ${#not_blank[@]} disk(s) are in use; trying to assemble"
        if ! mdadm --assemble "$MD" "${nvme_devices[@]}"; then
            echo "error: could not assemble $MD, and these disks are not blank: ${not_blank[*]}"
            echo "error: not creating a new array, so no data is overwritten. Check /proc/mdstat and 'mdadm --examine'."
            exit 1
        fi
        echo "info: assembled $MD"
    else
        echo "info: all NVMe disks are blank; creating $MD"
        if ! mdadm --create "$MD" \
            --run \
            --force \
            --name=ephemeral \
            --level=0 \
            --raid-devices="$num_nvme" \
            --homehost=any \
            "${nvme_devices[@]}"; then
            echo "error: failed to create $MD"
            exit 1
        fi
    fi
    udevadm settle --timeout=60 || true
fi

# Format only an array without a file system (a newly created one)
if ! blkid -p -u filesystem "$MD" > /dev/null 2>&1; then
    echo "info: creating xfs fs on $MD"
    mkfs.xfs "$MD"
else
    echo "info: $MD is already formatted with an xfs fs"
fi
