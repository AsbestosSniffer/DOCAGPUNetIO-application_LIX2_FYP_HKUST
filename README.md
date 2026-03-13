# DOCA GPUNetIO Trading System — HKUST FYP

**GPU-Accelerated Market Data Processing with NVIDIA BlueField-3 DPU**

Student: LIX2 | Supervisor: Prof. Li Xin + NVIDIA HK Engineers
Hardware: BlueField-3 DPU (ConnectX-7) + 2x NVIDIA A2 GPUs (Ampere sm_86, 16GB each)
Server: `lxcpu1.cse.ust.hk` (Ubuntu 24.04, CUDA 13.1, DOCA SDK)

---

## What This Project Does

This project benchmarks three progressively faster architectures for real-time market data processing, demonstrating how NVIDIA DOCA GPUNetIO eliminates CPU bottlenecks by steering network packets directly to GPU memory.

All three systems process the same data through the same 4-kernel trading pipeline, producing identical trading signals — the only difference is **how data gets to the GPU**.

| System | Data Path | CPU Involvement |
|--------|-----------|-----------------|
| **System 1: CPU Baseline** | Socket -> CPU parse -> CPU candles -> CPU strategy -> CPU orders | 100% |
| **System 2: GPU RDMA** | Socket -> CPU recv -> pinned mem -> GPU kernels -> D2H orders | ~30% (recv + copy) |
| **System 3: DOCA GPUNetIO** | NIC -> GPU direct (bypass CPU) -> GPU kernels -> semaphore -> CPU logging | ~5% (logging only) |

### The 4-Kernel Trading Pipeline

Every system runs the same processing logic:

```
Kernel 1: decode_parse     -- Validate/reformat events (per-event parallel)
Kernel 2: apply_events     -- 60-second OHLCV candle aggregation + VWAP (per-event parallel)
Kernel 3: strategy         -- Momentum + VWAP signal generation (per-symbol parallel)
Kernel 4: pack_orders      -- Compact orders + compute statistics (per-order parallel)
```

The strategy generates BUY signals when price is above VWAP with positive momentum (>0.1%), and SELL signals when below VWAP with negative momentum (<-0.1%).

### Market Data

The system processes trades for 10 Binance cryptocurrency pairs simultaneously:
BTCUSDT, ETHUSDT, BNBUSDT, SOLUSDT, XRPUSDT, ADAUSDT, DOGEUSDT, TRXUSDT, AVAXUSDT, DOTUSDT

Data sources:
- **Synthetic**: Deterministic fake events for reproducible benchmarks (default)
- **Historical**: Real Binance trade CSVs converted to binary format
- **Live**: Binance WebSocket feed (future -- WebSocket connectivity confirmed)
- **UDP replay**: Replay binary files over localhost UDP for network-path testing

---

## Repository Structure

```
DOCAGPUNetIO-application_LIX2_FYP_HKUST/
|
+-- common/                          # Shared infrastructure (all 3 systems use these)
|   +-- market_event.h               #   MarketEvent, Candle, PerSymbolState, Order structs
|   +-- benchmark.h                  #   LatencyStats (p50/p99/p999), ThroughputMeter
|   +-- pnl_tracker.h                #   PnL tracking (win rate, drawdown, cumulative PnL)
|   +-- binance_feed.h               #   Data sources: FileReplay, UDP, Synthetic generator
|
+-- cpu_baseline/                    # System 1: CPU Baseline
|   +-- cpu_pipeline.cpp             #   Pure CPU 4-stage pipeline (single-threaded)
|
+-- gpu_rdma/                        # System 2: GPU RDMA Pipeline
|   +-- src/gpu_pipeline.cu          #   CUDA kernels + pinned memory + CUDA event timing
|
+-- gpu_doca/                        # System 3: DOCA GPUNetIO Pipeline
|   +-- doca_trading.c               #   CPU control loop + DOCA device/RXQ/flow/semaphore setup
|   +-- gpu_kernels/
|   |   +-- packet_recv.cu           #   GPU persistent kernel: NIC->GPU packet recv + parse + trade
|   +-- meson.build                  #   DOCA build system (meson/ninja)
|
+-- benchmark/                       # Benchmark automation
|   +-- run_benchmarks.sh            #   Automated benchmark runner (quick/full modes)
|   +-- plot_results.py              #   Chart generator (ASCII table + matplotlib PNG)
|
+-- mini_trader/                     # Original GPU pipeline (preserved, still builds)
|   +-- src/gpu_staging.cu           #   Standalone GPU pipeline test
|   +-- src/udp_receiver.cpp         #   UDP receiver + GPU integration
|   +-- src/udp_replayer.cpp         #   UDP packet replayer (blast/real-time/hybrid modes)
|   +-- src/csv_to_bin_converter.cpp #   Binance CSV -> binary MarketEvent converter
|   +-- src/results_logger.cpp       #   Trade results CSV logger
|   +-- binance_downloader.sh        #   Binance historical data downloader
|   +-- include/market_event.h       #   Original data structures
|
+-- mini_trader_cupy/                # CuPy reference implementation (Python)
|   +-- main.py                      #   CuPy-based pipeline alternative
|   +-- requirements.txt
|
+-- gpu_packet_processing/           # DOCA GPUNetIO reference app (from NVIDIA samples)
|   +-- gpu_packet_processing.c      #   Reference DOCA app (TCP/UDP/ICMP GPU processing)
|   +-- gpu_kernels/                 #   Reference GPU kernels for packet processing
|   +-- config_queues/               #   Queue and flow configuration
|   +-- meson.build
|
+-- Makefile                         # Top-level build (make cpu / make gpu / make all)
+-- .gitignore                       # Excludes binaries, CSVs, build artifacts
+-- PROJECT_PLAN.md                  # Detailed execution plan with phases and timeline
+-- ARCHITECTURE.md                  # System architecture and design decisions
+-- BUILD.md                         # Server setup, build instructions, dependencies
+-- TESTING_GUIDE.md                 # Comprehensive testing with real data
+-- setEnv.csh                       # DOCA environment setup
```

---

## Quick Start

### On the Server (lxcpu1.cse.ust.hk)

```bash
# Clone and checkout
git clone <repo-url>
cd DOCAGPUNetIO-application_LIX2_FYP_HKUST
git checkout development

# Build Systems 1 + 2 + tools
make all

# Smoke test with synthetic data
./cpu_baseline/cpu_baseline 100000 1000
./gpu_rdma/gpu_rdma_pipeline 100000 1000

# Run benchmark comparison
./benchmark/run_benchmarks.sh quick
```

### Real Data Test

```bash
# Download 1 day of Binance trades
cd mini_trader
./binance_downloader.sh 2026-02-08 2026-02-08
mkdir -p data/bin
./csv_to_bin_converter data/raw/BTCUSDT/2026-02-08.csv BTCUSDT data/bin/btcusdt.bin

# Test CPU baseline with real data
cd ..
./cpu_baseline/cpu_baseline --file mini_trader/data/bin/btcusdt.bin 1000

# Test GPU pipeline with real data
./gpu_rdma/gpu_rdma_pipeline --file mini_trader/data/bin/btcusdt.bin 1000
```

See [BUILD.md](BUILD.md) for full setup and [TESTING_GUIDE.md](TESTING_GUIDE.md) for comprehensive testing procedures.

---

## Documentation

| Document | Contents |
|----------|----------|
| [PROJECT_PLAN.md](PROJECT_PLAN.md) | Full execution plan, phases, timeline, risk register |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Three-system architecture, data flow, kernel details, DOCA integration |
| [BUILD.md](BUILD.md) | Server environment, dependencies, build instructions, GPU setup |
| [TESTING_GUIDE.md](TESTING_GUIDE.md) | Step-by-step testing: synthetic, historical, live, UDP replay |
| [mini_trader/PIPELINE_SPEC.md](mini_trader/PIPELINE_SPEC.md) | Original pipeline specification and module details |
| [mini_trader/TESTING_GUIDE.md](mini_trader/TESTING_GUIDE.md) | Original mini_trader testing guide |

---

## Hardware Environment

```
Server:   lxcpu1.cse.ust.hk (Ubuntu 24.04.4 LTS, kernel 6.17.0)
GPUs:     2x NVIDIA A2 (Ampere sm_86, 16GB GDDR6 each, 40W TDP)
DPU:      NVIDIA BlueField-3 (MT43244) with integrated ConnectX-7
          - 2x Ethernet ports (mlx5_0, mlx5_1)
          - DMA controller for SoC management
CUDA:     13.1 (V13.1.115)
Driver:   590.48.01
DOCA SDK: /opt/mellanox/doca/

PCIe Topology:
  GPU0 <-> GPU1:     PHB  (same PCIe Host Bridge)
  GPU0 <-> NIC0/1:   NODE (same NUMA node, different PCIe bridges)
  NIC0 <-> NIC1:     PIX  (single PCIe bridge)
  NUMA affinity:     Node 1, CPUs 12-23,36-47

NOTE: GPU 0 is running VLLM (13.3GB used). All development targets GPU 1.
```

---

## Benchmark Targets

| Metric | CPU Baseline | GPU RDMA | DOCA GPUNetIO |
|--------|-------------|----------|---------------|
| Data path hops | 4 (socket->parse->candle->strategy) | 3 (socket->GPU->D2H) | 1 (NIC->GPU direct) |
| Expected latency | ~100us-1ms | ~50-200us | ~10-50us |
| Expected throughput | ~100K ev/s | ~500K ev/s | ~1M+ ev/s |
| CPU utilization | 100% | ~30% | ~5% |

Benchmarks sweep: batch sizes (100, 1K, 10K, 50K), symbol counts (1, 5, 10), and data sources (synthetic, historical).

---

## Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Initial skeleton (archived) |
| `dev-cupy` | Most advanced original work (base for development) |
| `development` | **Active branch** -- three-system benchmark architecture |
