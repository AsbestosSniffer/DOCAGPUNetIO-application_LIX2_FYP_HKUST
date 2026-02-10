# GPU Trading Pipeline - Testing & Run Guide

## Prerequisites

Before running, ensure you have:

1. **CUDA Toolkit** (nvcc compiler)
   ```bash
   nvcc --version
   ```
   If not installed, download from: https://developer.nvidia.com/cuda-downloads

2. **GCC/G++** (C++ compiler)
   ```bash
   g++ --version
   ```

3. **Basic Unix tools** (make, bash, curl)
   ```bash
   make --version
   bash --version
   ```

4. **GPU with CUDA support** (check with `nvidia-smi`)

## Step 1: Build All Modules

Navigate to the mini_trader directory and compile everything:

```bash
cd /path/to/mini_trader
make all
```

**Expected output:**
```
g++ -O3 -std=c++17 -Iinclude src/results_logger.cpp -o results_logger
g++ -O3 -std=c++17 -Iinclude src/csv_to_bin_converter.cpp -o csv_to_bin_converter
g++ -O3 -std=c++17 -Iinclude src/udp_replayer.cpp -o udp_replayer
nvcc -O3 -std=c++17 -Iinclude src/gpu_staging.cu -o gpu_staging
nvcc -O3 -std=c++17 -Iinclude src/udp_receiver.cpp -o udp_receiver
```

**Binaries created:**
- `csv_to_bin_converter`
- `udp_replayer`
- `udp_receiver`
- `gpu_staging`
- `results_logger`

If you get compilation errors, see **Troubleshooting** at the end.

---

## Step 2: Test GPU Pipeline (Standalone - No Network)

This is the **quickest test** - no UDP networking required.

```bash
./gpu_staging 100000 50000
```

**Parameters:**
- `100000` = number of events to process
- `50000` = maximum batch size

**Expected output:**
```
GPU Pipeline Staging Test
Events: 100000, Max batch: 50000
Processing 100 batches of 1000 events

[GPU Pipeline] Batch: 1000 events, 6 signals (3 buy, 3 sell), 12.345 ms
[GPU Pipeline] Batch: 1000 events, 8 signals (5 buy, 3 sell), 11.987 ms
[GPU Pipeline] Batch: 1000 events, 7 signals (4 buy, 3 sell), 12.123 ms
...
Test completed successfully!
```

**What this proves:**
- ✅ CUDA compilation works
- ✅ GPU kernels execute
- ✅ Candle aggregation works
- ✅ Signals are generated
- ✅ Batch processing pipeline functions

**Try different sizes:**
```bash
# Smaller test (10K events)
./gpu_staging 10000 5000

# Larger test (1M events)
./gpu_staging 1000000 100000

# Check throughput improvement with larger batches
./gpu_staging 500000 100000  # vs
./gpu_staging 500000 10000
```

---

## Step 3: Full End-to-End Test (UDP + GPU)

This tests the complete pipeline with network ingress.

### 3A: Using Synthetic Data (Easiest - No Download)

**Open Terminal 1 - Start the GPU Receiver**
```bash
cd /path/to/mini_trader

# Listen on port 9999, batch limit 50K, process max 10 batches then exit
./udp_receiver 9999 50000 10
```

**Expected output:**
```
UDP Receiver + GPU Pipeline
Listening on port 9999 (batch_limit=50000)
Initializing GPU pipeline...
Ready to receive UDP packets...

[GPU] Batch 1: 5000 events, 12 signals (7B/5S), 10.234ms
[GPU] Batch 2: 5000 events, 15 signals (9B/6S), 9.876ms
[GPU] Batch 3: 5000 events, 11 signals (6B/5S), 10.123ms
...
[GPU] Batch 10: 5000 events, 13 signals (8B/5S), 10.456ms

=== Final Statistics ===
Total events: 50000
Total batches: 10
Avg batch size: 5000
```

**Open Terminal 2 - Send Synthetic Data**
```bash
cd /path/to/mini_trader

# Send 50K fake events in 5K-event batches at maximum speed (pacing_mode=0)
./udp_replayer 127.0.0.1 9999 FAKE 5000 50000 0
```

**Expected output:**
```
Generated 50000 fake events
sent packet_seq=100 sent=50000
Replay finished: 50000 events in 234.567 ms
```

**What happens:**
1. Receiver sets up GPU and waits for packets
2. Replayer generates synthetic MarketEvent data
3. Replayer sends UDP packets in batches
4. Receiver decodes packets and feeds GPU
5. GPU processes through all 4 kernels
6. Results printed per batch
7. Summary statistics printed at end

---

## Step 4: Real Data Test (With Binance Downloads)

This tests with actual market data from Binance.

### 4A: Download Binance Data

```bash
cd /path/to/mini_trader

# Download trades for 1 symbol, 1 month (2023-06-01 to 2023-06-30)
./binance_downloader.sh 2023-06-01 2023-06-30
```

**Expected output:**
```
Downloading Binance trades from 2023-06-01 to 2023-06-30
Symbols: BTCUSDT ETHUSDT BNBUSDT SOLUSDT XRPUSDT ADAUSDT DOGEUSDT TRXUSDT AVAXUSDT DOTUSDT
Downloading BTCUSDT...
  Fetching 2023-06-01...
  Fetching 2023-06-02...
  ...
Download complete! CSV files in data/raw/
```

**Files created:**
- `data/raw/BTCUSDT/2023-06-01.csv`
- `data/raw/BTCUSDT/2023-06-02.csv`
- ... (one per day)
- Same for ETHUSDT, BNBUSDT, etc.

**Note:** Download may take 5-10 minutes depending on internet speed.

### 4B: Convert CSV to Binary

```bash
# Create output directory
mkdir -p data/bin

# Convert one symbol's data
./csv_to_bin_converter data/raw/BTCUSDT/2023-06-15.csv BTCUSDT data/bin/BTCUSDT.bin
```

**Expected output:**
```
Converted 12345 events for BTCUSDT to data/bin/BTCUSDT.bin
```

**What this does:**
- Reads CSV (slow, one-time)
- Converts timestamps: milliseconds → nanoseconds
- Maps symbol string "BTCUSDT" → uint32_t ID
- Sorts by timestamp
- Writes binary MarketEvent structs (40 bytes each)
- GPU never parses CSV (only binary on hot path)

### 4C: Replay Real Data

**Terminal 1 - Receiver:**
```bash
./udp_receiver 9999 50000 50  # Process 50 batches
```

**Terminal 2 - Replay real data:**
```bash
# Replay with blast pacing (as fast as possible)
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 100000 0
```

This will replay 100K events from real Binance data.

---

## Step 5: View Results & Logs

### Print Logger Summary

```bash
./results_logger print
```

**Expected output:**
```
=== Trading Pipeline Summary ===
Total batches: 3
Total events: 3000
Total signals: 18 (0.60%)
  BUY signals: 10
  SELL signals: 8
Total kernel time: 35.40 ms
Throughput: 84746 events/sec
Avg kernel time per batch: 11.800 ms
Orders written to orders_example.csv (3 orders)
Batch stats written to batch_stats_example.csv (3 batches)
```

This generates two CSV files:
- `orders_example.csv` - detailed order list
- `batch_stats_example.csv` - batch-level statistics

---

## Testing Scenarios

### Scenario 1: Quick Validation (< 1 minute)

Verify everything builds and runs:

```bash
# Build
make clean && make all

# GPU standalone test
./gpu_staging 50000 10000

# Result: Should see signals and timing, no errors
```

**Time:** ~30 seconds

---

### Scenario 2: Synthetic Data Throughput Test (2-3 minutes)

Test GPU throughput with generated data:

**Terminal 1:**
```bash
# Receive 100 batches = 500K events
./udp_receiver 9999 50000 100
```

**Terminal 2:**
```bash
# Send 500K events in 5K batches, blast mode
./udp_replayer 127.0.0.1 9999 FAKE 5000 500000 0
```

**Metrics to observe:**
- Events/sec in final summary
- Avg kernel time per batch
- Signal generation rate

---

### Scenario 3: Batch Size Impact Test (5 minutes)

Compare different batch sizes to find optimal:

**Test 1: Small batches (1K)**
```bash
# Terminal 1
./udp_receiver 9999 10000 50

# Terminal 2
./udp_replayer 127.0.0.1 9999 FAKE 1000 50000 0
```

**Test 2: Medium batches (10K)**
```bash
# Terminal 1
./udp_receiver 9999 100000 50

# Terminal 2
./udp_replayer 127.0.0.1 9999 FAKE 10000 500000 0
```

**Test 3: Large batches (50K)**
```bash
# Terminal 1
./udp_receiver 9999 100000 20

# Terminal 2
./udp_replayer 127.0.0.1 9999 FAKE 50000 1000000 0
```

**Compare:** Throughput (events/sec) should improve with larger batches due to reduced overhead.

---

### Scenario 4: Real Data Test (10-15 minutes)

Full realistic test with Binance data:

```bash
# Download (5 min)
./binance_downloader.sh 2023-06-01 2023-06-10

# Convert (30 sec)
mkdir -p data/bin
for day in {01..10}; do
  ./csv_to_bin_converter data/raw/BTCUSDT/2023-06-$day.csv BTCUSDT data/bin/BTCUSDT_day$day.bin
done

# Test receiver (5 min) - Terminal 1
./udp_receiver 9999 50000 100

# Replay (Terminal 2) - with real-time pacing to simulate actual market
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT_day01.bin 5000 100000 1
```

---

## Understanding the Output

### GPU Pipeline Batch Output

```
[GPU] Batch 5: 5000 events, 12 signals (7B/5S), 10.234ms
```

Breaking this down:
- **Batch 5**: Which batch number
- **5000 events**: Number of market events in this batch
- **12 signals**: Total BUY+SELL orders generated
- **7B/5S**: 7 BUY signals, 5 SELL signals
- **10.234ms**: Total time (H2D copy + all kernels + D2H copy)

### Final Statistics

```
=== Final Statistics ===
Total events: 500000
Total batches: 100
Avg batch size: 5000
```

- **Total events**: Sum of all events processed
- **Total batches**: Number of UDP packets received & processed
- **Avg batch size**: Average events per batch

### Performance Metrics

**Throughput = Total Events / Total Kernel Time (seconds)**
- Example: 500K events in 5 seconds = 100K events/sec
- Higher is better
- Typical range: 50K–500K events/sec depending on GPU

**Signal Rate = Total Signals / Total Events × 100%**
- Example: 3000 signals from 500K events = 0.6%
- Depends on market conditions (strategy thresholds)
- Typical range: 0.1%–2%

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| `nvcc: command not found` | CUDA not installed | Install CUDA Toolkit, add to PATH |
| `CUDA out of memory` | Batch too large for GPU | Reduce `max_events_per_batch` in receiver |
| `Address already in use (port 9999)` | Another process using port | Change port in both replayer & receiver, or `lsof -i :9999` to kill |
| `Bad magic in packet` | Replayer not sending correctly | Verify replayer IP/port matches receiver |
| `No signals generated` | Strategy thresholds too strict | Reduce thresholds in `strategy_kernel` (currently 0.1%) |
| `Compilation error in gpu_staging.cu` | Missing CUDA headers | Ensure CUDA toolkit properly installed & in PATH |
| `Slow throughput (<10K events/sec)` | GPU not being used efficiently | Increase batch size, use pacing_mode=0 (blast) |
| `Segfault in apply_events_kernel` | Invalid symbol_id in data | Check data isn't corrupted, symbol_id should be 0–9 |

### Re-compile if needed

```bash
# Clean everything
make clean

# Fresh rebuild
make all

# If specific module fails, rebuild individually
make gpu        # Just GPU pipeline
make receiver   # Just UDP receiver
make converter  # Just CSV converter
```

---

## Key Testing Checkpoints

✅ **Checkpoint 1: GPU Kernel Works**
```bash
./gpu_staging 100000 50000
# Should show signals being generated
```

✅ **Checkpoint 2: UDP Network Works**
```bash
# Terminal 1
./udp_receiver 9999 10000 5

# Terminal 2
./udp_replayer 127.0.0.1 9999 FAKE 1000 10000 0
# Should show batches flowing through receiver
```

✅ **Checkpoint 3: End-to-End Integration**
```bash
# Full pipeline with results
./udp_receiver 9999 50000 10 && echo "Receiver exited successfully"
./udp_replayer 127.0.0.1 9999 FAKE 5000 50000 0
```

✅ **Checkpoint 4: Real Data**
```bash
# Download, convert, replay actual market data
./binance_downloader.sh 2023-06-01 2023-06-01
./csv_to_bin_converter data/raw/BTCUSDT/2023-06-01.csv BTCUSDT data/bin/BTCUSDT.bin
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 50000 0
```

---

## Advanced Testing

### Measure Latency Per Event

Edit `udp_receiver.cpp` to calculate per-event latency:
```cpp
double latency_per_event = batch_time_ms / n_events;
std::cout << "Latency per event: " << latency_per_event << " ms\n";
```

### Vary Pacing Modes

```bash
# Pacing mode 0: Blast (fastest)
./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 0

# Pacing mode 1: Real-time (1μs/event)
./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 1

# Pacing mode 2: Hybrid (burst + sleep)
./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 2
```

### Profile with Different Symbol Distributions

Modify `udp_replayer.cpp` to bias towards certain symbols (currently uniform).

---

## Summary: Recommended Test Flow

1. **5 min**: Build everything (`make all`)
2. **2 min**: Quick GPU test (`./gpu_staging 100000 50000`)
3. **3 min**: Synthetic data end-to-end (UDP test)
4. **5-10 min**: Real data test (download + replay)
5. **2 min**: Check results and metrics

**Total: ~20-30 minutes for full validation**

Good luck! Let me know if you hit any issues.
