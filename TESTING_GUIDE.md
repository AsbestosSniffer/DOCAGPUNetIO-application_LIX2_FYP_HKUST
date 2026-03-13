# Testing Guide — Complete Testing Procedures

This guide covers every way to test the three systems, from quick smoke tests to full benchmark runs with real Binance market data.

---

## Table of Contents

1. [Quick Smoke Test (2 minutes)](#1-quick-smoke-test)
2. [Synthetic Benchmark (5 minutes)](#2-synthetic-benchmark)
3. [Real Data: Download Binance Trades](#3-real-data-download)
4. [Real Data: Convert CSV to Binary](#4-real-data-convert)
5. [Real Data: Test with Historical Data](#5-real-data-test)
6. [UDP Replay Testing](#6-udp-replay-testing)
7. [Full Benchmark Suite](#7-full-benchmark-suite)
8. [Live Binance WebSocket Testing](#8-live-binance-websocket-testing)
9. [DOCA GPUNetIO Testing](#9-doca-testing)
10. [Understanding the Output](#10-understanding-output)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Quick Smoke Test

**Time**: 2 minutes. **Purpose**: Verify everything compiles and runs.

```bash
# Build everything
make clean && make all

# Test CPU baseline (synthetic, 100K events, batches of 1000)
./cpu_baseline/cpu_baseline 100000 1000

# Test GPU RDMA pipeline (synthetic, 100K events, batches of 1000)
./gpu_rdma/gpu_rdma_pipeline 100000 1000
```

**What to check:**
- Both binaries compile without errors
- Both print latency statistics (p50, p99, p999, mean, stddev)
- Both print throughput (events/sec)
- Both print PnL summary (trades closed, win rate, drawdown)
- GPU version should be faster than CPU (compare throughput numbers)

**Expected CPU output:**
```
System 1: CPU Baseline Pipeline

Mode: Synthetic benchmark (100000 events, batch_size=1000)
Processing 100 batches...

=== CPU Baseline Results ===
[CPU Latency] samples=100  mean=45.2 us  p50=42.1  p99=78.3  p999=92.1  stddev=12.4
[CPU Throughput] 100000 events in 100 batches  2214897 ev/s
=== Trade Performance ===
  Total closed trades : 0
  ...
```

**Expected GPU output:**
```
System 2: GPU RDMA Pipeline

Mode: Synthetic benchmark (100000 events, batch=1000, GPU 1)
Processing 100 batches...

=== GPU RDMA Pipeline Results ===
[GPU Latency] samples=100  mean=120.5 us  p50=95.2  p99=245.3  p999=312.1  stddev=45.7
[GPU Throughput] 100000 events in 100 batches  830000 ev/s
```

Note: With small batches (1000), CPU may appear faster due to GPU kernel launch overhead. The GPU advantage appears at larger batch sizes (10K+). This is expected and demonstrates the batch-size vs. latency tradeoff.

---

## 2. Synthetic Benchmark

**Time**: 5 minutes. **Purpose**: Compare CPU vs GPU at different batch sizes.

```bash
# Small batches (CPU may win — demonstrates kernel launch overhead)
echo "=== Batch size 100 ==="
./cpu_baseline/cpu_baseline 100000 100
./gpu_rdma/gpu_rdma_pipeline 100000 100

# Medium batches (GPU starts winning)
echo "=== Batch size 1000 ==="
./cpu_baseline/cpu_baseline 1000000 1000
./gpu_rdma/gpu_rdma_pipeline 1000000 1000

# Large batches (GPU clearly wins)
echo "=== Batch size 10000 ==="
./cpu_baseline/cpu_baseline 1000000 10000
./gpu_rdma/gpu_rdma_pipeline 1000000 10000

# Very large batches (maximum GPU throughput)
echo "=== Batch size 50000 ==="
./cpu_baseline/cpu_baseline 1000000 50000
./gpu_rdma/gpu_rdma_pipeline 1000000 50000
```

**What to look for:**
- CPU throughput stays relatively constant regardless of batch size
- GPU throughput increases dramatically with larger batches (amortizes H2D/D2H overhead)
- GPU p99 latency may be higher than CPU for small batches (kernel launch + transfer overhead)
- Both systems produce identical trading signals (same synthetic data, same seed)

---

## 3. Real Data: Download Binance Trades

**Time**: 5-15 minutes (network dependent). **Purpose**: Get real market data for testing.

### Download One Day

```bash
cd mini_trader

# Download trades for all 10 symbols, 1 day
./binance_downloader.sh 2026-02-08 2026-02-08
```

**What happens:**
1. Script downloads daily trade ZIP files from `data.binance.vision`
2. Each ZIP contains a CSV with columns: `trade_id, price, qty, quoteQty, time, isBuyerMaker, isBestMatch`
3. Files are extracted to `mini_trader/data/raw/<SYMBOL>/<DATE>.csv`

**Expected files:**
```
mini_trader/data/raw/BTCUSDT/2026-02-08.csv
mini_trader/data/raw/ETHUSDT/2026-02-08.csv
mini_trader/data/raw/BNBUSDT/2026-02-08.csv
... (10 symbols total)
```

### Download Multiple Days (for longer backtests)

```bash
# Download 1 week
./binance_downloader.sh 2026-02-01 2026-02-07

# Download 1 month
./binance_downloader.sh 2026-01-01 2026-01-31
```

### If Download Fails

The university network may block `data.binance.vision`. Alternatives:
1. Download on your local machine and `scp` to server
2. Use the CSV files already in `mini_trader_cupy/` (from the original repo, 8 symbols, 1 day each)
3. Use synthetic data (always works, no network needed)

---

## 4. Real Data: Convert CSV to Binary

**Time**: 30 seconds per file. **Purpose**: Convert slow-to-parse CSV into fast binary format.

### Build the Converter

```bash
make tools    # builds csv_to_bin_converter
```

### Convert a Single File

```bash
cd mini_trader
mkdir -p data/bin

# Usage: ./csv_to_bin_converter <input.csv> <SYMBOL> <output.bin>
./csv_to_bin_converter data/raw/BTCUSDT/2026-02-08.csv BTCUSDT data/bin/btcusdt.bin
```

**Expected output:**
```
Converted 123456 events for BTCUSDT to data/bin/btcusdt.bin
```

### What the Converter Does

1. Reads CSV line by line (trade_id, price, qty, quoteQty, time_ms, isBuyerMaker, isBestMatch)
2. Maps symbol string "BTCUSDT" to uint32 ID (0)
3. Converts timestamp: milliseconds -> nanoseconds (`time_ms * 1000000`)
4. Maps isBuyerMaker: "True" -> side=0 (buyer), "False" -> side=1 (seller)
5. Sorts all events by timestamp
6. Writes binary array of `MarketEvent` structs (each event is fixed-size)

### Convert Multiple Symbols

```bash
cd mini_trader
mkdir -p data/bin

for symbol in BTCUSDT ETHUSDT BNBUSDT SOLUSDT XRPUSDT ADAUSDT DOGEUSDT TRXUSDT AVAXUSDT DOTUSDT; do
    if [ -f "data/raw/$symbol/2026-02-08.csv" ]; then
        ./csv_to_bin_converter "data/raw/$symbol/2026-02-08.csv" "$symbol" "data/bin/${symbol,,}.bin"
        echo "Converted $symbol"
    fi
done
```

### Using the CuPy CSVs (Already in Repo)

If you have the CSV files from `mini_trader_cupy/`:

```bash
cd mini_trader
mkdir -p data/bin
./csv_to_bin_converter ../mini_trader_cupy/BTCUSDT-trades-2026-02-08.csv BTCUSDT data/bin/btcusdt.bin
./csv_to_bin_converter ../mini_trader_cupy/ETHUSDT-trades-2026-02-08.csv ETHUSDT data/bin/ethusdt.bin
# ... etc for each symbol
```

Note: The CSV files are no longer tracked by git (.gitignore excludes *.csv), but if they exist locally they can still be converted.

---

## 5. Real Data: Test with Historical Data

**Time**: 2-5 minutes. **Purpose**: Run the pipeline on actual Binance market data.

### CPU Baseline with Real Data

```bash
cd /path/to/repo  # back to repo root

# Process BTC trades, batches of 1000
./cpu_baseline/cpu_baseline --file mini_trader/data/bin/btcusdt.bin 1000

# Process with larger batches
./cpu_baseline/cpu_baseline --file mini_trader/data/bin/btcusdt.bin 10000
```

### GPU RDMA with Real Data

```bash
# Process BTC trades on GPU 1
./gpu_rdma/gpu_rdma_pipeline --file mini_trader/data/bin/btcusdt.bin 1000

# Larger batches (GPU should clearly outperform CPU here)
./gpu_rdma/gpu_rdma_pipeline --file mini_trader/data/bin/btcusdt.bin 10000
```

### Side-by-Side Comparison

```bash
echo "===== CPU Baseline ====="
./cpu_baseline/cpu_baseline --file mini_trader/data/bin/btcusdt.bin 5000

echo ""
echo "===== GPU RDMA ====="
./gpu_rdma/gpu_rdma_pipeline --file mini_trader/data/bin/btcusdt.bin 5000
```

**What to compare:**
- **Latency**: p50, p99, p999 (in microseconds)
- **Throughput**: events/sec
- **PnL**: Should be identical (same data, same strategy, same deterministic logic)
- **Win rate**: Should be identical between CPU and GPU
- **Max drawdown**: Should be identical between CPU and GPU

If PnL differs between CPU and GPU, there is a bug in the implementation (floating-point order of operations can cause minor differences due to GPU thread scheduling, but the overall numbers should be very close).

---

## 6. UDP Replay Testing

**Time**: 5-10 minutes. **Purpose**: Test the full network ingestion path (socket recv -> processing).

This uses two terminals: one for the receiver (listening) and one for the replayer (sending).

### Step 1: Start the Receiver

**Terminal 1:**

```bash
# CPU baseline listening on port 9999
./cpu_baseline/cpu_baseline --udp 9999 10000
```

OR for GPU:

```bash
# GPU pipeline listening on port 9999
./gpu_rdma/gpu_rdma_pipeline --udp 9999 10000
```

### Step 2: Send Data via UDP Replayer

**Terminal 2:**

```bash
cd mini_trader

# Option A: Send synthetic (fake) data
# Usage: ./udp_replayer <host> <port> FAKE <batch_size> <total_events> <pacing_mode>
./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 0

# Option B: Send real data from .bin file
./udp_replayer 127.0.0.1 9999 data/bin/btcusdt.bin 5000 100000 0
```

### Pacing Modes

| Mode | Name | Behavior |
|------|------|----------|
| 0 | Blast | Send as fast as possible (max throughput test) |
| 1 | Real-time | 1 microsecond per event (simulates real market speed) |
| 2 | Hybrid | Burst of events, then sleep (realistic bursty patterns) |
| 3 | Timed | Configurable delay per packet (in milliseconds) |

### What to Look For

In the receiver terminal:
- Batches arriving and being processed
- Signal counts (BUY/SELL) per batch
- Cumulative PnL updating
- No "Bad magic" errors (indicates replayer format mismatch)
- No "Short packet" warnings (indicates UDP fragmentation)

---

## 7. Full Benchmark Suite

**Time**: 10-30 minutes. **Purpose**: Produce publication-quality comparison data.

### Quick Benchmark (3 batch sizes, 100K events)

```bash
chmod +x benchmark/run_benchmarks.sh
./benchmark/run_benchmarks.sh quick
```

### Full Benchmark (5 batch sizes, 1M events, 3 repeats)

```bash
./benchmark/run_benchmarks.sh full
```

### Output

Results are saved to `benchmark/results/benchmark_YYYYMMDD_HHMMSS.csv` with columns:
```
system, n_symbols, batch_size, total_events, lat_p50_us, lat_p99_us, lat_mean_us, throughput_evps, time_sec
```

### Generate Charts

```bash
python3 benchmark/plot_results.py
# Or specify a specific CSV:
python3 benchmark/plot_results.py benchmark/results/benchmark_20260313_120000.csv
```

If matplotlib is installed, this generates a PNG with:
- Left panel: p99 latency vs batch size (CPU vs GPU)
- Right panel: Throughput vs batch size (CPU vs GPU)

If matplotlib is not installed, it prints an ASCII table.

### Custom Benchmark Runs

For specific parameter combinations:

```bash
# CPU with 50K batch
./cpu_baseline/cpu_baseline 5000000 50000

# GPU with 50K batch
./gpu_rdma/gpu_rdma_pipeline 5000000 50000

# Compare at 1-symbol scale (modify source -- future flag)
# Compare at increasing symbol counts (future flag)
```

---

## 8. Live Binance WebSocket Testing

**Time**: Ongoing (real-time). **Purpose**: Process live market data from Binance.

This requires the "live" build variants which link against libwebsockets and nlohmann-json.

### Prerequisites

```bash
# Install dependencies
sudo apt install libwebsockets-dev nlohmann-json3-dev

# Verify
pkg-config --modversion libwebsockets
dpkg -l | grep nlohmann
```

### Build Live Variants

```bash
# Build everything with WebSocket support
make live

# This creates:
#   binance_ws_test              — standalone WS test (prints trades)
#   cpu_baseline/cpu_baseline_live    — CPU pipeline + --live mode
#   gpu_rdma/gpu_rdma_pipeline_live  — GPU pipeline + --live mode
```

Note: `make all` builds the standard variants WITHOUT WebSocket dependency. `make live` builds separate binaries WITH WebSocket support. This keeps the standard builds simple and dependency-free.

### Step 1: Test WebSocket Connectivity

```bash
# Quick test: connect and print first 100 trades
./binance_ws_test --dump 100
```

**Expected output:**
```
Binance WebSocket Live Feed Test

[BinanceWS] Connecting to stream.binance.com:9443...
[BinanceWS] Connected. Streaming 10 symbols.
[BinanceWS] Batch size: 100 events
[BTCUSDT] BUY   price=85234.5600  qty=0.001200  trade_id=3847562891
[ETHUSDT] SELL  price=3215.4300  qty=0.050000  trade_id=2934781234
[SOLUSDT] BUY   price=145.2800  qty=1.230000  trade_id=892347123
...
--- 100 events in 4.2s (23 ev/s) ---

=== Final Statistics ===
[Live Feed] 100 events in 1 batches  24 ev/s
```

### Step 2: Save Live Data to Binary File

```bash
# Record 10,000 live trades to a binary file
./binance_ws_test --bin live_trades.bin --dump 10000

# Then use the binary file with standard pipelines (no WS dependency)
./cpu_baseline/cpu_baseline --file live_trades.bin 1000
./gpu_rdma/gpu_rdma_pipeline --file live_trades.bin 1000
```

This is useful for capturing live data once, then benchmarking repeatedly on the same dataset.

### Step 3: Run CPU Pipeline on Live Data

```bash
./cpu_baseline/cpu_baseline_live --live 500
# Processes in batches of 500 events
# Press Ctrl+C to stop

# Expected output:
# Mode: LIVE Binance WebSocket (batch_size=500)
# [BinanceWS] Connecting to stream.binance.com:9443...
# [BinanceWS] Connected. Streaming 10 symbols.
# [CPU LIVE] Batch 10: 500 events, 3 signals (2B/1S) | PnL=$0.0000 | 1205 ev/s
# [CPU LIVE] Batch 20: 500 events, 2 signals (1B/1S) | PnL=$0.0012 | 1198 ev/s
# ...
```

### Step 4: Run GPU Pipeline on Live Data

```bash
./gpu_rdma/gpu_rdma_pipeline_live --live 500
# Same as CPU but processes on GPU 1
# Press Ctrl+C to stop
```

### Step 5: Side-by-Side Live Comparison

Run both in separate terminals on the same live data stream:

**Terminal 1:**
```bash
./cpu_baseline/cpu_baseline_live --live 500
```

**Terminal 2:**
```bash
./gpu_rdma/gpu_rdma_pipeline_live --live 500
```

Both connect to Binance independently. The data will be slightly different (different trade batches) but the overall statistics should be comparable.

### Expected Live Data Rates

Binance trade rates vary by market conditions:
- **Quiet market**: ~500-2000 trades/minute across 10 symbols (~8-33 trades/sec)
- **Active market**: ~5000-20000 trades/minute (~83-333 trades/sec)
- **Volatile/news event**: ~50000+ trades/minute (~800+ trades/sec)

With batch_size=500, you'll see a new batch every 15-60 seconds in quiet markets, or every 1-5 seconds during active trading.

### Two Approaches: Download vs Live

| Approach | Command | Pros | Cons |
|----------|---------|------|------|
| **Download + Replay** | `binance_downloader.sh` then `--file` | Reproducible benchmarks, no network needed during test, exact same data for CPU vs GPU | Historical only, requires download step |
| **Live WebSocket** | `--live` mode | Real-time data, no download step, demonstrates live capability | Non-reproducible, different data per run, depends on network |

**Recommendation**: Use downloaded data for benchmarks (reproducibility). Use live data for demos and the final presentation.

---

## 9. DOCA GPUNetIO Testing (Server Only)

### Stub Mode (Without DOCA SDK)

The DOCA pipeline compiles in stub mode on machines without the SDK:

```bash
cd gpu_doca
# If meson is available:
meson setup build -Dhave_doca=false
ninja -C build
./build/doca_trading
```

This runs the CPU control loop with simulated semaphore polling (usleep-based).

### Full Mode (On Server with DOCA SDK)

```bash
cd gpu_doca
export PKG_CONFIG_PATH=/opt/mellanox/doca/lib/pkgconfig:$PKG_CONFIG_PATH
meson setup build
ninja -C build

# Run (requires root for hugepages and NIC access)
sudo ./build/doca_trading
```

### Testing DOCA Prerequisites

Before running System 3, verify these on the server:

```bash
# 1. Check DOCA SDK version
cat /opt/mellanox/doca/VERSION

# 2. Check BlueField-3 is detected
lspci | grep -i mellanox

# 3. Check GPU-NIC connectivity
nvidia-smi topo -m

# 4. Test basic DOCA sample
ls /opt/mellanox/doca/samples/doca_gpunetio/
# Try running: /opt/mellanox/doca/samples/doca_gpunetio/simple_receive

# 5. Check hugepages (DOCA requires them)
cat /proc/meminfo | grep HugePages

# 6. Allocate hugepages if needed (requires root)
sudo sh -c "echo 2048 > /proc/sys/vm/nr_hugepages"

# 7. Check Mellanox NIC interfaces
ibstat    # or: ip link show
```

---

## 10. Understanding the Output

### Latency Statistics

```
[CPU Latency] samples=1000  mean=45.2 us  p50=42.1  p99=78.3  p999=92.1  stddev=12.4
```

| Field | Meaning |
|-------|---------|
| samples | Number of batches timed |
| mean | Average batch processing time (microseconds) |
| p50 | Median latency: 50% of batches complete faster than this |
| p99 | 99th percentile: only 1% of batches are slower |
| p999 | 99.9th percentile: worst-case tail latency |
| stddev | Standard deviation: consistency of latency |

Lower is better for all metrics. Low stddev indicates consistent performance.

### Throughput

```
[CPU Throughput] 100000 events in 100 batches  2214897 ev/s
```

Higher events/sec is better. This measures total events divided by wall-clock time.

### PnL Summary

```
=== Trade Performance ===
  Total closed trades : 47
  Winning trades      : 23 (48.9%)
  Cumulative PnL      : $0.0012
  Peak PnL            : $0.0034
  Max Drawdown        : $0.0022
```

| Metric | What it means |
|--------|---------------|
| Total closed trades | Number of BUY-SELL pairs matched (FIFO) |
| Winning trades | Trades where SELL price > BUY price |
| Win rate | winning / total as percentage |
| Cumulative PnL | Sum of all (sell_price - buy_price) * qty |
| Peak PnL | Highest cumulative PnL reached |
| Max Drawdown | Largest drop from peak (peak_pnl - current_pnl) |

### GPU Pipeline Batch Output (Legacy mini_trader)

```
[GPU] Batch 5: 5000 events, 12 signals (7B/5S), 10.234ms | PnL: $0.0042 | Win Rate: 52.3% | Drawdown: $0.0008
```

- **5000 events**: Batch size
- **12 signals**: Total orders generated (7 BUY + 5 SELL)
- **10.234ms**: Full pipeline time (H2D + kernels + D2H)
- **PnL**: Running cumulative profit/loss
- **Win Rate**: Percentage of closed trades that were profitable
- **Drawdown**: Current drawdown from peak PnL

---

## 11. Troubleshooting

### Build Issues

| Problem | Solution |
|---------|----------|
| `nvcc: command not found` | `export PATH=/usr/local/cuda/bin:$PATH` |
| `fatal error: cuda_runtime.h: No such file` | `export CPATH=/usr/local/cuda/include:$CPATH` |
| `undefined reference to clock_gettime` | Add `-lrt` to LDFLAGS (usually not needed on modern Linux) |
| `error: expected initializer before static` | The `common/market_event.h` uses `__attribute__((packed))` which requires GCC |

### Runtime Issues

| Problem | Solution |
|---------|----------|
| `CUDA error: no CUDA-capable device` | `nvidia-smi` to check GPUs are visible |
| `CUDA error: out of memory` | Check GPU 1 memory with `nvidia-smi`; reduce batch size |
| GPU 1 not responding | VLLM may have crashed and leaked memory; `sudo nvidia-smi --gpu-reset -i 1` |
| Zero signals generated | Normal for short synthetic runs; candles need 60 seconds of data to close |
| PnL is zero | Need at least 2 closed candle intervals (120+ seconds of data) for signals |
| CPU throughput seems too high | Small batch sizes have very fast CPU processing; try 10K+ events |

### Data Issues

| Problem | Solution |
|---------|----------|
| `Cannot open` .bin file | Check path (relative to where you run the binary, not the source) |
| Converter says 0 events | CSV may be empty or wrong format; check with `head -5 file.csv` |
| Download fails | Check network: `curl -I https://data.binance.vision/` |
| Wrong symbol prices | Ensure CSV matches the symbol name passed to converter |

### Network Issues

| Problem | Solution |
|---------|----------|
| `Address already in use` | `lsof -i :9999` then `kill <PID>`, or use different port |
| Replayer sends but receiver gets nothing | Check firewall: `sudo iptables -L` |
| `Bad magic in packet` | Version mismatch between replayer and receiver; rebuild both |
| `Short packet` | UDP fragmentation; reduce batch_size in replayer to <5000 |

---

## Recommended Test Flow

### For Development (do this every time you change code)

```bash
make clean && make all                           # 30 seconds
./cpu_baseline/cpu_baseline 100000 1000          # 5 seconds
./gpu_rdma/gpu_rdma_pipeline 100000 1000         # 5 seconds
```

### For Weekly Progress Check

```bash
make all
./benchmark/run_benchmarks.sh quick              # 5 minutes
python3 benchmark/plot_results.py                # 10 seconds
```

### For Final Benchmarks (before presentation)

```bash
# Download 1 week of data
cd mini_trader && ./binance_downloader.sh 2026-02-01 2026-02-07

# Convert all symbols
mkdir -p data/bin
for sym in BTCUSDT ETHUSDT BNBUSDT SOLUSDT XRPUSDT ADAUSDT DOGEUSDT TRXUSDT AVAXUSDT DOTUSDT; do
    for day in 01 02 03 04 05 06 07; do
        csv="data/raw/$sym/2026-02-$day.csv"
        [ -f "$csv" ] && ./csv_to_bin_converter "$csv" "$sym" "data/bin/${sym,,}_day$day.bin"
    done
done

# Run full benchmarks
cd ..
./benchmark/run_benchmarks.sh full               # 20-30 minutes

# Run historical comparison
for bin in mini_trader/data/bin/*.bin; do
    echo "=== $bin ==="
    ./cpu_baseline/cpu_baseline --file "$bin" 5000
    ./gpu_rdma/gpu_rdma_pipeline --file "$bin" 5000
    echo ""
done

# Generate charts
python3 benchmark/plot_results.py
```
