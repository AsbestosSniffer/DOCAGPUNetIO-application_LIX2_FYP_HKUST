# Architecture — Three-System Benchmark Design

This document explains the architecture of all three systems, the shared data structures, the GPU kernel pipeline, and the DOCA GPUNetIO integration design.

---

## 1. Overview: Why Three Systems?

The FYP thesis is: **DOCA GPUNetIO eliminates CPU bottlenecks in real-time packet processing by steering network data directly to GPU memory.**

To prove this, we benchmark three architectures that process identical market data through identical trading logic, differing only in how data reaches the processing engine:

```
                    Binance Market Data
                           |
            +--------------+--------------+
            |              |              |
       [SYSTEM 1]    [SYSTEM 2]    [SYSTEM 3]
      CPU Baseline  GPUDirect RDMA DOCA GPUNetIO

     CPU socket recv  CPU recv->GPU  NIC->GPU direct
     CPU parse        GPU kernels    GPU kernels
     CPU candles      D2H orders     GPU semaphores
     CPU strategy                    D2H orders
     CPU orders
            |              |              |
            +--------------+--------------+
                           |
                   Benchmark Comparison
               (latency, throughput, CPU util)
                           |
                    PnL / Win Rate
```

---

## 2. Shared Data Structures (common/)

All three systems share the same data types defined in `common/market_event.h`. This ensures apples-to-apples comparison.

### MarketEvent (input)

```c
struct MarketEvent {
    uint64_t ts_ns;      // Nanosecond timestamp
    uint32_t symbol_id;  // 0-9 (mapped from BTCUSDT..DOTUSDT)
    float    price;      // Trade price
    float    qty;        // Trade quantity
    uint8_t  side;       // 0=buyer, 1=seller (isBuyerMaker from Binance)
    uint64_t trade_id;   // For deduplication
};
```

### PerSymbolState (processing state)

Tracks the current candle being built and a ring buffer of the last 10 closed candles per symbol:

```c
struct PerSymbolState {
    // Current candle in progress
    float candle_open, candle_high, candle_low, candle_close;
    float candle_volume;
    uint32_t candle_trade_count;
    uint64_t candle_start_ts;

    // Closed candle history (ring buffer, last 10)
    Candle closed_candles[10];
    int closed_count;

    // Features for strategy
    float vwap;          // Volume-weighted average price
    float last_price;
    uint32_t total_trades;
};
```

### Order (output)

```c
struct Order {
    uint32_t symbol_id;
    uint8_t  side;       // 0=buy, 1=sell
    float    price;
    float    qty;
    uint64_t ts_ns;
    uint8_t  order_type; // 0=market, 1=limit
};
```

### Candle (intermediate)

```c
struct Candle {
    uint64_t ts_start_ns;
    float open, high, low, close;
    float volume;
    uint32_t trade_count;
};
```

---

## 3. The 4-Kernel Pipeline

All three systems execute the same 4-stage pipeline. On the CPU baseline, these are sequential functions. On GPU systems, these are CUDA kernels.

### Kernel 1: decode_parse

**Purpose**: Validate and optionally reformat raw events.
**Parallelism**: 1 thread per event (embarrassingly parallel).
**Current behavior**: Pass-through (copy). Designed for future extension: decompression, format conversion, checksum validation.

```
Input:  MarketEvent[N] (raw)
Output: MarketEvent[N] (validated)
Threads: N (one per event)
```

### Kernel 2: apply_events

**Purpose**: Update per-symbol candle state and compute features.
**Parallelism**: 1 thread per event, atomics for per-symbol state.

For each event:
1. Determine which 60-second candle interval it belongs to: `candle_ts = (ts_ns / 60e9) * 60e9`
2. If the candle interval changed from the current candle, close the current candle (move to ring buffer history) and start a new one
3. Update current candle: `high = max(high, price)`, `low = min(low, price)`, `close = price`, `volume += qty`
4. Update VWAP incrementally: `vwap = (vwap * (n-1) + price) / n`

```
Input:  MarketEvent[N], PerSymbolState[10]
Output: PerSymbolState[10] (updated in-place)
Threads: N
```

### Kernel 3: strategy

**Purpose**: Generate BUY/SELL trading signals based on momentum and VWAP.
**Parallelism**: 1 thread per symbol (10 threads).

For each symbol with at least one closed candle:
```
price_change = (current_close - previous_candle_close) / previous_candle_close

if price_change > 0.001 AND last_price > VWAP:
    emit BUY order (qty=0.01)

if price_change < -0.001 AND last_price < VWAP:
    emit SELL order (qty=0.01)
```

Orders are written to a shared array using `atomicAdd` on the order count.

```
Input:  PerSymbolState[10]
Output: Order[up to 20], order_count
Threads: 10 (one per symbol)
```

### Kernel 4: pack_orders

**Purpose**: Compute aggregate statistics over the generated orders.
**Parallelism**: 1 thread per order.

```
Input:  Order[order_count]
Output: OrderStats { total_signals, buy_count, sell_count, total_qty }
```

---

## 4. System 1: CPU Baseline (cpu_baseline/)

**File**: `cpu_baseline/cpu_pipeline.cpp`

The CPU baseline implements all 4 stages as sequential C++ functions. This is intentionally single-threaded to model the worst case: a system where the CPU must handle all packet processing, candle aggregation, and strategy evaluation.

### Data Flow

```
Data Source (synthetic/file/UDP)
    |
    v
cpu_pipeline.decode_parse()    -- memcpy validation
    |
    v
cpu_pipeline.apply_events()    -- sequential loop over events
    |
    v
cpu_pipeline.strategy()        -- sequential loop over 10 symbols
    |
    v
cpu_pipeline.pack_orders()     -- count/aggregate
    |
    v
LatencyStats + ThroughputMeter + PnLTracker
```

### Why Single-Threaded?

The project description states: "In lower-power platforms, the CPU can easily become the bottleneck." Single-threaded CPU processing is the realistic baseline for embedded/edge systems. Multi-threaded CPU would be a less compelling comparison target.

### Input Modes

```bash
# Synthetic (default): generate N events, process in batches
./cpu_baseline 1000000 1000

# File replay: read binary MarketEvent file
./cpu_baseline --file path/to/data.bin 1000

# UDP receiver: listen for UDP packets from replayer
./cpu_baseline --udp 9999 10000
```

---

## 5. System 2: GPU RDMA Pipeline (gpu_rdma/)

**File**: `gpu_rdma/src/gpu_pipeline.cu`

The GPU RDMA pipeline receives data on the CPU (via socket or file), copies it to GPU using pinned memory and `cudaMemcpyAsync`, processes through the 4 CUDA kernels, and copies results back.

### Data Flow

```
Data Source (synthetic/file/UDP)
    |
    v
CPU: copy events to pinned host buffer (h_events)
    |
    v  cudaMemcpyAsync (Host->Device, pinned memory = GPUDirect RDMA path)
    |
    v
GPU: decode_parse_kernel<<<grid, 256>>>
    |
    v
GPU: apply_events_kernel<<<grid, 256>>>
    |
    v
GPU: strategy_kernel<<<1, 256>>>
    |
    v
GPU: pack_orders_kernel<<<1, 256>>>
    |
    v  cudaMemcpyAsync (Device->Host)
    |
    v
CPU: read h_stats, h_orders -> PnLTracker
```

### CUDA Event Timing

The GPU pipeline uses `cudaEventRecord` and `cudaEventElapsedTime` for precise GPU-side timing:

```
ev_start  -> H2D copy start
ev_h2d    -> H2D copy end / kernel start
ev_kern   -> all kernels complete
ev_d2h    -> D2H copy complete
ev_end    -> synchronization complete
```

This gives us: H2D time, kernel time, D2H time, and total pipeline time — all measured on the GPU clock (no host timer skew).

### GPU Selection

The pipeline calls `cudaSetDevice(1)` because GPU 0 is running VLLM (using 13.3GB of 15.3GB). GPU 1 has ~15.2GB free.

### Input Modes

Same as CPU baseline: synthetic (default), `--file`, `--udp`.

---

## 6. System 3: DOCA GPUNetIO Pipeline (gpu_doca/)

**Files**: `gpu_doca/doca_trading.c` (CPU side), `gpu_doca/gpu_kernels/packet_recv.cu` (GPU side)

This is the core contribution. The DOCA GPUNetIO pipeline uses the BlueField-3 DPU to steer network packets directly into GPU memory, bypassing the CPU entirely for the data path.

### Architecture

```
BlueField-3 NIC (ConnectX-7)
    |
    +-- DOCA Flow rules steer matching traffic to GPU RXQ
    |
    v
GPU RXQ (doca_eth_rxq) -- packets land in GPU memory (GPUDirect RDMA / dmabuf)
    |
    v
+--------------------------------------------------+
| GPU Persistent Kernel: gpu_receive_and_process()  |
|                                                    |
| 1. doca_gpu_dev_eth_rxq_recv()  -- receive burst   |
| 2. parse_packet_to_event()      -- Eth/IP/TCP->    |
|                                    MarketEvent     |
| 3. apply events (candle aggregation)               |
| 4. strategy (signal generation)                    |
| 5. doca_gpu_dev_semaphore_set_status(READY)        |
+--------------------------------------------------+
    |
    v (GPU semaphore)
    |
CPU Control Loop:
    doca_gpu_semaphore_get_status()
    if READY: read orders, update PnL, set FREE
```

### DOCA Components Used

| Component | Purpose |
|-----------|---------|
| `doca_gpu_create()` | Initialize GPU device handler |
| `doca_eth_rxq_create()` | Create Ethernet receive queue mapped to GPU memory |
| `doca_flow_pipe_create()` | Steer specific traffic (by port/protocol) to GPU RXQ |
| `doca_gpu_semaphore_create()` | GPU-to-CPU signaling (16-slot ring buffer) |
| `doca_gpu_dev_eth_rxq_recv()` | GPU kernel call to receive packets directly |
| `doca_gpu_dev_eth_rxq_get_pkt_addr()` | Get raw packet address in GPU memory |

### GPU Packet Parsing

The GPU kernel parses raw Ethernet frames in-place on the GPU:

```
Ethernet Header (14 bytes): dst_mac[6] + src_mac[6] + ether_type[2]
    |
    v (if ether_type == 0x0800 -> IPv4)
    |
IPv4 Header (20+ bytes): protocol field determines TCP (6) or UDP (17)
    |
    v
TCP Header (20+ bytes) or UDP Header (8 bytes)
    |
    v
Payload: binary MarketEvent struct
```

In production, a local proxy on the DPU ARM cores (or a pre-processing step) converts Binance JSON WebSocket messages into the binary MarketEvent format before the packets reach the GPU. This avoids JSON parsing on the GPU.

### Stub Mode

When building without DOCA SDK (e.g., on a local development machine), the code compiles in stub mode (`#ifndef HAVE_DOCA`). The stub simulates the DOCA control loop with `usleep()` calls and provides a `gpu_receive_stub` kernel for testing the GPU-side trading logic without actual NIC integration.

### Build

```bash
cd gpu_doca
meson setup build
ninja -C build
```

Requires DOCA SDK at `/opt/mellanox/doca/`. See [BUILD.md](BUILD.md) for details.

---

## 7. Shared Infrastructure (common/)

### benchmark.h — Timing and Metrics

- **`now_ns()`**: `clock_gettime(CLOCK_MONOTONIC)` wrapper returning nanoseconds
- **`LatencyStats`**: Records per-batch latency samples, computes p50/p99/p999/mean/stddev
- **`ThroughputMeter`**: Tracks total events and elapsed time, computes events/sec
- **`BenchmarkResult`**: Struct for CSV export of benchmark runs

### pnl_tracker.h — Trading Performance

All three systems use the same `PnLTracker` for fair comparison:
- FIFO order matching: BUY orders queued per-symbol, matched against SELL orders
- Tracks: cumulative PnL, peak PnL, win rate, max drawdown
- `process_orders(Order*, int)` called after each batch

### binance_feed.h — Data Sources

Three data source implementations:
- **`SyntheticFeed`**: Deterministic LCG-based random events with realistic base prices. Seed 42 produces identical data every run for reproducible benchmarks.
- **`FileReplayFeed`**: Reads binary `.bin` files (produced by `csv_to_bin_converter`). Supports batched iteration.
- **`UDPFeed`**: BSD socket UDP receiver with `PacketHeader` validation (magic=0xDEADBEEF).

---

## 8. Data Pipeline

### From Raw Binance Data to Binary Events

```
Binance API -> CSV download -> csv_to_bin_converter -> .bin file -> (FileReplayFeed | UDPFeed)
```

1. **Download**: `mini_trader/binance_downloader.sh` fetches daily trade CSVs from `data.binance.vision`
2. **Convert**: `mini_trader/csv_to_bin_converter` parses CSV (trade_id, price, qty, quoteQty, time, isBuyerMaker, isBestMatch), maps symbol strings to uint32 IDs, converts ms timestamps to ns, sorts by time, writes binary MarketEvent array
3. **Replay**: Binary files can be read directly by `--file` mode or sent over UDP by `udp_replayer`

### Synthetic Data Generation

`SyntheticFeed` uses a linear congruential generator (LCG) with seed 42:

```
rng = rng * 1103515245 + 12345  (standard LCG)
symbol = (rng >> 16) % 10
noise  = ((rng & 0xFFFF) / 65535 - 0.5) * 0.002  (+-0.1% price noise)
price  = base_prices[symbol] * (1 + noise)
```

Base prices approximate March 2026 Binance values (BTC~85K, ETH~3.2K, etc.).
Events are spaced 0.1ms apart (10K events/sec rate).

---

## 9. Benchmark Design

### What We Measure

| Metric | How | Tool |
|--------|-----|------|
| End-to-end latency | Time from batch start to orders available | `clock_gettime` (CPU), `cudaEventElapsedTime` (GPU) |
| H2D transfer time | GPU event timing around `cudaMemcpyAsync` | CUDA events |
| Kernel execution time | GPU event timing around kernel launches | CUDA events |
| D2H transfer time | GPU event timing around result copy | CUDA events |
| Throughput | Total events / total elapsed time | `ThroughputMeter` |
| CPU utilization | (future) `/proc/stat` sampling | Benchmark script |

### Latency Statistics

For each system, we collect per-batch latency and report:
- **p50** (median): Typical case
- **p99**: Tail latency
- **p999**: Worst case
- **mean**: Average
- **stddev**: Consistency

### Benchmark Variables

| Parameter | Values |
|-----------|--------|
| System | cpu, gpu_rdma, gpu_doca |
| Batch size | 100, 1000, 5000, 10000, 50000 |
| Total events | 100K (quick), 1M (full) |
| Data source | Synthetic (default), historical (real Binance) |

### Running Benchmarks

```bash
# Quick mode: 100K events, 3 batch sizes
./benchmark/run_benchmarks.sh quick

# Full mode: 1M events, 5 batch sizes, 3 repeats
./benchmark/run_benchmarks.sh full

# Plot results
python3 benchmark/plot_results.py
```

---

## 10. Why A2 GPUs Help the Argument

The NVIDIA A2 is a low-power (40W) Ampere GPU with 1280 CUDA cores and 16GB GDDR6. It is modest compared to A100/H100 datacenter GPUs. This actually strengthens the thesis:

- The project description says "lower-power platforms show CPU bottleneck more clearly"
- If even an A2 beats the CPU, the argument generalizes to any GPU
- The A2's sm_86 compute capability is fully supported by DOCA GPUNetIO (requires sm_80+)
- At 40W, we can also compute a compelling **events/sec/watt** efficiency metric
