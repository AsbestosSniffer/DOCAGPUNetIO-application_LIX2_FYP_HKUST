#!/usr/bin/env bash
# run_profiling.sh — Automates the hardware profiling experiments for the
# DOCA GPUNetIO pipeline report.
#
# Usage:
#   sudo ./scripts/run_profiling.sh --gpu <GPU_PCI> --nic <NIC_PCI> [options]
#
# Required:
#   --gpu <PCI>        GPU PCIe address  (e.g. 0000:ac:00.0)
#   --nic <PCI>        NIC PCIe address  (e.g. 0000:bd:00.0)
#
# Optional:
#   --queues <N>       Number of GPU RX queues (default: 4)
#   --duration <sec>   Seconds to run each experiment (default: 30)
#   --http-server      Enable HTTP server mode (adds --http-server flag)
#   --outdir <dir>     Output directory for CSVs and traces (default: profiling_out/)
#   --skip-nsys        Skip Nsight Systems capture (if nsys not available)
#   --skip-ncu         Skip Nsight Compute capture (if ncu not available)
#
# Prerequisites:
#   - Application built: meson setup build && ninja -C build
#   - Traffic generator running on sender side (pktgen-DPDK or hping3)
#   - nsys and ncu in PATH (NVIDIA Nsight tools)
#
# Outputs written to --outdir:
#   profiling_stats.csv           — 1-second throughput time series
#   profiling_timing_udp.csv      — UDP intra-kernel clock64 ring buffer
#   profiling_timing_tcp.csv      — TCP intra-kernel clock64 ring buffer
#   gpunetio_runtime.nsys-rep    — Nsight Systems trace
#   ncu_roofline.ncu-rep          — Nsight Compute roofline data
#   ncu_cache.ncu-rep             — Nsight Compute cache metrics
#   ncu_occupancy.ncu-rep         — Nsight Compute occupancy / warp stats

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
GPU_PCI=""
NIC_PCI=""
NUM_QUEUES=4
DURATION=30
HTTP_SERVER=""
OUTDIR="profiling_out"
SKIP_NSYS=0
SKIP_NCU=0
APP="./build/doca_gpu_packet_processing"

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu)          GPU_PCI="$2";    shift 2 ;;
        --nic)          NIC_PCI="$2";    shift 2 ;;
        --queues)       NUM_QUEUES="$2"; shift 2 ;;
        --duration)     DURATION="$2";   shift 2 ;;
        --http-server)  HTTP_SERVER="--http-server"; shift ;;
        --outdir)       OUTDIR="$2";     shift 2 ;;
        --skip-nsys)    SKIP_NSYS=1;     shift ;;
        --skip-ncu)     SKIP_NCU=1;      shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$GPU_PCI" || -z "$NIC_PCI" ]]; then
    echo "ERROR: --gpu and --nic are required."
    echo "Usage: $0 --gpu <GPU_PCI> --nic <NIC_PCI> [options]"
    exit 1
fi

mkdir -p "$OUTDIR"
APP_ARGS="-g $GPU_PCI -n $NIC_PCI -q $NUM_QUEUES $HTTP_SERVER"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --------------------------------------------------------------------------
# Experiment 0: Hardware documentation
# --------------------------------------------------------------------------
log "=== Experiment 0: Hardware documentation ==="
{
    echo "=== GPU info ==="
    nvidia-smi --query-gpu=name,memory.total,clocks.max.sm,clocks.max.memory,\
pcie.link.gen.max,pcie.link.width.max,compute_cap --format=csv 2>/dev/null || true

    echo ""
    echo "=== PCIe topology ==="
    lspci | grep -E "NVIDIA|Mellanox" 2>/dev/null || true

    echo ""
    echo "=== NUMA topology ==="
    numactl --hardware 2>/dev/null || true
} | tee "$OUTDIR/hardware_config.txt"
log "Hardware info written to $OUTDIR/hardware_config.txt"

# --------------------------------------------------------------------------
# Experiment 1: Runtime breakdown — baseline run with instrumented app
# --------------------------------------------------------------------------
log "=== Experiment 1: Runtime breakdown (${DURATION}s run, ${NUM_QUEUES} queues) ==="

# Start nvidia-smi monitoring in the background
nvidia-smi dmon -s mup -d 1 -o DT > "$OUTDIR/nvidiasmi_baseline.csv" &
NSMI_PID=$!

log "  Starting application (kill with Ctrl+C after ${DURATION}s or use timeout)..."
timeout "$((DURATION + 5))" $APP $APP_ARGS &
APP_PID=$!

sleep "$DURATION"
kill -INT "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
kill "$NSMI_PID" 2>/dev/null || true
wait "$NSMI_PID" 2>/dev/null || true

# Move output CSVs to outdir
mv -f profiling_stats.csv        "$OUTDIR/profiling_stats_q${NUM_QUEUES}.csv"        2>/dev/null || true
mv -f profiling_timing_udp.csv   "$OUTDIR/profiling_timing_udp_q${NUM_QUEUES}.csv"   2>/dev/null || true
mv -f profiling_timing_tcp.csv   "$OUTDIR/profiling_timing_tcp_q${NUM_QUEUES}.csv"   2>/dev/null || true
log "  Output CSVs moved to $OUTDIR/"

# --------------------------------------------------------------------------
# Experiment 2: Nsight Systems capture
# --------------------------------------------------------------------------
if [[ "$SKIP_NSYS" -eq 0 ]] && command -v nsys &>/dev/null; then
    log "=== Experiment 2: Nsight Systems timeline capture ==="
    nsys profile \
        --trace=cuda,nvtx,osrt \
        --delay=5 \
        --duration="$DURATION" \
        --output="$OUTDIR/gpunetio_runtime" \
        $APP $APP_ARGS || true
    log "  Nsight Systems trace: $OUTDIR/gpunetio_runtime.nsys-rep"
    log "  Export to SQLite for Python analysis:"
    log "    nsys export --type sqlite $OUTDIR/gpunetio_runtime.nsys-rep"
else
    log "=== Experiment 2: Nsight Systems — SKIPPED (nsys not found or --skip-nsys) ==="
fi

# --------------------------------------------------------------------------
# Experiment 3: Nsight Compute — roofline (no replay, hardware counters only)
# --------------------------------------------------------------------------
if [[ "$SKIP_NCU" -eq 0 ]] && command -v ncu &>/dev/null; then
    log "=== Experiment 3: Nsight Compute — roofline ==="
    ncu \
        --set roofline \
        --kernel-id ::cuda_kernel_receive_udp:2 \
        --kernel-id ::cuda_kernel_receive_tcp:2 \
        --kernel-id ::cuda_kernel_receive_icmp:2 \
        --target-processes all \
        --output "$OUTDIR/ncu_roofline" \
        $APP $APP_ARGS || true
    log "  Roofline data: $OUTDIR/ncu_roofline.ncu-rep"
else
    log "=== Experiment 3: Nsight Compute roofline — SKIPPED ==="
fi

# --------------------------------------------------------------------------
# Experiment 4: Nsight Compute — cache hit rates
# --------------------------------------------------------------------------
if [[ "$SKIP_NCU" -eq 0 ]] && command -v ncu &>/dev/null; then
    log "=== Experiment 4: Nsight Compute — cache metrics ==="
    ncu \
        --metrics \
            l1tex__t_sectors_pipe_lsu_mem_global_op_ld_lookup_hit.sum,\
l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum,\
lts__t_sectors_op_read_lookup_hit.sum,\
lts__t_requests.sum,\
l1tex__t_sectors_pipe_lsu_mem_global_op_st.sum \
        --kernel-id ::cuda_kernel_receive_udp:2 \
        --kernel-id ::cuda_kernel_receive_tcp:2 \
        --target-processes all \
        --output "$OUTDIR/ncu_cache" \
        $APP $APP_ARGS || true
    log "  Cache data: $OUTDIR/ncu_cache.ncu-rep"
else
    log "=== Experiment 4: Nsight Compute cache — SKIPPED ==="
fi

# --------------------------------------------------------------------------
# Experiment 5: Nsight Compute — occupancy and warp statistics
# --------------------------------------------------------------------------
if [[ "$SKIP_NCU" -eq 0 ]] && command -v ncu &>/dev/null; then
    log "=== Experiment 5: Nsight Compute — occupancy and warp stats ==="
    ncu \
        --section WarpStateStatistics \
        --section SchedulerStatistics \
        --section OccupancyAnalysis \
        --metrics \
            sm__warps_active.avg.pct_of_peak_sustained_active,\
smsp__warp_issue_stalled_long_scoreboard_per_warp_active.ratio,\
smsp__warp_issue_stalled_barrier_per_warp_active.ratio,\
smsp__warp_issue_stalled_wait_per_warp_active.ratio \
        --kernel-id ::cuda_kernel_receive_udp:2 \
        --kernel-id ::cuda_kernel_receive_tcp:2 \
        --kernel-id ::cuda_kernel_receive_icmp:2 \
        --target-processes all \
        --output "$OUTDIR/ncu_occupancy" \
        $APP $APP_ARGS || true
    log "  Occupancy data: $OUTDIR/ncu_occupancy.ncu-rep"
else
    log "=== Experiment 5: Nsight Compute occupancy — SKIPPED ==="
fi

# --------------------------------------------------------------------------
# Experiment 6: Queue-count scalability sweep (q=1..4)
# --------------------------------------------------------------------------
log "=== Experiment 6: Queue-count scalability sweep ==="
for Q in 1 2 3 4; do
    log "  Running with -q $Q for ${DURATION}s..."
    nvidia-smi dmon -s up -d 1 -o DT > "$OUTDIR/nvidiasmi_q${Q}.csv" &
    NSMI_PID=$!

    timeout "$((DURATION + 5))" $APP -g "$GPU_PCI" -n "$NIC_PCI" -q "$Q" $HTTP_SERVER &
    APP_PID=$!
    sleep "$DURATION"
    kill -INT "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    kill "$NSMI_PID" 2>/dev/null || true
    wait "$NSMI_PID" 2>/dev/null || true

    mv -f profiling_stats.csv "$OUTDIR/profiling_stats_q${Q}.csv" 2>/dev/null || true
    log "  q=${Q} done — stats: $OUTDIR/profiling_stats_q${Q}.csv"
done

# --------------------------------------------------------------------------
# Microbenchmark: run if nvcc available
# --------------------------------------------------------------------------
if command -v nvcc &>/dev/null && [[ -f "profiling/microbench_udp.cu" ]]; then
    log "=== Microbenchmark: building and running microbench_udp ==="
    nvcc -O3 -arch=native -o "$OUTDIR/microbench_udp" profiling/microbench_udp.cu 2>&1 | tail -5 || true
    if [[ -x "$OUTDIR/microbench_udp" ]]; then
        "$OUTDIR/microbench_udp" 500 | tee "$OUTDIR/microbench_udp_results.txt"
        if [[ "$SKIP_NCU" -eq 0 ]] && command -v ncu &>/dev/null; then
            log "  Running ncu --set full on microbenchmark..."
            ncu --set full --output "$OUTDIR/ncu_microbench_udp_full" \
                "$OUTDIR/microbench_udp" 10 || true
        fi
    fi
fi

# --------------------------------------------------------------------------
# Analysis: generate plots from CSVs
# --------------------------------------------------------------------------
log "=== Generating plots ==="
if command -v python3 &>/dev/null && [[ -f "profiling/analyze.py" ]]; then
    python3 profiling/analyze.py \
        --stats         "$OUTDIR/profiling_stats_q${NUM_QUEUES}.csv" \
        --timing-udp    "$OUTDIR/profiling_timing_udp_q${NUM_QUEUES}.csv" \
        --timing-tcp    "$OUTDIR/profiling_timing_tcp_q${NUM_QUEUES}.csv" \
        --outdir        "$OUTDIR/plots" \
        2>&1 || log "  Analysis script failed — run manually: python3 profiling/analyze.py --help"
else
    log "  python3 not found — run manually: python3 profiling/analyze.py --help"
fi

log "=== All experiments complete. Results in: $OUTDIR/ ==="
log ""
log "Next steps:"
log "  1. Open Nsight Systems GUI: nsys-ui $OUTDIR/gpunetio_runtime.nsys-rep"
log "  2. Open Nsight Compute:      ncu-ui  $OUTDIR/ncu_roofline.ncu-rep"
log "  3. Review plots:             ls $OUTDIR/plots/"
log "  4. Run perf stat manually against each tier for CPU utilization comparison."
