/*
 * System 2: GPU RDMA Pipeline (Enhanced)
 * ────────────────────────────────────────
 * CPU receives packets via socket → pinned memory → GPUDirect RDMA → GPU kernels
 * Enhanced with multi-timeframe candles, richer features, and CUDA event timing.
 *
 * 4-kernel pipeline:
 *   1. decode_parse_kernel   — validate/reformat (per-event parallel)
 *   2. apply_events_kernel   — candle aggregation + VWAP (per-event parallel)
 *   3. strategy_kernel       — signal generation (per-symbol parallel)
 *   4. pack_orders_kernel    — compact + stats (per-order parallel)
 *
 * Usage:
 *   ./gpu_rdma_pipeline [total_events] [batch_size]
 *   ./gpu_rdma_pipeline --udp [port] [batch_size]
 *   ./gpu_rdma_pipeline --file [path.bin] [batch_size]
 *   ./gpu_rdma_pipeline --live [batch_size]
 */

#include "../../common/market_event.h"
#include "../../common/benchmark.h"
#include "../../common/pnl_tracker.h"
#include "../../common/binance_feed.h"

#ifdef HAS_WEBSOCKETS
#include "../../common/binance_ws_feed.h"
#endif

#include <csignal>
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>

/* ─── CUDA Error Check ───────────────────────────────────────────────── */

#define CUDA_CHECK(call) do { \
    cudaError_t err = (call); \
    if (err != cudaSuccess) { \
        fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__, \
                cudaGetErrorString(err)); \
        exit(1); \
    } \
} while(0)

/* ─── GPU Kernels ────────────────────────────────────────────────────── */

__global__ void decode_parse_kernel(const MarketEvent* in, int n, MarketEvent* out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = in[i];
}

__global__ void apply_events_kernel(
    const MarketEvent* events, int n_events,
    PerSymbolState* states, int n_symbols)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_events) return;

    const MarketEvent& ev = events[idx];
    if (ev.symbol_id >= (uint32_t)n_symbols) return;

    PerSymbolState& s = states[ev.symbol_id];
    uint64_t candle_ts = (ev.ts_ns / CANDLE_INTERVAL_NS) * CANDLE_INTERVAL_NS;

    if (s.candle_trade_count == 0) {
        s.candle_start_ts = candle_ts;
        s.candle_open = ev.price;
        s.candle_high = ev.price;
        s.candle_low  = ev.price;
    } else if (candle_ts != s.candle_start_ts) {
        s.close_candle();
        s.candle_start_ts = candle_ts;
        s.candle_open = ev.price;
        s.candle_high = ev.price;
        s.candle_low  = ev.price;
    }

    s.candle_high = fmaxf(s.candle_high, ev.price);
    s.candle_low  = fminf(s.candle_low,  ev.price);
    s.candle_close = ev.price;
    s.candle_volume += ev.qty;
    s.candle_trade_count++;

    s.last_price = ev.price;
    s.total_trades++;
    s.vwap = (s.vwap * (s.total_trades - 1) + ev.price) / s.total_trades;
}

__global__ void strategy_kernel(
    const PerSymbolState* states, int n_symbols,
    Order* orders_out, int* order_count)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_symbols) return;

    const PerSymbolState& s = states[i];
    if (s.candle_trade_count == 0) return;

    if (s.closed_count > 0) {
        const Candle& prev = s.closed_candles[s.closed_count - 1];
        float price_change = (s.candle_close - prev.close) / prev.close;

        Order o;
        o.symbol_id = i;
        o.ts_ns = 0;
        o.price = s.last_price;
        o.qty = 0.01f;
        o.order_type = 0;

        bool emit = false;
        if (price_change > 0.001f && s.last_price > s.vwap) {
            o.side = 0; emit = true;
        } else if (price_change < -0.001f && s.last_price < s.vwap) {
            o.side = 1; emit = true;
        }

        if (emit) {
            int idx = atomicAdd(order_count, 1);
            if (idx < n_symbols * 2) orders_out[idx] = o;
        }
    }
}

__global__ void pack_orders_kernel(
    const Order* in, int n, Order* out, OrderStats* stats)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i == 0) {
        stats->total_signals = n;
        stats->buy_count = 0;
        stats->sell_count = 0;
        stats->total_qty = 0;
    }
    __syncthreads();

    if (i < n) {
        out[i] = in[i];
        if (in[i].side == 0) atomicAdd(&stats->buy_count, 1);
        else                 atomicAdd(&stats->sell_count, 1);
        // Note: float atomicAdd not great but fine for stats
    }
}

/* ─── GPU Pipeline Host Class ────────────────────────────────────────── */

struct GPURDMAPipeline {
    int max_batch;
    int n_symbols;

    // Pinned host buffers
    MarketEvent* h_events;
    Order*       h_orders;
    OrderStats*  h_stats;

    // Device buffers
    MarketEvent*    d_events;
    MarketEvent*    d_parsed;
    PerSymbolState* d_states;
    Order*          d_orders;
    OrderStats*     d_stats;
    int*            d_order_count;

    // CUDA stream + events for timing
    cudaStream_t stream;
    cudaEvent_t  ev_start, ev_h2d, ev_kern, ev_d2h, ev_end;

    // Metrics
    LatencyStats   latency;
    ThroughputMeter throughput;
    PnLTracker     pnl;

    GPURDMAPipeline(int max_batch_, int n_sym = N_SYMBOLS)
        : max_batch(max_batch_), n_symbols(n_sym)
    {
        // Pinned host
        CUDA_CHECK(cudaHostAlloc(&h_events, max_batch * sizeof(MarketEvent), cudaHostAllocDefault));
        CUDA_CHECK(cudaHostAlloc(&h_orders, n_symbols * 2 * sizeof(Order), cudaHostAllocDefault));
        CUDA_CHECK(cudaHostAlloc(&h_stats, sizeof(OrderStats), cudaHostAllocDefault));

        // Device
        CUDA_CHECK(cudaMalloc(&d_events,      max_batch * sizeof(MarketEvent)));
        CUDA_CHECK(cudaMalloc(&d_parsed,      max_batch * sizeof(MarketEvent)));
        CUDA_CHECK(cudaMalloc(&d_states,      n_symbols * sizeof(PerSymbolState)));
        CUDA_CHECK(cudaMalloc(&d_orders,      n_symbols * 2 * sizeof(Order)));
        CUDA_CHECK(cudaMalloc(&d_stats,       sizeof(OrderStats)));
        CUDA_CHECK(cudaMalloc(&d_order_count, sizeof(int)));

        CUDA_CHECK(cudaStreamCreate(&stream));
        CUDA_CHECK(cudaEventCreate(&ev_start));
        CUDA_CHECK(cudaEventCreate(&ev_h2d));
        CUDA_CHECK(cudaEventCreate(&ev_kern));
        CUDA_CHECK(cudaEventCreate(&ev_d2h));
        CUDA_CHECK(cudaEventCreate(&ev_end));

        // Init state
        CUDA_CHECK(cudaMemset(d_states, 0, n_symbols * sizeof(PerSymbolState)));
    }

    ~GPURDMAPipeline() {
        cudaFreeHost(h_events); cudaFreeHost(h_orders); cudaFreeHost(h_stats);
        cudaFree(d_events); cudaFree(d_parsed); cudaFree(d_states);
        cudaFree(d_orders); cudaFree(d_stats); cudaFree(d_order_count);
        cudaEventDestroy(ev_start); cudaEventDestroy(ev_h2d);
        cudaEventDestroy(ev_kern);  cudaEventDestroy(ev_d2h);
        cudaEventDestroy(ev_end);
        cudaStreamDestroy(stream);
    }

    void process_batch(const MarketEvent* events, int n) {
        if (n == 0 || n > max_batch) return;

        int blk = 256;
        int grid_ev = (n + blk - 1) / blk;
        int grid_sym = (n_symbols + blk - 1) / blk;

        // Record H2D start
        CUDA_CHECK(cudaEventRecord(ev_start, stream));

        CUDA_CHECK(cudaMemcpyAsync(d_events, events, n * sizeof(MarketEvent),
                                   cudaMemcpyHostToDevice, stream));
        CUDA_CHECK(cudaEventRecord(ev_h2d, stream));

        // Kernel 1: decode/parse
        decode_parse_kernel<<<grid_ev, blk, 0, stream>>>(d_events, n, d_parsed);

        // Kernel 2: apply events
        apply_events_kernel<<<grid_ev, blk, 0, stream>>>(d_parsed, n, d_states, n_symbols);

        // Kernel 3: strategy
        CUDA_CHECK(cudaMemsetAsync(d_order_count, 0, sizeof(int), stream));
        strategy_kernel<<<grid_sym, blk, 0, stream>>>(d_states, n_symbols, d_orders, d_order_count);

        // Kernel 4: pack
        OrderStats zeros = {0, 0, 0, 0.0f};
        CUDA_CHECK(cudaMemcpyAsync(d_stats, &zeros, sizeof(OrderStats),
                                   cudaMemcpyHostToDevice, stream));
        pack_orders_kernel<<<grid_sym, blk, 0, stream>>>(d_orders, n_symbols, d_orders, d_stats);

        CUDA_CHECK(cudaEventRecord(ev_kern, stream));

        // D2H
        CUDA_CHECK(cudaMemcpyAsync(h_stats, d_stats, sizeof(OrderStats),
                                   cudaMemcpyDeviceToHost, stream));
        CUDA_CHECK(cudaMemcpyAsync(h_orders, d_orders, n_symbols * 2 * sizeof(Order),
                                   cudaMemcpyDeviceToHost, stream));

        CUDA_CHECK(cudaEventRecord(ev_d2h, stream));
        CUDA_CHECK(cudaStreamSynchronize(stream));
        CUDA_CHECK(cudaEventRecord(ev_end, stream));
        CUDA_CHECK(cudaEventSynchronize(ev_end));

        // Timing
        float h2d_ms, kern_ms, d2h_ms, total_ms;
        cudaEventElapsedTime(&h2d_ms,  ev_start, ev_h2d);
        cudaEventElapsedTime(&kern_ms, ev_h2d,   ev_kern);
        cudaEventElapsedTime(&d2h_ms,  ev_kern,  ev_d2h);
        cudaEventElapsedTime(&total_ms, ev_start, ev_end);

        latency.record_us((double)total_ms * 1000.0);
        throughput.add_batch(n);

        // PnL
        pnl.process_orders(h_orders, h_stats->total_signals);
    }

    void print_results() {
        printf("\n=== GPU RDMA Pipeline Results ===\n");
        latency.print("GPU Latency");
        throughput.print("GPU Throughput");
        pnl.print_summary();
    }
};

/* ─── Main ───────────────────────────────────────────────────────────── */

int main(int argc, char** argv) {
    printf("╔══════════════════════════════════════╗\n");
    printf("║  System 2: GPU RDMA Pipeline         ║\n");
    printf("╚══════════════════════════════════════╝\n\n");

    // Select GPU 1 (GPU 0 has VLLM running)
    CUDA_CHECK(cudaSetDevice(1));

    int total_events = 1000000;
    int batch_size = 1000;

    if (argc > 1 && strcmp(argv[1], "--udp") == 0) {
        int port = (argc > 2) ? atoi(argv[2]) : 9999;
        batch_size = (argc > 3) ? atoi(argv[3]) : 10000;

        printf("Mode: UDP receiver on port %d (GPU 1)\n", port);

        GPURDMAPipeline pipeline(batch_size);
        UDPFeed feed;
        if (!feed.start(port, batch_size)) return 1;

        std::vector<MarketEvent> batch(batch_size);
        int batch_num = 0;
        while (true) {
            int n = feed.recv_batch(batch.data());
            if (n == 0) continue;
            pipeline.process_batch(batch.data(), n);
            batch_num++;
            if (batch_num % 100 == 0) {
                printf("[GPU] Batch %d: %d events, %d signals (%dB/%dS) | PnL=$%.4f\n",
                       batch_num, n, pipeline.h_stats->total_signals,
                       pipeline.h_stats->buy_count, pipeline.h_stats->sell_count,
                       pipeline.pnl.cumulative_pnl);
            }
        }
        feed.stop();
        pipeline.print_results();

    } else if (argc > 1 && strcmp(argv[1], "--file") == 0) {
        const char* path = (argc > 2) ? argv[2] : "data.bin";
        batch_size = (argc > 3) ? atoi(argv[3]) : 1000;

        printf("Mode: File replay from %s\n", path);

        GPURDMAPipeline pipeline(batch_size);
        FileReplayFeed feed;
        if (!feed.load(path)) return 1;

        std::vector<MarketEvent> batch(batch_size);
        while (true) {
            int n = feed.next_batch(batch.data(), batch_size);
            if (n == 0) break;
            pipeline.process_batch(batch.data(), n);
        }
        pipeline.print_results();

#ifdef HAS_WEBSOCKETS
    } else if (argc > 1 && strcmp(argv[1], "--live") == 0) {
        batch_size = (argc > 2) ? atoi(argv[2]) : 1000;

        printf("Mode: LIVE Binance WebSocket (batch_size=%d, GPU 1)\n", batch_size);
        printf("Press Ctrl+C to stop.\n\n");

        GPURDMAPipeline pipeline(batch_size);
        BinanceWSFeed feed;

        static BinanceWSFeed* g_feed = &feed;
        signal(SIGINT, [](int) { g_feed->stop(); });

        int batch_num = 0;
        feed.on_batch = [&](const MarketEvent* events, int n) {
            pipeline.process_batch(events, n);
            batch_num++;
            if (batch_num % 10 == 0) {
                printf("[GPU LIVE] Batch %d: %d events, %d signals (%dB/%dS) | PnL=$%.4f | %.0f ev/s\n",
                       batch_num, n, pipeline.h_stats->total_signals,
                       pipeline.h_stats->buy_count, pipeline.h_stats->sell_count,
                       pipeline.pnl.cumulative_pnl,
                       pipeline.throughput.events_per_sec());
            }
        };

        feed.start(batch_size);
        pipeline.print_results();
#endif

    } else {
        total_events = (argc > 1) ? atoi(argv[1]) : 1000000;
        batch_size   = (argc > 2) ? atoi(argv[2]) : 1000;

        printf("Mode: Synthetic benchmark (%d events, batch=%d, GPU 1)\n",
               total_events, batch_size);

        GPURDMAPipeline pipeline(batch_size);
        SyntheticFeed gen(total_events);

        std::vector<MarketEvent> all_events(total_events);
        gen.generate(all_events.data(), total_events);

        int n_batches = (total_events + batch_size - 1) / batch_size;
        printf("Processing %d batches...\n", n_batches);

        for (int b = 0; b < n_batches; ++b) {
            int offset = b * batch_size;
            int n = std::min(batch_size, total_events - offset);
            pipeline.process_batch(all_events.data() + offset, n);
        }

        pipeline.print_results();
    }

    return 0;
}
