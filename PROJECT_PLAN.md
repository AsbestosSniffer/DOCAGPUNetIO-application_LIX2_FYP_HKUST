# FYP Project Plan: DOCA GPUNetIO Trading System
## HKUST LIX2 FYP — GPU-Accelerated Market Data Processing

**Date**: 2026-03-12
**Base Branch**: `dev-cupy` (most advanced, forked to new `development` branch)
**Hardware**: BlueField-3 DPU + 2x NVIDIA A2 GPUs (Ampere sm_86, 16GB each)
**Supervisor**: Prof. Li Xin + NVIDIA HK Engineers

---

## Table of Contents
1. [Project Viability Assessment](#1-project-viability-assessment)
2. [Branch Selection Rationale](#2-branch-selection-rationale)
3. [Architecture Overview](#3-architecture-overview)
4. [Execution Plan (Phases)](#4-execution-plan)
5. [GPU Justification](#5-gpu-justification)
6. [Benchmark Design](#6-benchmark-design)
7. [DOCA GPUNetIO Integration Plan](#7-doca-gpunetio-integration-plan)
8. [What I Need From You](#8-what-i-need-from-you)
9. [Ideas for Improvement](#9-ideas-for-improvement)
10. [Risk Register](#10-risk-register)

---

## 1. Project Viability Assessment

### Is this project viable? **Yes, strongly.**

**Why it works:**
- The project description explicitly says: *"In lower-power platforms, the CPU can easily become the bottleneck, masking GPU value."* — Your A2 GPUs are exactly this: low-power (40W) Ampere GPUs. This is the perfect hardware to demonstrate the thesis.
- Trading/market data is a legitimate real-time packet processing domain that fits the project requirements (signal processing, information gathering, input reconstruction).
- Binance provides free, high-volume market data via WebSocket — no exchange membership needed.
- You already have a working GPU pipeline (4 kernels, live PnL). The foundation is solid.

**Is the use of DOCA GPUNetIO justified?**
- **For real crypto trading?** Probably overkill. Binance latencies are in milliseconds, not microseconds.
- **For this FYP?** Absolutely. The point is to demonstrate the technology, not to build a profitable trading system. The trading application is a *vehicle* to showcase GPU packet processing acceleration.
- The project description specifically asks to "apply this technique to new domains" — applying GPUNetIO to financial data processing is exactly that.

**What makes this convincing for evaluation:**
1. Three-tier comparison (CPU → RDMA → DOCA GPUNetIO) with measurable latency/throughput differences
2. Real market data (Binance), not synthetic
3. Working trading strategy with live PnL tracking
4. GPU parallelism across 10 symbols simultaneously
5. Hardware-specific optimization for BlueField-3 + A2

---

## 2. Branch Selection Rationale

| Branch | Status | Decision |
|--------|--------|----------|
| `main` | Skeleton only (initial mini_trader + DOCA reference) | Skip |
| `development` | Full 7-phase pipeline, but missing bug fixes | Skip |
| **`dev-cupy`** | **Everything in development + 3 makefile fixes + live stats bug fix + CuPy alt + real Binance data (313MB)** | **SELECTED** |

**Action**: Fork from `dev-cupy` → create new `development` branch. The old `development` branch will be archived.

---

## 3. Architecture Overview

### Current State (What Exists)
```
Binance CSV → csv_to_bin_converter → .bin files
                                        ↓
                              udp_replayer (localhost:9999)
                                        ↓
                              udp_receiver (socket recv)
                                        ↓
                        ┌─── GPU PIPELINE (4 CUDA kernels) ───┐
                        │ 1. decode_parse_kernel (pass-through)│
                        │ 2. apply_events_kernel (60s candles) │
                        │ 3. strategy_kernel (momentum+VWAP)   │
                        │ 4. pack_orders_kernel (compact)       │
                        └──────────────┬───────────────────────┘
                                       ↓
                              Live PnL + CSV output
```

### Target State (What We're Building)
```
                    Binance WebSocket (live data)
                              ↓
            ┌─────────────────┼─────────────────┐
            ↓                 ↓                  ↓
     [SYSTEM 1]         [SYSTEM 2]         [SYSTEM 3]
    CPU Baseline      GPUDirect RDMA     DOCA GPUNetIO

  CPU socket recv    CPU recv → GPU     NIC → GPU direct
  CPU parse          GPUDirect RDMA     (bypass CPU)
  CPU candles        GPU kernels        GPU kernels
  CPU strategy       D2H orders         GPU semaphores
  CPU orders                            D2H orders
            ↓                 ↓                  ↓
            └─────────────────┼─────────────────┘
                              ↓
                    Benchmark Comparison
                    (latency, throughput, CPU util)
                              ↓
                    Mock Order Manager
                    (PnL, win rate, drawdown)
```

### The Three Systems Explained

**System 1 — CPU Baseline:**
- Standard BSD sockets receive Binance data
- All processing on CPU (candle aggregation, strategy, order generation)
- Purpose: Establish baseline. Show CPU bottleneck with increasing symbols/streams

**System 2 — GPUDirect RDMA:**
- CPU receives packets via socket
- Data transferred to GPU via GPUDirect RDMA (cudaMemcpyAsync with pinned memory)
- GPU runs the 4-kernel pipeline
- This is essentially what you already have (udp_receiver.cpp)

**System 3 — DOCA GPUNetIO:**
- BlueField-3 DPU steers packets directly to GPU memory (bypass CPU entirely)
- CUDA kernel on GPU uses `doca_gpu_dev_eth_rxq_recv()` to receive packets
- GPU processes packets in-place (zero-copy)
- GPU semaphores notify CPU of results
- CPU picks up orders and logs them
- Purpose: Demonstrate CPU-bypass advantage

---

## 4. Execution Plan

### Phase 0: Repository Setup (Day 1) ✅ PLANNING NOW
- [x] Analyze all three branches
- [x] Select `dev-cupy` as base
- [ ] Create new `development` branch from `dev-cupy`
- [ ] Clean up large CSV files from tracked git (use .gitignore)
- [ ] Verify existing pipeline compiles on server

### Phase 1: Live Binance WebSocket Connection (Days 2-4)
**Goal**: Replace UDP replayer with real-time Binance data

**Tasks:**
- [ ] Implement Binance WebSocket client (C++ with libwebsockets or boost::beast)
  - Connect to `wss://stream.binance.com:9443/ws`
  - Subscribe to `<symbol>@trade` streams for 10 symbols
  - Parse JSON trade messages → MarketEvent structs
- [ ] Create a `binance_feed.cpp` module
- [ ] Keep UDP replayer as fallback for offline testing
- [ ] Test with live data, verify event rates match expected (~1000-5000 trades/sec across 10 symbols)

**Output**: Real-time market data ingress, compatible with existing pipeline

### Phase 2: CPU Baseline System (Days 5-8)
**Goal**: Build System 1 — pure CPU processing for benchmark comparison

**Tasks:**
- [ ] Create `cpu_baseline/` directory
- [ ] Port GPU kernels to CPU:
  - Candle aggregation (sequential, per-symbol)
  - Momentum + VWAP strategy
  - Order packing
- [ ] Implement CPU-only pipeline: socket → parse → candles → strategy → orders
- [ ] Add high-resolution timing (chrono::high_resolution_clock)
- [ ] Benchmark: latency per batch, throughput (events/sec), CPU utilization

**Output**: CPU baseline with comparable metrics to GPU pipeline

### Phase 3: GPU Pipeline Enhancement (Days 9-14)
**Goal**: Improve existing GPU pipeline (System 2) for fair benchmarking

**Tasks:**
- [ ] Enhance strategy with more GPU-parallel features:
  - **Multi-timeframe candles**: 1s, 5s, 15s, 60s candles in parallel
  - **Per-symbol feature vector**: SMA(5), SMA(20), volatility, momentum, VWAP spread
  - **Cross-symbol correlation**: Compute pairwise correlation matrix on GPU
  - **Ensemble signals**: Combine multiple indicators
- [ ] Implement proper double-buffering (ping-pong) for overlapping H2D/compute/D2H
- [ ] Add GPU timing via CUDA events (not host timers)
- [ ] Add order book depth simulation (if feasible with trade data)
- [ ] Profile with `nsys` (Nsight Systems) on the server

**Why more GPU work?** The current strategy is too simple (just momentum + VWAP). With only 10 symbols and a simple threshold, CPU can handle this easily. We need to add enough parallel compute to make GPU advantage visible:
- 10 symbols × 4 timeframes × 6 features = 240 parallel computations
- Correlation matrix: 10×10 = 100 pairs
- This makes the GPU advantage clear and measurable

**Output**: Enhanced GPU pipeline with richer strategy, proper profiling

### Phase 4: DOCA GPUNetIO Integration (Days 15-25) — THE CORE
**Goal**: Build System 3 — direct NIC-to-GPU packet processing

**Sub-phases:**

#### 4a: DOCA Environment Setup (Days 15-16)
- [ ] Verify DOCA SDK installed on server (`/opt/mellanox/doca/`)
- [ ] Verify BlueField-3 firmware and drivers
- [ ] Test basic DOCA samples (simple_receive, simple_send)
- [ ] Set up meson build for our project with DOCA dependencies

#### 4b: Adapt gpu_packet_processing (Days 17-20)
- [ ] Take existing `gpu_packet_processing/` as template
- [ ] Modify for our use case:
  - Configure DOCA Flow to steer Binance UDP/TCP traffic to GPU RXQ
  - Create GPU receive kernel that extracts MarketEvent from raw packets
  - Chain into existing 4-kernel pipeline
- [ ] Key DOCA API calls needed:
  ```
  CPU side:
    doca_gpu_create() → GPU device
    doca_eth_rxq_create() → receive queue
    doca_flow_port_start() → flow engine
    doca_flow_pipe_create() → packet steering rules
    doca_gpu_semaphore_create() → GPU↔CPU sync

  GPU side (CUDA kernel):
    doca_gpu_dev_eth_rxq_recv() → receive packets directly on GPU
    doca_gpu_dev_eth_rxq_get_pkt_addr() → get packet buffer
    → Parse Ethernet/IP/TCP headers on GPU
    → Extract payload (Binance JSON or binary)
    → Feed to existing kernels
  ```

#### 4c: GPU-Side Packet Parsing (Days 21-23)
- [ ] Write CUDA kernel to parse raw Ethernet frames on GPU:
  - Strip Ethernet header (14 bytes)
  - Parse IP header (20 bytes)
  - Parse TCP/UDP header
  - Extract payload
  - Parse Binance trade message → MarketEvent
- [ ] This is the novel contribution: packet parsing + trading logic, all on GPU
- [ ] Use GPU semaphores to signal batch completion to CPU

#### 4d: Integration Testing (Days 24-25)
- [ ] Test with real Binance traffic through BlueField-3
- [ ] Verify packet steering rules work
- [ ] Validate parsing produces identical MarketEvents as CPU path
- [ ] Measure end-to-end latency (packet arrival → order generation)

**Output**: Full DOCA GPUNetIO pipeline, NIC→GPU→orders with no CPU in data path

### Phase 5: Benchmarking (Days 26-30)
**Goal**: Produce compelling comparison data for all three systems

**Benchmark 1: Latency Benchmark**
- Metric: Time from packet arrival to order generation
- Method: Embed nanosecond timestamps at each stage
- Compare: CPU baseline vs RDMA GPU vs DOCA GPUNetIO
- Vary: Number of symbols (1, 5, 10), batch size (100, 1K, 10K, 50K)
- Expected result: DOCA GPUNetIO shows lowest latency (no CPU hop)

**Benchmark 2: Throughput Benchmark**
- Metric: Maximum events/second at zero packet loss
- Method: UDP replayer at blast speed, increase rate until drops
- Compare: All three systems
- Vary: Packet rate (10K, 50K, 100K, 500K, 1M events/sec)
- Expected result: DOCA GPUNetIO handles highest throughput

**Additional Metrics:**
- CPU utilization (should be near 0% for DOCA path)
- GPU utilization
- Memory bandwidth usage
- PCIe bandwidth
- Packet drop rate at various loads

**Output**: Benchmark results with charts, tables, and analysis

### Phase 6: Mock Trading & Results (Days 31-35)
**Goal**: Run all three systems on same historical + live data, compare PnL

**Tasks:**
- [ ] Download 30 days of Binance data (10 symbols)
- [ ] Run historical backtest through all three systems
- [ ] Verify identical trading decisions (determinism check)
- [ ] Run live mock trading for 24-48 hours
- [ ] Log: orders, PnL, latency, throughput continuously
- [ ] Generate comparison report

**Output**: Trading performance comparison + system performance comparison

### Phase 7: Documentation & Presentation (Days 36-40)
- [ ] Write final report
- [ ] Create presentation slides
- [ ] Record demo video
- [ ] Clean up code and README

---

## 5. GPU Justification

### Why GPU? The Formal Argument

**Claim**: For real-time multi-symbol market data processing with parallel feature computation and strategy evaluation, GPU processing provides measurably lower latency and higher throughput than CPU processing, especially when combined with DOCA GPUNetIO to eliminate CPU from the data path.

**Evidence we will produce:**

| Aspect | CPU | GPU (RDMA) | GPU (DOCA) |
|--------|-----|------------|------------|
| Data path | Socket→CPU→process | Socket→CPU→GPU→process | NIC→GPU→process |
| CPU involvement | 100% | ~30% (recv + copy) | ~5% (logging only) |
| Parallelism | 1 symbol at a time | 10 symbols × N features | 10 symbols × N features |
| Latency (expected) | ~100μs-1ms | ~50-200μs | ~10-50μs |
| Max throughput | ~100K ev/s | ~500K ev/s | ~1M+ ev/s |
| Scaling with symbols | Linear degradation | Near-constant | Near-constant |

**The key insight**: With 10 symbols, 4 timeframes, 6 features each = 240 independent computations per batch. On CPU, these are sequential. On GPU, they're parallel. As you add more symbols or more complex strategies, CPU degrades linearly while GPU stays flat.

**Why A2 GPUs specifically help the argument:**
- A2 is a *low-power* GPU (40W). Even this modest GPU outperforms CPU.
- The project description says lower-power platforms show CPU bottleneck more clearly.
- If even an A2 beats the CPU, imagine what an A100/H100 would do.

### What the GPU Actually Does (Parallel Workload)

```
Per batch of N events (e.g., 10,000):

  Kernel 1: decode_parse (N threads)
    - Each thread validates 1 event
    - Embarrassingly parallel

  Kernel 2: apply_events (N threads)
    - Each thread updates 1 symbol's candle
    - 10 symbols × 4 timeframes = 40 independent candle updates
    - Atomic updates for OHLCV

  Kernel 3: strategy (10 threads, one per symbol)
    - Each thread computes 6 features (SMA5, SMA20, vol, momentum, VWAP spread, correlation)
    - Each thread evaluates ensemble strategy
    - Independent per-symbol decisions

  Kernel 4: pack_orders (signal_count threads)
    - Compact orders, compute stats
    - Atomic counters
```

---

## 6. Benchmark Design

### Benchmark 1: Latency Profile

**Setup:**
```
Timestamp points:
  T0: Packet arrives at NIC (hardware timestamp from BlueField-3)
  T1: Packet available to processing entity (CPU or GPU)
  T2: Candle aggregation complete
  T3: Strategy evaluation complete
  T4: Order generated and available to host

Latency = T4 - T0 (end-to-end)
```

**Measurement:**
- Use CUDA events for GPU timing
- Use `clock_gettime(CLOCK_MONOTONIC)` for CPU timing
- Use BlueField-3 hardware timestamps for T0
- Run 1000 batches, report: p50, p99, p999, mean, stddev

**Variables:**
| Parameter | Values |
|-----------|--------|
| Symbols | 1, 5, 10 |
| Batch size | 100, 1000, 10000, 50000 |
| System | CPU, RDMA-GPU, DOCA-GPU |

### Benchmark 2: Throughput (Max Sustainable Rate)

**Setup:**
- UDP replayer sends at increasing rates
- Measure: events processed per second with 0% packet loss
- Increase rate until >1% packet loss → that's the ceiling

**Expected Results:**
- CPU: Saturates at ~100K events/sec (single-threaded recv + processing)
- RDMA-GPU: ~500K events/sec (CPU recv bottleneck, GPU processes fast)
- DOCA-GPU: ~1M+ events/sec (no CPU bottleneck, limited by NIC line rate)

### Benchmark 3: Scaling Benchmark
- Fix total event rate at 100K events/sec
- Increase number of symbols: 1, 2, 5, 10, 20, 50
- Measure latency degradation
- Expected: CPU degrades linearly, GPU stays flat

---

## 7. DOCA GPUNetIO Integration Plan

### Architecture for DOCA Path

```
BlueField-3 NIC (ConnectX-7 embedded)
        │
        ├─ DOCA Flow rules steer UDP/TCP to GPU RXQ
        │
        ▼
GPU RXQ (doca_eth_rxq) ──── packets in GPU memory (GPUDirect RDMA / dmabuf)
        │
        ▼
┌──────────────────────────────────────────┐
│ CUDA Kernel: gpu_packet_parse()          │
│  - Parse Ethernet/IP/TCP headers         │
│  - Extract Binance trade payload         │
│  - Convert JSON/binary → MarketEvent     │
│  - Store in GPU event buffer             │
└───────────────┬──────────────────────────┘
                ▼
┌──────────────────────────────────────────┐
│ Existing 4-Kernel Pipeline               │
│  1. decode_parse_kernel                  │
│  2. apply_events_kernel (candles)        │
│  3. strategy_kernel (signals)            │
│  4. pack_orders_kernel (compact)         │
└───────────────┬──────────────────────────┘
                ▼
GPU Semaphore → signals CPU that batch is ready
                ▼
CPU reads orders from GPU memory (GDRCopy)
                ▼
Order Manager (log, PnL, mock execution)
```

### Key DOCA Components We Need

1. **doca_gpu_create()** — Initialize A2 GPU device handler
2. **doca_eth_rxq_create()** — Create Ethernet receive queue on GPU
3. **doca_flow_pipe_create()** — Steer specific traffic (Binance port) to GPU RXQ
4. **doca_gpu_semaphore_create()** — GPU-to-CPU signaling for batch completion
5. **doca_gpu_dev_eth_rxq_recv()** — GPU kernel receives packets directly
6. **doca_gpu_dev_eth_rxq_get_pkt_addr()** — Get packet address in GPU memory

### Execution Flow

```
CPU Thread 1 (Control):
  while (running) {
    doca_pe_progress(pe);  // Process events, errors

    // Check GPU semaphore for completed batches
    doca_gpu_semaphore_get_status(sem, idx, &status);
    if (status == DOCA_GPU_SEMAPHORE_STATUS_READY) {
      // Read orders from GPU memory
      // Update PnL, log trades
      // Set status to DONE
    }
  }

GPU Persistent Kernel:
  while (running) {
    // Receive packets directly from NIC
    doca_gpu_dev_eth_rxq_recv(rxq, max_pkts, timeout, &first_idx, &num);

    for each packet:
      addr = doca_gpu_dev_eth_rxq_get_pkt_addr(rxq, idx);
      parse_packet(addr);  // Eth→IP→TCP→Binance→MarketEvent

    // Run trading pipeline on accumulated events
    apply_events(...);
    strategy(...);
    pack_orders(...);

    // Signal CPU via semaphore
    doca_gpu_dev_semaphore_set_status(sem, idx, READY);
  }
```

### A2 GPU Compatibility Notes

- A2 is Ampere (sm_86) — DOCA GPUNetIO supports sm_80+
- A2 has 16GB GDDR6 — plenty for packet buffers + state
- A2 has 1280 CUDA cores — modest but sufficient for our workload
- Key: PCIe Gen4 x16 connection to BlueField-3 must be verified

---

## 8. What I Need From You

### Immediate (Before Phase 1)

1. **SSH access details**: Can you SSH to the server right now? Is VPN needed?
2. **Server OS**: What Linux distribution? (Ubuntu 22.04? Rocky Linux?)
3. **DOCA SDK version**: Run `dpkg -l | grep doca` or check `/opt/mellanox/doca/`
4. **CUDA version**: Run `nvcc --version` on the server
5. **BlueField-3 status**: Run `lspci | grep -i mellanox` — is it in DPU mode or NIC mode?
6. **GPU verification**: Run `nvidia-smi` — confirm 2x A2 GPUs visible
7. **PCIe topology**: Run `nvidia-smi topo -m` — check GPU↔NIC connection
8. **Binance API**: Do you have a Binance account? (Free tier is fine, just need WebSocket access)
9. **Network**: Can the server reach `stream.binance.com:9443` from the university network?

### During Development

10. **DOCA samples**: Can you run `/opt/mellanox/doca/samples/doca_gpunetio/simple_receive` on the server?
11. **Build tools**: Is meson/ninja installed? (`meson --version`, `ninja --version`)
12. **Libraries**: Is libwebsockets or boost installed? (for Binance WebSocket)
13. **Permissions**: Do you have sudo on the server? (DOCA needs root for hugepages and NIC configuration)

---

## 9. Ideas for Improvement

### Making the Project Stronger

1. **Order Book Reconstruction on GPU**
   Instead of just processing trades, reconstruct the order book (top 10 levels) on GPU. This is more compute-intensive and justifies GPU better. Binance provides `@depth` streams.

2. **Multi-GPU Pipeline**
   You have 2x A2 GPUs. Use GPU 0 for market data processing and GPU 1 for strategy/risk computation. Show multi-GPU scaling.

3. **GPU-to-GPU Communication via DOCA**
   Use DOCA GPUNetIO for GPU-to-GPU data transfer (GPU 0 receives packets, transfers processed data to GPU 1 for strategy). This demonstrates the RDMA/GPUDirect path between GPUs.

4. **Adaptive Batch Sizing**
   Dynamically adjust batch size based on market activity. High volatility → smaller batches (lower latency). Quiet market → larger batches (higher throughput).

5. **Feature Store on GPU**
   Keep a rolling window of features in GPU memory (last N candles, correlation matrices). This persistent GPU state eliminates repeated H2D transfers.

6. **Hardware Timestamp Comparison**
   Use BlueField-3's PTP hardware clock for packet timestamps. Compare against software timestamps. Show the accuracy improvement.

7. **Power Efficiency Metric**
   Since A2 is 40W: compute events/second/watt for each system. GPU might win on power efficiency too, which is a compelling metric for data centers.

### DOCA GPUNetIO Specific Improvements

8. **Use WARP-level receive** instead of THREAD-level for `doca_gpu_dev_eth_rxq_recv()`. 32 threads collaborate on packet reception — higher throughput.

9. **GPU semaphore ring buffer** for multi-batch pipelining. Don't wait for CPU to process before starting next batch.

10. **Timed send** (`doca_gpu_dev_eth_txq_wait_send()`) for precise order submission timing if you extend to an actual exchange API.

---

## 10. Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| A2 GPU too slow for DOCA GPUNetIO | High | A2 is sm_86 (Ampere), which is supported. Verify with simple DOCA sample first |
| BlueField-3 not in correct mode | High | Verify NIC mode vs DPU mode. GPUNetIO works in both but setup differs |
| PCIe topology blocks GPUDirect | High | Run `nvidia-smi topo -m`. If GPU and NIC are on different PCIe switches, performance degrades |
| Binance WebSocket blocked by firewall | Medium | Use UDP replayer as fallback. Download data and replay offline |
| DOCA SDK version incompatible | Medium | Check SDK version matches BlueField firmware. May need firmware update |
| JSON parsing on GPU too slow | Medium | Pre-convert to binary format on DPU ARM cores. Or use Binance binary protocol |
| Cannot achieve meaningful latency difference | Medium | Add more compute-intensive features (correlation matrix, order book) |
| Server access unreliable | Low | Develop locally, test on server. Keep UDP replayer for local testing |

---

## Timeline Summary

```
Week 1 (Days 1-7):   Setup + Binance feed + CPU baseline
Week 2 (Days 8-14):  GPU pipeline enhancement
Week 3 (Days 15-21): DOCA GPUNetIO integration (part 1)
Week 4 (Days 22-28): DOCA integration (part 2) + initial benchmarks
Week 5 (Days 29-35): Full benchmarks + mock trading
Week 6 (Days 36-40): Documentation + presentation
```

---

## File Structure (Target)

```
DOCAGPUNetIO-application_LIX2_FYP_HKUST/
├── PROJECT_PLAN.md          ← THIS FILE
├── README.md                ← Updated project overview
├── common/
│   ├── market_event.h       ← Shared data structures
│   ├── binance_feed.h/cpp   ← WebSocket client
│   └── benchmark.h          ← Timing utilities
├── cpu_baseline/
│   ├── cpu_pipeline.cpp     ← System 1: CPU-only
│   └── Makefile
├── gpu_rdma/
│   ├── (existing mini_trader pipeline)
│   └── Makefile
├── gpu_doca/
│   ├── doca_trading.c       ← System 3: DOCA GPUNetIO
│   ├── gpu_kernels/
│   │   ├── packet_parse.cu  ← GPU packet parsing
│   │   └── trading.cu       ← Enhanced trading kernels
│   ├── config/
│   │   └── flow_setup.c     ← DOCA Flow rules
│   └── meson.build
├── benchmark/
│   ├── run_benchmarks.sh    ← Automated benchmark suite
│   ├── plot_results.py      ← Generate charts
│   └── results/             ← Benchmark data
├── mock_trading/
│   ├── order_manager.h/cpp  ← Unified order management
│   └── pnl_tracker.h/cpp    ← PnL calculation
└── docs/
    ├── PIPELINE_SPEC.md
    ├── TESTING_GUIDE.md
    └── BENCHMARK_RESULTS.md
```

---

## Honest Assessment

**Strengths of this project:**
- Real hardware (BlueField-3 + A2 GPUs) with real NVIDIA collaboration
- Clear three-tier comparison with measurable metrics
- Practical domain (financial data processing)
- Uses cutting-edge DOCA GPUNetIO (very few projects use this)
- Working prototype already exists

**Weaknesses to address:**
- Simple strategy (momentum + VWAP) — need to add more parallel compute
- A2 is a modest GPU — but this actually helps the narrative (even low-power GPU beats CPU)
- Crypto market data may not be fast enough to stress-test — use replay at blast speed

**Bottom line:** This is a solid FYP project. The combination of DOCA GPUNetIO + GPU packet processing + real trading data is unique and technically impressive. The key is producing clear benchmark numbers that show the progression: CPU → RDMA-GPU → DOCA-GPU.
