# Modular GPU-Accelerated Trading Pipeline

A complete, modular GPU-accelerated processing pipeline for market event ingestion, candle aggregation, and trading signal generation. **Built to the specification** with support for future GPUNetIO integration.

## Architecture Overview

```
Binance Data → CSV→Binary → UDP Simulation → GPU Pipeline → Results Logger
           (Phase 1-2)    (Phase 3)      (Phase 4-6)        (Phase 7)
```

### Key Features

- ✅ **Binary Event Format**: Optimized 40B `MarketEvent` struct (no CSV parsing on GPU)
- ✅ **Candle Aggregation**: Real-time OHLCV aggregation in `apply_events_kernel` (60-second intervals)
- ✅ **Trading Signals**: Momentum + VWAP strategy (`strategy_kernel`) → BUY/SELL orders
- ✅ **Modular GPU Pipeline**: 4 independent kernels (decode → events → strategy → pack)
- ✅ **Pinned Host Memory**: Async H2D/D2H for minimal overhead
- ✅ **UDP Simulation**: Micro-batched packet delivery with configurable pacing
- ✅ **Real Data Support**: Binance trades download + CSV→BIN conversion
- ✅ **Throughput Benchmarking**: Detailed kernel timing & signal rate metrics
- ✅ **Future-Ready**: UDP ingress is decoupled from GPU kernels (swap to DPDK/GPUNetIO later)

## Build Targets

```bash
make converter        # CSV → Binary converter
make replayer         # UDP replayer (fake or real data)
make receiver         # GPU + UDP receiver (integrated)
make gpu              # GPU pipeline standalone test
make logger           # Results logger
make all              # Build everything
make clean            # Clean binaries
```

## Quick Start

### 1. Build All Modules
```bash
cd mini_trader
make all
```

### 2. GPU Standalone Test (No UDP Required)
```bash
./gpu_staging 100000 50000
# Processes 100K fake events through kernel pipeline
# Output: signal counts, kernel timing per batch
```

**Expected output:**
```
GPU Pipeline Staging Test
Events: 100000, Max batch: 50000
Processing 100 batches of 1000 events

[GPU Pipeline] Batch: 1000 events, 6 signals (3 buy, 3 sell), 12.345 ms
...
Test completed successfully!
```

### 3. Full End-to-End Test (UDP)

**Terminal 1: Start GPU receiver**
```bash
./udp_receiver 9999 50000 10
# Listens on port 9999, max 50K events/batch, processes 10 batches then exits
```

**Terminal 2: Start UDP replayer**
```bash
# Synthetic data (no download needed)
./udp_replayer 127.0.0.1 9999 FAKE 5000 100000 0
# Sends 100K fake events in 5K-event batches, blast pacing

# OR real Binance data (after conversion)
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 100000 0
```

**Output (receiver terminal):**
```
[GPU] Batch 1: 5000 events, 12 signals (7B/5S), 10.234ms
[GPU] Batch 2: 5000 events, 15 signals (9B/6S), 9.876ms
...
=== Final Statistics ===
Total events: 100000
Total batches: 20
Avg batch size: 5000
```

### 4. Use Real Binance Data (Optional)

```bash
# Download daily trades CSV for date range
./binance_downloader.sh 2023-01-01 2023-01-31
# Downloads to data/raw/<SYMBOL>/<DATE>.csv

# Convert CSV to binary
mkdir -p data/bin
./csv_to_bin_converter data/raw/BTCUSDT/2023-01-01.csv BTCUSDT data/bin/BTCUSDT.bin

# Replay from binary (same as step 3)
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 100000 0
```

## File Structure

### Core Headers
- **`include/market_event.h`**
  - `MarketEvent`: 40B struct (ts_ns, symbol_id, price, qty, side, trade_id)
  - `Candle`: OHLCV candle with timestamp
  - `PerSymbolState`: per-symbol tracking (candles, VWAP, features)
  - `Order`: trading signal output
  - Symbol mapping for 10 tickers (BTC, ETH, BNB, SOL, XRP, ADA, DOGE, TRX, AVAX, DOT)

### Phase 1-2: Data Acquisition & Conversion
- **`binance_downloader.sh`**: Download Binance trades CSV
- **`src/csv_to_bin_converter.cpp`**: CSV → optimized binary format

### Phase 3: UDP Simulation
- **`src/udp_replayer.cpp`**: Micro-batched UDP sender
  - Modes: fake data generation or load from .bin files
  - Pacing: blast (0), real-time (1), hybrid (2)

### Phase 4-6: Receiver + GPU Pipeline
- **`src/udp_receiver.cpp`**: Integrated UDP receiver + GPU pipeline
  - Parses UDP packets with magic validation (0xDEADBEEF)
  - Feeds batches to GPU kernels
  - Measures kernel throughput

- **`src/gpu_staging.cu`**: Standalone GPU pipeline test (no UDP)
  - `decode_parse_kernel`: Validate/reformat (pass-through)
  - `apply_events_kernel`: **Candle aggregation** (OHLCV, VWAP)
  - `strategy_kernel`: Signal generation (BUY/SELL)
  - `pack_orders_kernel`: Compact orders + statistics

### Phase 7: Results Logging
- **`src/results_logger.cpp`**: Log orders and batch statistics to CSV
  - Outputs: `orders.csv`, `batch_stats.csv`
  - Prints: throughput, signal rate, avg kernel latency

### Documentation
- **`PIPELINE_SPEC.md`**: Full specification & detailed walkthrough
- **`quickstart.sh`**: Automated build & test script

## GPU Kernel Pipeline

### `apply_events_kernel` ⭐ Core Responsibility: Candle Aggregation

For each event:
1. Determine 60-second candle interval (nanosecond timestamp)
2. If interval changed, close previous candle → move to history buffer
3. Update current candle: OHLCV (high=max, low=min, close=latest, volume=Σqty)
4. Compute VWAP (volume-weighted average price) incrementally

**State Tracking:**
- Current candle in progress
- Last 10 closed candles (ring buffer)
- VWAP, last price, total trades per symbol

### `strategy_kernel` - Signal Generation

Simple momentum + VWAP strategy:
```
For each symbol:
  if (price_change > 0.1% AND price > VWAP) → BUY
  if (price_change < -0.1% AND price < VWAP) → SELL
```

### `pack_orders_kernel` - Statistics & Compaction

- Copy orders to contiguous output buffer
- Count BUY vs SELL signals
- Sum total order quantity
- Produce `OrderStats{total_signals, buy_count, sell_count, total_qty}`

## Performance Metrics

Pipeline outputs:
- **Throughput**: events/second (kernel time ÷ total events)
- **Latency**: milliseconds per batch (H2D + kernels + D2H)
- **Signal Rate**: percentage of events generating orders
- **Batch Size Impact**: scalable 1K–100K events/batch

Example benchmark:
```
10 batches × 100K events = 1M total
Kernel time: 1.234 seconds
Throughput: ~810K events/sec
Avg batch latency: 123.4 ms
Signal rate: 0.60% (6K orders / 1M events)
```

## Usage Examples

### Benchmarking
```bash
# Large-scale test: 1M events in 50K batches
timeout 60 ./udp_receiver 9999 50000 20 &
./udp_replayer 127.0.0.1 9999 FAKE 50000 1000000 0
wait
```

### Real Data Test
```bash
./binance_downloader.sh 2023-06-01 2023-06-30
./csv_to_bin_converter data/raw/BTCUSDT/2023-06-15.csv BTCUSDT data/bin/BTCUSDT.bin

timeout 60 ./udp_receiver 9999 50000 100 &
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 500000 1  # real-time pacing
wait
```

### Results Logging
```bash
./results_logger print
# Shows example CSV output and summary statistics
```

## Architecture: Future GPUNetIO Integration

Today: UDP socket ingress
```
UDP packets → udp_receiver (socket) → GPU kernels
```

Later: GPUNetIO RXQ ingress (when NIC permissions fixed)
```
NIC RX queue → GPUNetIO RXQ → GPU kernels
```

**Key Design**: GPU kernel pipeline is **unchanged**. Only the ingress path swaps from UDP socket to DPDK/GPUNetIO. This ensures all development here is preserved.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| CUDA compilation error | Ensure CUDA toolkit installed; check `nvcc --version` |
| "GPU out of memory" | Reduce `max_events_per_batch` in receiver |
| No signals generated | Verify `strategy_kernel` thresholds; check sample data |
| Slow throughput | Use pacing_mode=0 (blast); increase batch_size |
| Port 9999 in use | Change port number in both replayer & receiver |

## Next Steps

- [ ] Download real Binance data for your trading symbols
- [ ] Benchmark throughput with varying batch sizes
- [ ] Tune strategy thresholds for your signal generation
- [ ] Integrate with DPDK for higher performance (optional)
- [ ] Swap to GPUNetIO when NIC permissions available

## License

See parent repo LICENSE.

