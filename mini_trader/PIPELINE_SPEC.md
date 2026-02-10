# GPU-Accelerated Trading Pipeline - Implementation Summary

## Overview

This repository implements a **modular GPU-accelerated market data processing and trading pipeline** as described in the specification. The system is designed to:

1. **Ingest market data** (Binance trades) via UDP simulation
2. **Convert data** from CSV to optimized binary format
3. **Process events on GPU** through a modular kernel pipeline
4. **Generate trading signals** based on candle aggregation and strategy logic
5. **Output results** with detailed statistics and logging

Later, the UDP ingress can be swapped for **GPUNetIO RXQ** without changing the GPU kernel pipeline.

---

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    HOST-SIDE DATA FLOW                          │
├─────────────────────────────────────────────────────────────────┤
│  Binance Trades CSV ──→ CSV→BIN Converter ──→ .bin files        │
│         (Phase 1)            (Phase 2)       (per symbol)       │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ↓
┌─────────────────────────────────────────────────────────────────┐
│                     UDP REPLAY (Phase 3)                        │
├─────────────────────────────────────────────────────────────────┤
│  udp_replayer reads .bin files ──→ batched UDP packets          │
│                                    (MarketEvent arrays)         │
│  Pacing modes: blast, real-time, hybrid                        │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ↓ UDP packets (localhost:9999)
┌─────────────────────────────────────────────────────────────────┐
│                   UDP RECEIVER (Phase 4)                        │
├─────────────────────────────────────────────────────────────────┤
│  udp_receiver listens on port 9999 ──→ parses packets          │
│  Validates magic number & event count                           │
│  Batches events into pinned host buffers                        │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ↓
┌─────────────────────────────────────────────────────────────────┐
│                  GPU KERNEL PIPELINE (Phase 5-6)               │
├─────────────────────────────────────────────────────────────────┤
│  1. decode_parse_kernel      : validate/reformat events         │
│  2. apply_events_kernel      : OHLCV candle aggregation         │
│  3. strategy_kernel          : generate BUY/SELL signals        │
│  4. pack_orders_kernel       : compact orders + stats           │
│                                                                 │
│  State: per-symbol candles (history), VWAP, prices             │
│  Output: Order[], OrderStats{signals, buy/sell counts}         │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ↓
┌─────────────────────────────────────────────────────────────────┐
│                  RESULTS LOGGER (Phase 7)                       │
├─────────────────────────────────────────────────────────────────┤
│  results_logger reads Order[] and stats ──→ CSV logs            │
│  Outputs:                                                       │
│  - orders.csv : detailed order list                             │
│  - batch_stats.csv : signal rates, throughput, timing           │
│  - summary : event/signal counts, avg kernel time               │
└─────────────────────────────────────────────────────────────────┘
```

---

## File Structure

### Core Data Definitions
- **`include/market_event.h`** (Module A)
  - `MarketEvent`: 40B struct with ts_ns, symbol_id, price, qty, side, trade_id
  - `Candle`: OHLCV + timestamp for fixed intervals
  - `PerSymbolState`: tracks per-symbol state (candle history, VWAP, features)
  - `Order`: trading signal output (symbol, side, price, qty)
  - Symbol mapping for 10 tickers: BTCUSDT, ETHUSDT, BNBUSDT, SOLUSDT, XRPUSDT, ADAUSDT, DOGEUSDT, TRXUSDT, AVAXUSDT, DOTUSDT

### Data Acquisition & Conversion
- **`binance_downloader.sh`** (Module B)
  - Downloads daily Binance trades CSV zips for 10 symbols
  - Input: date range (default: 2023-01-01 to 2023-01-31)
  - Output: `data/raw/<SYMBOL>/<DATE>.csv`
  - Usage: `./binance_downloader.sh 2023-01-01 2023-01-31`

- **`src/csv_to_bin_converter.cpp`** (Module C)
  - Converts CSV → binary `MarketEvent` format
  - Parses timestamp(ms) → ns, maps symbol strings → uint32_t IDs
  - Sorts by timestamp for efficient replay
  - Input: `data/raw/<SYMBOL>/<DATE>.csv`
  - Output: `data/bin/<SYMBOL>.bin`
  - Usage: `./csv_to_bin_converter <input.csv> <symbol> <output.bin>`

### Replay & UDP Simulation
- **`src/udp_replayer.cpp`** (Module D)
  - Reads `.bin` files or generates fake events
  - Micro-batches events into UDP packets with `PacketHeader` (magic=0xDEADBEEF)
  - Pacing modes:
    - 0 (blast): send as fast as possible
    - 1 (real-time): 1μs/event sleep
    - 2 (hybrid): burst + periodic sleep
  - Input: `*.bin` file or `FAKE` for synthetic data
  - Output: UDP packets to 127.0.0.1:9999 (or custom host:port)
  - Usage:
    ```bash
    # Real data
    ./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 1000 100000 0

    # Fake data
    ./udp_replayer 127.0.0.1 9999 FAKE 5000 1000000 2
    ```

### Receiver + GPU Pipeline
- **`src/udp_receiver.cpp`** (Module E + F + G-J)
  - **UDP Receiver**: binds to port 9999, parses `PacketHeader`, validates magic
  - **GPU Pipeline**:
    - `GPUPipeline` class: manages pinned host buffers, device memory, CUDA streams
    - `decode_parse_kernel`: validates/reformats events
    - `apply_events_kernel`: candle aggregation (OHLCV per symbol)
      - Tracks 60-second candles
      - Updates VWAP, last_price, trade_count
      - Closes candles when time interval changes
    - `strategy_kernel`: generates BUY/SELL signals
      - BUY: price > VWAP + positive momentum
      - SELL: price < VWAP + negative momentum
    - `pack_orders_kernel`: compacts orders, computes stats
  - Input: UDP packets on port 9999
  - Output: prints batch stats to stdout, final summary
  - Usage:
    ```bash
    ./udp_receiver 9999 50000 -1   # port, batch_limit, max_batches (-1=forever)
    ```

### GPU Standalone Test
- **`src/gpu_staging.cu`** (Phase 5-6 standalone)
  - Standalone GPU pipeline test (no UDP)
  - Generates fake event batches
  - Runs through full kernel pipeline
  - Prints signal counts and kernel timing
  - Usage:
    ```bash
    ./gpu_staging 100000 50000   # num_events, max_batch
    ```

### Results Logging
- **`src/results_logger.cpp`** (Module K)
  - Logs trading results to CSV
  - Outputs:
    - `orders_example.csv`: symbol, side, price, qty, timestamp
    - `batch_stats_example.csv`: batch_num, event_count, signal_count, kernel_time_ms
  - Prints summary: total events, signal rate, throughput, avg kernel time
  - Usage:
    ```bash
    ./results_logger print   # example output mode
    ```

---

## Build Instructions

### Prerequisites
- CUDA Toolkit (nvcc compiler)
- g++ (C++17 standard)
- Make or manual compilation

### Compile Individual Modules
```bash
cd mini_trader

# C++ tools (normal socket receivers were Phase 4A, not needed now)
g++ -O3 -std=c++17 -Iinclude src/csv_to_bin_converter.cpp -o csv_to_bin_converter
g++ -O3 -std=c++17 -Iinclude src/udp_replayer.cpp -o udp_replayer
g++ -O3 -std=c++17 -Iinclude src/results_logger.cpp -o results_logger

# CUDA modules
nvcc -O3 -std=c++17 -Iinclude src/gpu_staging.cu -o gpu_staging
nvcc -O3 -std=c++17 -Iinclude src/udp_receiver.cpp -o udp_receiver
```

### Alternative: Use Makefile
```bash
cd mini_trader

make converter        # csv_to_bin_converter
make replayer         # udp_replayer
make receiver         # udp_receiver (integrated with GPU)
make gpu              # gpu_staging (standalone test)
make logger           # results_logger

make all              # compiles everything
make clean            # removes binaries
```

---

## Usage Walkthrough

### Step 1: Prepare Data

**Option A: Download Real Binance Data**
```bash
cd mini_trader
./binance_downloader.sh 2023-01-01 2023-01-31
# Downloads to data/raw/BTCUSDT/, data/raw/ETHUSDT/, etc.
```

**Option B: Use Synthetic Data (No Download Needed)**
```bash
# Skip to Step 2 and use FAKE mode in udp_replayer
```

### Step 2: Convert CSV → Binary

```bash
# Convert one symbol (if using real data)
mkdir -p data/bin
./csv_to_bin_converter data/raw/BTCUSDT/2023-01-01.csv BTCUSDT data/bin/BTCUSDT.bin

# Repeat for other symbols or adapt the script
```

### Step 3A: GPU Standalone Test (Optional)

```bash
# Test GPU pipeline without UDP
./gpu_staging 100000 50000  # 100k events, 50k max batch size
# Output:
#   [GPU Pipeline] Batch: 1000 events, X signals (Y buy, Z sell), T.TTT ms
#   [GPU Pipeline] Batch: 1000 events, X signals (Y buy, Z sell), T.TTT ms
#   ...
#   Test completed successfully!
```

### Step 3B: Full End-to-End Test

**Terminal 1: Start Receiver (listens on port 9999)**
```bash
./udp_receiver 9999 50000 100
# Output:
#   UDP Receiver + GPU Pipeline
#   Listening on port 9999 (batch_limit=50000)
#   Initializing GPU pipeline...
#   Ready to receive UDP packets...
#
#   [GPU] Batch 1: 5000 events, 25 signals (15B/10S), 11.234ms
#   [GPU] Batch 2: 5000 events, 32 signals (19B/13S), 10.987ms
#   ...
#   Max batches reached (100), exiting...
#
#   === Final Statistics ===
#   Total events: 500000
#   Total batches: 100
#   Avg batch size: 5000
```

**Terminal 2: Start Replayer (sends data via UDP)**
```bash
# Real data from bin file
./udp_replayer 127.0.0.1 9999 data/bin/BTCUSDT.bin 5000 100000 0

# OR synthetic data with blast pacing
./udp_replayer 127.0.0.1 9999 FAKE 5000 500000 0
# Output:
#   Generated 500000 fake events
#   sent packet_seq=100 sent=500000
#   Replay finished: 500000 events in 2345.678 ms
```

### Step 4: View Results

```bash
./results_logger print
# Output:
#   === Trading Pipeline Summary ===
#   Total batches: 3
#   Total events: 3000
#   Total signals: 18 (0.60%)
#   BUY signals: 10
#   SELL signals: 8
#   Total kernel time: 35.40 ms
#   Throughput: 84746 events/sec
#   Avg kernel time per batch: 11.800 ms
#   Orders written to orders_example.csv (3 orders)
#   Batch stats written to batch_stats_example.csv (3 batches)
```

---

## GPU Kernel Details

### 1. decode_parse_kernel
**Purpose**: Validate and optionally reformat events.
- Currently a **pass-through** (no-op).
- Can be extended for: decompression, format conversion, validation.

### 2. apply_events_kernel ⭐ **Core Responsibility: Candle Aggregation**

**Input**:
- `MarketEvent[]` decoded events
- `PerSymbolState[]` per-symbol state (candles, VWAP, etc.)

**Processing**:
- For each event, determine the 60-second candle it belongs to
- If candle interval changed, **close the previous candle** (move to history)
- Update current candle: OHLCV (high=max price, low=min price, close=last price, volume=Σqty)
- Compute VWAP (volume-weighted average price) incrementally

**Output**: Updated `PerSymbolState` with latest candles and features

### 3. strategy_kernel

**Input**: `PerSymbolState[]` (candles, VWAP, price history)

**Logic**:
```
For each symbol:
  price_change = (current close - previous close) / previous close

  if price_change > 0.1% AND price > VWAP:
    → emit BUY order

  if price_change < -0.1% AND price < VWAP:
    → emit SELL order
```

**Output**: `Order[]` array, atomic increment of order_count

### 4. pack_orders_kernel

**Input**: `Order[]` (all generated orders), order count

**Processing**:
- Copy orders into compact layout
- Count BUY vs SELL
- Sum total quantity

**Output**:
- Compacted `Order[]`
- `OrderStats{total_signals, buy_count, sell_count, total_qty}`

---

## Key Features

### ✅ Modular Design
- Each kernel is independent and testable
- GPU pipeline is **decoupled from UDP ingress**
- Later swap UDP → GPUNetIO RXQ without kernel changes

### ✅ Efficient Batching
- UDP packets contain 1K–50K events (configurable)
- Pinned host buffers minimize H2D copy overhead
- Async CUDA streams (one stream per pipeline)

### ✅ Realistic Market Data
- Binance trades CSV → optimized binary format (no CSV parsing on GPU)
- Supports real historical data or configurable synthetic data
- Pacing modes: blast, real-time, hybrid

### ✅ Signal Generation
- **Per-symbol candle aggregation** (60-second intervals)
- **Momentum + VWAP strategy** (simple but meaningful)
- Generates measurable BUY/SELL signals for benchmarking

### ✅ Comprehensive Logging
- Batch-level stats: event count, signal rate, kernel time
- Order-level details: symbol, side, price, qty, timestamp
- Summary statistics: throughput (events/sec), avg kernel latency

---

## Performance Benchmarking

The pipeline outputs timing and counting statistics useful for:
1. **Throughput**: events/sec (kernel time ÷ total events)
2. **Latency**: milliseconds per batch (H2D + kernels + D2H)
3. **Signal Rate**: percentage of events generating orders
4. **Scalability**: varying batch sizes (1K–100K events)

Example benchmark:
```
Processing 10 batches × 100K events = 1M total
Kernel time: 1234.5 ms
Throughput: 1,000,000 / 1.2345 = ~810K events/sec
Avg kernel time: 1234.5 / 10 = 123.45 ms per batch
```

---

## Future: GPUNetIO Integration

When NIC permissions are fixed:

1. Replace UDP receiver with **DPDK-based ingress**
2. Map NIC RX queue → GPU memory (dmabuf)
3. Point `udp_receiver` to GPUNetIO RXQ instead of socket
4. **Kernel pipeline remains unchanged**

This ensures the effort here is preserved; only the data **ingress path** changes.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `GPU out of memory` | Reduce `max_events_per_batch` |
| `Bad magic in packet` | Verify replayer is sending to correct port (9999) |
| `No CUDA device found` | Ensure CUDA toolkit installed, GPU drivers up-to-date |
| `Symbol not found` | Check symbol is in 10-ticker list (BTCUSDT, ETHUSDT, etc.) |
| `Slow throughput` | Use pacing_mode=0 (blast), increase batch_size |

---

## Summary

This implementation satisfies **all phases** of the specification:

- ✅ **Phase 0**: Binary event model + symbol mapping
- ✅ **Phase 1**: Binance downloader script
- ✅ **Phase 2**: CSV → binary converter
- ✅ **Phase 3**: UDP replayer (micro-batched, configurable pacing)
- ✅ **Phase 4**: UDP receiver (socket-based, ready for DPDK swap)
- ✅ **Phase 5**: GPU staging + async H2D/D2H
- ✅ **Phase 6**: Full kernel pipeline (decode, apply_events, strategy, pack_orders)
- ✅ **Phase 7**: Results logger (CSV + summary stats)

The system is **ready to benchmark GPU throughput** with realistic or synthetic market data, and **ready to integrate GPUNetIO** when network permissions allow.
