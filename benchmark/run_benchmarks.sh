#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  FYP Benchmark Suite — CPU vs GPU RDMA vs DOCA GPUNetIO
# ═══════════════════════════════════════════════════════════
#
# Usage:   ./run_benchmarks.sh [quick|full]
# Output:  results/benchmark_YYYYMMDD_HHMMSS.csv

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV="$RESULTS_DIR/benchmark_${TIMESTAMP}.csv"

# Binaries
CPU_BIN="$ROOT_DIR/cpu_baseline/cpu_baseline"
GPU_BIN="$ROOT_DIR/gpu_rdma/gpu_rdma_pipeline"

MODE="${1:-quick}"

echo "═══════════════════════════════════════════"
echo "  FYP Benchmark Suite ($MODE mode)"
echo "  Output: $CSV"
echo "═══════════════════════════════════════════"

# Check binaries exist
for bin in "$CPU_BIN" "$GPU_BIN"; do
    if [ ! -f "$bin" ]; then
        echo "ERROR: $bin not found. Run 'make all' first."
        exit 1
    fi
done

# CSV header
echo "system,n_symbols,batch_size,total_events,lat_p50_us,lat_p99_us,lat_mean_us,throughput_evps,time_sec" > "$CSV"

# ── Benchmark Parameters ─────────────────────────────────
if [ "$MODE" = "quick" ]; then
    BATCH_SIZES="100 1000 10000"
    TOTAL_EVENTS="100000"
    REPEATS=1
elif [ "$MODE" = "full" ]; then
    BATCH_SIZES="100 1000 5000 10000 50000"
    TOTAL_EVENTS="1000000"
    REPEATS=3
else
    echo "Usage: $0 [quick|full]"
    exit 1
fi

echo ""
echo "──── CPU Baseline ────"
for bs in $BATCH_SIZES; do
    for r in $(seq 1 $REPEATS); do
        echo -n "  batch=$bs (run $r/$REPEATS)... "
        START=$(date +%s%N)
        "$CPU_BIN" "$TOTAL_EVENTS" "$bs" 2>&1 | tail -3
        END=$(date +%s%N)
        ELAPSED=$(echo "scale=3; ($END - $START) / 1000000000" | bc)
        echo "  ${ELAPSED}s"
    done
done

echo ""
echo "──── GPU RDMA Pipeline ────"
for bs in $BATCH_SIZES; do
    for r in $(seq 1 $REPEATS); do
        echo -n "  batch=$bs (run $r/$REPEATS)... "
        START=$(date +%s%N)
        "$GPU_BIN" "$TOTAL_EVENTS" "$bs" 2>&1 | tail -3
        END=$(date +%s%N)
        ELAPSED=$(echo "scale=3; ($END - $START) / 1000000000" | bc)
        echo "  ${ELAPSED}s"
    done
done

echo ""
echo "═══════════════════════════════════════════"
echo "  Benchmark complete. Results: $CSV"
echo "═══════════════════════════════════════════"
