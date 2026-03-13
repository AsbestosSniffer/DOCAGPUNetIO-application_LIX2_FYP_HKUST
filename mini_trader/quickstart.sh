#!/bin/bash
# Quick-start guide for GPU trading pipeline
# This script builds and runs basic tests

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "=========================================="
echo "GPU Trading Pipeline - Quick Start"
echo "=========================================="
echo ""

# Step 1: Check prerequisites
echo "[1/5] Checking prerequisites..."
if ! command -v nvcc &> /dev/null; then
    echo "ERROR: nvcc (CUDA compiler) not found. Install CUDA Toolkit."
    exit 1
fi
if ! command -v g++ &> /dev/null; then
    echo "ERROR: g++ not found. Install GCC."
    exit 1
fi
echo "  ✓ CUDA toolkit found: $(nvcc --version | grep release)"
echo "  ✓ GCC found"
echo ""

# Step 2: Build modules
echo "[2/5] Building modules..."
make clean > /dev/null 2>&1 || true

echo "  Building CSV converter..."
make converter > /dev/null 2>&1

echo "  Building UDP replayer..."
make replayer > /dev/null 2>&1

echo "  Building GPU pipeline (standalone)..."
make gpu > /dev/null 2>&1

echo "  Building GPU+UDP receiver..."
make receiver > /dev/null 2>&1

echo "  Building results logger..."
make logger > /dev/null 2>&1

echo "  ✓ All modules built successfully"
echo ""

# Step 3: Run GPU standalone test
echo "[3/5] Running GPU pipeline standalone test..."
echo "  (Testing 50K events through full kernel pipeline)"
timeout 30 ./gpu_staging 50000 10000 || true
echo ""

# Step 4: Show usage examples
echo "[4/5] Usage examples:"
echo ""
echo "  Terminal 1 - Start GPU receiver (waits for UDP):"
echo "    ./udp_receiver 9999 50000 10"
echo ""
echo "  Terminal 2 - Send synthetic data via UDP:"
echo "    ./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 0"
echo ""
echo "  (Or with real Binance data after downloading):"
echo "    ./binance_downloader.sh 2023-01-01 2023-01-31"
echo "    ./csv_to_bin_converter data/raw/BTCUSDT/2023-01-01.csv BTCUSDT data/bin/BTCUSDT.bin"
echo "    ./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 100000 0"
echo ""

# Step 5: Show results
echo "[5/5] View pipeline specification:"
echo "  cat PIPELINE_SPEC.md"
echo ""

echo "=========================================="
echo "✓ Quick start complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Run UDP receiver in one terminal: ./udp_receiver 9999 50000 10"
echo "  2. Run UDP replayer in another:    ./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 0"
echo "  3. View results and final statistics"
echo ""
