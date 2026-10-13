#!/usr/bin/env bash
# Generate an aria2c input file (downloads.txt) with mirror URLs for every file
# under DATA_DIR.  Mirror URL order is rotated per file so aria2c distributes
# connections evenly across all source server:port endpoints.
#
# Usage:  download-links.sh DATA_DIR PORTS DEST SOURCE_IP1 [SOURCE_IP2 ...]
#   PORTS is comma-separated, e.g. "8080,8081"
set -euo pipefail

DATA_DIR="$1"; shift
IFS=',' read -ra PORTS <<< "$1"; shift
DEST="$1";     shift
SOURCES=("$@")

OUT="/tmp/downloads.txt"
TAB=$'\t'

# Build an array of all server:port endpoints.
ENDPOINTS=()
for s in "${SOURCES[@]}"; do
  for p in "${PORTS[@]}"; do
    ENDPOINTS+=("$s:$p")
  done
done
NUM_ENDPOINTS=${#ENDPOINTS[@]}

cd "$DATA_DIR"
idx=0
find . -type f -printf '%P\n' | sort | while IFS= read -r f; do
  # Rotate which endpoint appears first so aria2c doesn't always prefer the same one.
  urls=""
  for ((j=0; j<NUM_ENDPOINTS; j++)); do
    ep="${ENDPOINTS[$(( (idx + j) % NUM_ENDPOINTS ))]}"
    urls+="http://$ep/$f${TAB}"
  done
  printf '%s\n  dir=%s\n  out=%s\n\n' "${urls%${TAB}}" "${DEST}" "$f"
  idx=$(( idx + 1 ))
done > "$OUT"
echo "Generated $(wc -l < "$OUT") lines in $OUT"
