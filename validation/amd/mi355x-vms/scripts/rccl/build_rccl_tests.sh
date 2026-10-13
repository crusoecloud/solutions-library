#!/usr/bin/env bash
# build_rccl_tests.sh -- build rccl-tests (MPI=1) against the image's ROCm/RCCL if the
# binaries are not already present. Run it on EVERY node (mpirun execs the same path on
# all hosts), e.g. from an Ansible task, before run_rccl_mi355x.sh.
#
#   build_rccl_tests.sh            # no-op if rccl-tests is found (prints its dir)
#   FORCE=1 build_rccl_tests.sh    # rebuild
#
# Env:
#   RCCL_TESTS_PREFIX  checkout dir                      (default ~/rccl-tests; binaries in build/)
#   RCCL_TESTS_REPO    git URL                           (default https://github.com/ROCm/rccl-tests.git)
#   RCCL_TESTS_REF     branch/tag/commit                 (default: repo default branch)
#   ROCM_PATH          ROCm root, also used as RCCL home (default /opt/rocm)
#   RCCL_HOME          RCCL install (include/rccl, lib)  (default $ROCM_PATH)
#   MPI_HOME           OpenMPI root with include/mpi.h   (default: auto-detect)
#   GPU_TARGETS        offload arch                      (default gfx950 = MI355X)
#   SMOKE=0            skip the single-process 8-GPU smoke run after building
#
# Optional fallback for images without rccl-tests: builds rccl-tests with MPI=1 against
# the image's RCCL in /opt/rocm (binaries in <checkout>/build), so the test exercises
# exactly what the image ships.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ROCM_PATH:=/opt/rocm}"; : "${RCCL_HOME:=$ROCM_PATH}"; : "${GPU_TARGETS:=gfx950}"
: "${RCCL_TESTS_PREFIX:=$HOME/rccl-tests}"
: "${RCCL_TESTS_REPO:=https://github.com/ROCm/rccl-tests.git}"
log(){ printf '[build_rccl_tests] %s\n' "$*" >&2; }
die(){ log "ERROR: $*"; exit 1; }

# shellcheck source=rccl_env.sh
source "$HERE/rccl_env.sh" 2>/dev/null || true   # only for the detection helpers

if [ "${FORCE:-0}" != 1 ]; then
  if d=$(rccl_find_tests_dir); then
    log "rccl-tests already present: $d"
    echo "$d"; exit 0
  fi
fi

# ---- prerequisites
[ -x "$ROCM_PATH/bin/hipcc" ] || die "hipcc not found under $ROCM_PATH"
[ -f "$RCCL_HOME/include/rccl/rccl.h" ] || [ -f "$RCCL_HOME/include/rccl.h" ] || die "rccl.h not found under $RCCL_HOME/include"
ls "$RCCL_HOME"/lib/librccl.so* >/dev/null 2>&1 || die "librccl.so not found under $RCCL_HOME/lib"
command -v git >/dev/null || die "git not installed"
command -v make >/dev/null || die "make not installed (apt-get install build-essential)"

# OpenMPI root that has include/mpi.h + lib/libmpi.so. Ubuntu's system OpenMPI keeps them
# under /usr/lib/x86_64-linux-gnu/openmpi, not /usr.
find_mpi_dev(){
  local c
  for c in ${MPI_HOME:-} /opt/ompi /opt/openmpi /opt/ompi/install /usr/lib/x86_64-linux-gnu/openmpi /usr/mpi/gcc/openmpi-* /usr/local /usr; do
    [ -f "$c/include/mpi.h" ] && ls "$c"/lib/libmpi.so* >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}
MPI_DEV=$(find_mpi_dev) || die "no OpenMPI headers found (need include/mpi.h + lib/libmpi.so; try: sudo apt-get install libopenmpi-dev, or set MPI_HOME)"
log "ROCm=$ROCM_PATH RCCL=$RCCL_HOME MPI=$MPI_DEV arch=$GPU_TARGETS -> $RCCL_TESTS_PREFIX"

# ---- source
if [ -d "$RCCL_TESTS_PREFIX/.git" ]; then
  git -C "$RCCL_TESTS_PREFIX" fetch --quiet --all --tags || log "WARNING: git fetch failed; building the existing checkout"
else
  git clone --quiet "$RCCL_TESTS_REPO" "$RCCL_TESTS_PREFIX"
fi
[ -n "${RCCL_TESTS_REF:-}" ] && git -C "$RCCL_TESTS_PREFIX" checkout --quiet "$RCCL_TESTS_REF"
log "rccl-tests at $(git -C "$RCCL_TESTS_PREFIX" describe --always --dirty 2>/dev/null || echo '?')"

# ---- build (MPI=1, HIP/NCCL homes)
make -C "$RCCL_TESTS_PREFIX" clean >/dev/null 2>&1 || true
make -C "$RCCL_TESTS_PREFIX" -j "$(nproc)" \
  MPI=1 MPI_HOME="$MPI_DEV" HIP_HOME="$ROCM_PATH" ROCM_PATH="$ROCM_PATH" \
  NCCL_HOME="$RCCL_HOME" CUSTOM_RCCL_LIB="$RCCL_HOME/lib/librccl.so" \
  GPU_TARGETS="$GPU_TARGETS" AMDGPU_TARGETS="$GPU_TARGETS"

OUTDIR="$RCCL_TESTS_PREFIX/build"
for b in all_reduce_perf all_gather_perf reduce_scatter_perf alltoall_perf; do
  [ -x "$OUTDIR/$b" ] || die "build finished but $OUTDIR/$b is missing"
done

# ---- verify: links the bundle's RCCL, has gfx950 code objects
ldd "$OUTDIR/all_reduce_perf" | grep -E 'librccl|libmpi' | sed 's/^/  /' >&2 || true
if ldd "$OUTDIR/all_reduce_perf" | grep -q 'librccl.*not found'; then die "librccl not resolvable; add $RCCL_HOME/lib to LD_LIBRARY_PATH"; fi
if command -v "$ROCM_PATH/bin/roc-obj-ls" >/dev/null 2>&1; then
  "$ROCM_PATH/bin/roc-obj-ls" "$OUTDIR/all_reduce_perf" 2>/dev/null | grep -q "$GPU_TARGETS" \
    || log "WARNING: no $GPU_TARGETS code object found in all_reduce_perf (check GPU_TARGETS handling in this rccl-tests version)"
elif ! grep -aq "$GPU_TARGETS" "$OUTDIR/all_reduce_perf"; then
  log "WARNING: string $GPU_TARGETS not found in all_reduce_perf; it may not run on MI355X"
fi

# ---- smoke: one process, 8 GPUs, no network (fails fast on a wrong arch / broken RCCL)
if [ "${SMOKE:-1}" = 1 ]; then
  log "smoke: all_reduce_perf -g 8, 64M-256M, single process"
  if out=$(NCCL_TOPO_FILE="${NCCL_TOPO_FILE:-}" timeout 300 "$OUTDIR/all_reduce_perf" -b 64M -e 256M -f 2 -g 8 -n 5 -w 2 -c 1 2>&1); then
    echo "$out" | grep -E 'Avg bus bandwidth|Out of bounds' | sed 's/^/  /' >&2
  else
    echo "$out" | tail -20 >&2; die "smoke run failed"
  fi
fi
log "OK: $OUTDIR"
echo "$OUTDIR"
