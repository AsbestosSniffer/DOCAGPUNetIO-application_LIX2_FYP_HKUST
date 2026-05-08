#!/usr/bin/env bash
# run_profiling.sh -- orchestrate hardware profiling experiments for the
# NeurIPS hardware analysis report.
#
# This script targets bin/gpu_receiver (the real T4/T5 DOCA GPUNetIO receiver).
# It assumes traffic is already flowing (sender started on lxcpu2 before running
# any live-NIC experiment), or use --offline-only to skip the live-NIC parts.
#
# The microbench_ema binary must be pre-built:
#   nvcc -O3 -arch=sm_86 -o profiling/microbench_ema profiling/microbench_ema.cu
#
# Usage:
#   sudo ./scripts/run_profiling.sh [options]
#
# Options:
#   --gpu-pcie  <addr>   GPU PCIe address  (default: 0000:ac:00.0)
#   --nic-pcie  <addr>   NIC PCIe address  (default: 0000:bd:00.1)
#   --gpu       <idx>    CUDA device index (default: 1)
#   --harness   <ip>     Benchmark harness IP (default: 127.0.0.1)
#   --fillsim   <ip>     Fill simulator IP    (default: 127.0.0.1)
#   --duration  <sec>    Seconds for live-NIC captures (default: 30)
#   --outdir    <dir>    Output directory (default: profiling_out/)
#   --skip-nsys          Skip Nsight Systems timeline capture
#   --skip-ncu           Skip all Nsight Compute runs
#   --offline-only       Run only offline experiments (roofline, cache) -- no NIC needed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GPU_PCIE="${GPU_PCIE:-0000:ac:00.0}"
NIC_PCIE="${NIC_PCIE:-0000:bd:00.1}"
CUDA_DEV="${CUDA_DEV:-1}"
HARNESS_IP="${HARNESS_IP:-127.0.0.1}"
FILLSIM_IP="${FILLSIM_IP:-127.0.0.1}"
DURATION="${DURATION:-30}"
OUTDIR="${OUTDIR:-$REPO_ROOT/profiling_out}"
SKIP_NSYS=0
SKIP_NCU=0
OFFLINE_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-pcie)     GPU_PCIE="$2";    shift 2 ;;
        --nic-pcie)     NIC_PCIE="$2";    shift 2 ;;
        --gpu)          CUDA_DEV="$2";    shift 2 ;;
        --harness)      HARNESS_IP="$2";  shift 2 ;;
        --fillsim)      FILLSIM_IP="$2";  shift 2 ;;
        --duration)     DURATION="$2";    shift 2 ;;
        --outdir)       OUTDIR="$2";      shift 2 ;;
        --skip-nsys)    SKIP_NSYS=1;      shift ;;
        --skip-ncu)     SKIP_NCU=1;       shift ;;
        --offline-only) OFFLINE_ONLY=1;   shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUTDIR"

GPU_RECEIVER="$REPO_ROOT/bin/gpu_receiver"
MICROBENCH="$REPO_ROOT/profiling/microbench_ema"

RECEIVER_ARGS=(
    --gpu-pcie "$GPU_PCIE"
    --nic-pcie "$NIC_PCIE"
    --gpu      "$CUDA_DEV"
    --tier     4
    --harness  "$HARNESS_IP"
    --fillsim  "$FILLSIM_IP"
    --light-bench
)

echo "[profiling] GPU PCIe: $GPU_PCIE  NIC PCIe: $NIC_PCIE  duration: ${DURATION}s"
echo "[profiling] Output:  $OUTDIR"

[[ -x "$GPU_RECEIVER" ]] || { echo "ERROR: $GPU_RECEIVER not found. Run 'make t4' first." >&2; exit 1; }
[[ -x "$MICROBENCH" ]] || {
    echo "ERROR: $MICROBENCH not found." >&2
    echo "       nvcc -O3 -arch=sm_86 -o profiling/microbench_ema profiling/microbench_ema.cu" >&2
    exit 1
}
command -v nsys >/dev/null 2>&1 || { echo "WARNING: nsys not found -- skipping nsys"; SKIP_NSYS=1; }
command -v ncu  >/dev/null 2>&1 || { echo "WARNING: ncu not found  -- skipping ncu";  SKIP_NCU=1;  }

# E0: Hardware configuration
echo ""
echo "=== E0: Hardware configuration ==="
{
    echo "=== nvidia-smi ==="
    nvidia-smi --query-gpu=name,memory.total,clocks.max.sm,clocks.max.memory,\
pcie.link.gen.max,pcie.link.width.max,compute_cap --format=csv
    echo ""
    echo "=== numactl --hardware ==="
    numactl --hardware 2>/dev/null || echo "(numactl not available)"
    echo ""
    echo "=== lspci (NVIDIA + Mellanox) ==="
    lspci | grep -E "NVIDIA|Mellanox" || true
    echo ""
    echo "=== mlxconfig query ==="
    mlxconfig -d "0000:bd:00.0" query 2>/dev/null \
        | grep -E "LINK_TYPE|SRIOV|ROCE" \
        || echo "(mlxconfig unavailable)"
} | tee "$OUTDIR/hardware_config.txt"

# E2: Roofline (offline -- microbench_ema)
if [[ $SKIP_NCU -eq 0 ]]; then
    echo ""
    echo "=== E2: Roofline analysis (offline) ==="
    ncu \
        --set roofline \
        --output "$OUTDIR/ncu_roofline" \
        --force-overwrite \
        "$MICROBENCH" \
        2>&1 | tee "$OUTDIR/ncu_roofline_log.txt"
    ncu --import "$OUTDIR/ncu_roofline.ncu-rep" \
        --print-summary per-kernel \
        > "$OUTDIR/ncu_roofline_summary.txt" 2>&1 || true
    echo "[profiling] E2 done. Open $OUTDIR/ncu_roofline.ncu-rep in ncu-ui."
fi

# E4: Cache hit rates (offline -- microbench_ema)
if [[ $SKIP_NCU -eq 0 ]]; then
    echo ""
    echo "=== E4: Cache hit rates (offline) ==="
    ncu \
        --metrics \
l1tex__t_sectors_pipe_lsu_mem_global_op_ld_lookup_hit.sum,\
l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum,\
lts__t_sectors_op_read_lookup_hit.sum,\
lts__t_requests.sum \
        --output "$OUTDIR/ncu_cache" \
        --force-overwrite \
        "$MICROBENCH" \
        2>&1 | tee "$OUTDIR/ncu_cache_log.txt"
    ncu --import "$OUTDIR/ncu_cache.ncu-rep" \
        --print-summary per-kernel \
        > "$OUTDIR/ncu_cache_summary.txt" 2>&1 || true
    echo "[profiling] E4 done: $OUTDIR/ncu_cache_summary.txt"
fi

# Live-NIC experiments
if [[ $OFFLINE_ONLY -eq 1 ]]; then
    echo ""
    echo "[profiling] --offline-only: skipping live-NIC experiments (E1 timeline, E6 occupancy)."
    echo "[profiling] To run those, start the sender on lxcpu2 and re-run without --offline-only."
    exit 0
fi

echo ""
echo "=== Live-NIC experiments -- sender must be running on lxcpu2 ==="
echo "  Example sender command:"
echo "    ssh lix2@lxcpu2.cse.ust.hk \\"
echo "      \"~/DOCAGPUNetIO-application_LIX2_FYP_HKUST/bin/data_source \\"
echo "        --mode replay --csv ~/DOCAGPUNetIO-application_LIX2_FYP_HKUST/data/ticks.csv \\"
echo "        --rate 100000 --dest 192.168.100.2:6005\""
echo ""
read -rp "Press Enter when sender is running at 100k ticks/sec (Ctrl-C to abort)..."

# E1: Nsight Systems timeline
if [[ $SKIP_NSYS -eq 0 ]]; then
    echo ""
    echo "=== E1: Nsight Systems timeline (${DURATION}s, cudaProfilerApi capture range) ==="
    nsys profile \
        --trace=cuda,nvtx,osrt \
        --capture-range=cudaProfilerApi \
        --output="$OUTDIR/t4_timeline" \
        --force-overwrite \
        -- "$GPU_RECEIVER" "${RECEIVER_ARGS[@]}" &
    NSYS_PID=$!
    echo "[profiling] nsys running (PID $NSYS_PID) for ${DURATION}s..."
    sleep "$DURATION"
    kill -INT "$NSYS_PID" 2>/dev/null || true
    wait "$NSYS_PID" 2>/dev/null || true
    [[ -f "profiling_timing_gpu.csv" ]] && \
        cp "profiling_timing_gpu.csv" "$OUTDIR/" && \
        echo "[profiling] profiling_timing_gpu.csv saved to $OUTDIR/"
    echo "[profiling] E1 done. Open $OUTDIR/t4_timeline.nsys-rep in nsys-ui."
fi

# E6: Warp occupancy at 10k and 100k ticks/sec
if [[ $SKIP_NCU -eq 0 ]]; then
    for RATE_LABEL in "10k" "100k"; do
        echo ""
        echo "=== E6: Warp occupancy at ${RATE_LABEL} ticks/sec ==="
        read -rp "Adjust sender to ${RATE_LABEL} ticks/sec, then press Enter..."
        ncu \
            --section WarpStateStatistics \
            --section OccupancyAnalysis \
            --metrics \
sm__warps_active.avg.pct_of_peak_sustained_active,\
smsp__warp_issue_stalled_wait_per_warp_active.ratio,\
smsp__warp_issue_stalled_long_scoreboard_per_warp_active.ratio,\
smsp__warp_issue_stalled_barrier_per_warp_active.ratio \
            --kernel-id "::gpu_recv_process_kernel:1" \
            --output "$OUTDIR/ncu_occupancy_${RATE_LABEL}" \
            --force-overwrite \
            -- "$GPU_RECEIVER" "${RECEIVER_ARGS[@]}" &
        NCU_PID=$!
        sleep "$DURATION"
        kill -INT "$NCU_PID" 2>/dev/null || true
        wait "$NCU_PID" 2>/dev/null || true
        ncu --import "$OUTDIR/ncu_occupancy_${RATE_LABEL}.ncu-rep" \
            --print-summary per-kernel \
            > "$OUTDIR/ncu_occupancy_${RATE_LABEL}_summary.txt" 2>&1 || true
        echo "[profiling] E6 (${RATE_LABEL}) done: $OUTDIR/ncu_occupancy_${RATE_LABEL}_summary.txt"
    done
fi

echo ""
echo "=== All profiling experiments complete. Output: $OUTDIR ==="
echo ""
echo "Remaining steps:"
echo "  1. Full benchmark sweep (runtime breakdown data):"
echo "       sudo ./scripts/run_benchmark.sh --tiers 1,4 \\"
echo "         --rates 10000,50000,100000,250000,500000 --reps 3"
echo "  2. Plot generation:"
echo "       python3 profiling/analyze.py \\"
echo "         --bench results/<latest>.csv \\"
echo "         --timing $OUTDIR/profiling_timing_gpu.csv \\"
echo "         --outdir $OUTDIR/plots/"
echo "  3. Open .nsys-rep in nsys-ui and .ncu-rep in ncu-ui for screenshots."
