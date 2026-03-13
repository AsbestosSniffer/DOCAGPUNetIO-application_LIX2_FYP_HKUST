/*
 * System 2: GPU RDMA Pipeline (Compute-Heavy)
 * ─────────────────────────────────────────────
 * CPU receives data → pinned memory → GPU kernels with heavy feature engineering.
 *
 * Pipeline (4 kernels):
 *   1. aggregate_candles_kernel — per-symbol sequential candle aggregation (no races)
 *   2. compute_features_kernel — HEAVY: technical indicators + Monte Carlo VaR
 *   3. evaluate_strategy_kernel — multi-factor signal generation
 *   4. pack_orders_kernel — compact orders + compute stats
 *
 * The GPU advantage comes from kernel 2: each block runs 256 Monte Carlo
 * simulation paths in parallel. CPU must do this sequentially.
 *
 * Usage:
 *   ./gpu_rdma_pipeline [total_events] [batch_size]
 *   ./gpu_rdma_pipeline --file [path.bin] [batch_size]
 *   ./gpu_rdma_pipeline --udp [port] [batch_size]
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

// Initialize per-symbol states on GPU (avoids cudaMemset zero-init bug)
__global__ void init_states_kernel(PerSymbolState* states, int n_symbols) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n_symbols) states[i].init();
}

// Kernel 1: Aggregate candles — one block per symbol, thread 0 only.
// Processes events sequentially per symbol to avoid race conditions.
__global__ void aggregate_candles_kernel(
    const MarketEvent* events, int n_events,
    PerSymbolState* states, int n_symbols)
{
    int sid = blockIdx.x; // one block per symbol
    if (sid >= n_symbols || threadIdx.x != 0) return;

    PerSymbolState& s = states[sid];

    for (int i = 0; i < n_events; i++) {
        const MarketEvent& ev = events[i];
        if (ev.symbol_id != (uint32_t)sid) continue;

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
        s.vwap_sum_pq += (double)ev.price * (double)ev.qty;
        s.vwap_sum_q  += (double)ev.qty;
    }
}

// Kernel 2: Compute features — one block (MC_PATHS threads) per symbol.
// Thread 0 computes technical indicators, ALL threads run Monte Carlo.
// This is the compute-heavy kernel that justifies GPU acceleration.
__global__ void compute_features_kernel(
    const PerSymbolState* states,
    FeatureVector* features,
    int n_symbols)
{
    int sid = blockIdx.x;
    if (sid >= n_symbols) return;
    int tid = threadIdx.x;

    const PerSymbolState& s = states[sid];
    int n = s.closed_count;

    // Load candle data into shared memory for fast access
    __shared__ float closes[MAX_CANDLE_HISTORY];
    __shared__ float highs[MAX_CANDLE_HISTORY];
    __shared__ float lows[MAX_CANDLE_HISTORY];
    __shared__ float volumes[MAX_CANDLE_HISTORY];

    // Cooperative load: each thread loads multiple candles
    for (int i = tid; i < n; i += blockDim.x) {
        closes[i]  = s.closed_candles[i].close;
        highs[i]   = s.closed_candles[i].high;
        lows[i]    = s.closed_candles[i].low;
        volumes[i] = s.closed_candles[i].volume;
    }
    __syncthreads();

    __shared__ FeatureVector shared_feat;

    // Thread 0: compute all technical indicators
    if (tid == 0) {
        // Zero out
        memset(&shared_feat, 0, sizeof(FeatureVector));
        shared_feat.signal_side = -1;

        if (n < 2) {
            // Not enough history
        } else {
            // === EMA (Exponential Moving Averages) ===
            float ema5 = closes[0], ema10 = closes[0];
            float ema20 = closes[0], ema50 = closes[0];
            float k5 = 2.0f / 6.0f, k10 = 2.0f / 11.0f;
            float k20 = 2.0f / 21.0f, k50 = 2.0f / 51.0f;
            for (int i = 1; i < n; i++) {
                ema5  = closes[i] * k5  + ema5  * (1 - k5);
                ema10 = closes[i] * k10 + ema10 * (1 - k10);
                ema20 = closes[i] * k20 + ema20 * (1 - k20);
                ema50 = closes[i] * k50 + ema50 * (1 - k50);
            }
            shared_feat.ema_5 = ema5;
            shared_feat.ema_10 = ema10;
            shared_feat.ema_20 = ema20;
            shared_feat.ema_50 = ema50;

            // === RSI (Relative Strength Index, 14-period) ===
            int rsi_period = min(14, n - 1);
            float gains = 0, losses = 0;
            for (int i = n - rsi_period; i < n; i++) {
                float diff = closes[i] - closes[i - 1];
                if (diff > 0) gains += diff;
                else losses -= diff;
            }
            float avg_gain = gains / rsi_period;
            float avg_loss = losses / rsi_period;
            float rs = (avg_loss > 1e-8f) ? avg_gain / avg_loss : 100.0f;
            shared_feat.rsi = 100.0f - 100.0f / (1.0f + rs);

            // === Bollinger Bands (20-period, 2 std dev) ===
            int bb_period = min(20, n);
            float bb_sum = 0, bb_sum2 = 0;
            for (int i = n - bb_period; i < n; i++) {
                bb_sum += closes[i];
                bb_sum2 += closes[i] * closes[i];
            }
            float bb_mean = bb_sum / bb_period;
            float bb_var = bb_sum2 / bb_period - bb_mean * bb_mean;
            float bb_std = sqrtf(fmaxf(bb_var, 0.0f));
            shared_feat.bb_middle = bb_mean;
            shared_feat.bb_upper = bb_mean + 2.0f * bb_std;
            shared_feat.bb_lower = bb_mean - 2.0f * bb_std;

            // === MACD (12, 26, signal 9) ===
            float ema12 = closes[0], ema26 = closes[0];
            float k12 = 2.0f / 13.0f, k26 = 2.0f / 27.0f;
            float macd_signal = 0;
            float k9 = 2.0f / 10.0f;
            for (int i = 1; i < n; i++) {
                ema12 = closes[i] * k12 + ema12 * (1 - k12);
                ema26 = closes[i] * k26 + ema26 * (1 - k26);
                float macd_line = ema12 - ema26;
                macd_signal = macd_line * k9 + macd_signal * (1 - k9);
            }
            shared_feat.macd_line = ema12 - ema26;
            shared_feat.macd_signal = macd_signal;
            shared_feat.macd_hist = shared_feat.macd_line - macd_signal;

            // === ATR (Average True Range, 14-period) ===
            int atr_period = min(14, n);
            float atr_sum = 0;
            for (int i = n - atr_period; i < n; i++) {
                float tr = highs[i] - lows[i];
                if (i > 0) {
                    tr = fmaxf(tr, fabsf(highs[i] - closes[i - 1]));
                    tr = fmaxf(tr, fabsf(lows[i] - closes[i - 1]));
                }
                atr_sum += tr;
            }
            shared_feat.atr = atr_sum / atr_period;

            // === Volatility (annualized from log returns) ===
            float lr_sum = 0, lr_sum2 = 0;
            int lr_n = 0;
            for (int i = 1; i < n; i++) {
                if (closes[i - 1] > 0) {
                    float lr = logf(closes[i] / closes[i - 1]);
                    lr_sum += lr;
                    lr_sum2 += lr * lr;
                    lr_n++;
                }
            }
            if (lr_n > 1) {
                float lr_mean = lr_sum / lr_n;
                float lr_var = lr_sum2 / lr_n - lr_mean * lr_mean;
                // Annualize: sqrt(var * periods_per_year)
                // 1-minute candles: 525600 per year
                shared_feat.volatility = sqrtf(fmaxf(lr_var, 0.0f)) * sqrtf(525600.0f);
            }

            // === Volume ratio (current vs average) ===
            float vol_sum = 0;
            for (int i = 0; i < n; i++) vol_sum += volumes[i];
            float avg_vol = vol_sum / n;
            shared_feat.volume_ratio = (avg_vol > 0) ? s.candle_volume / avg_vol : 1.0f;

            // === Momentum (rate of change over 10 periods) ===
            int mom_lookback = min(10, n);
            float old_close = closes[n - mom_lookback];
            if (old_close > 0) {
                shared_feat.momentum = (closes[n - 1] - old_close) / old_close;
            }

            // === VWAP deviation ===
            float current_vwap = s.vwap();
            if (current_vwap > 0) {
                shared_feat.vwap_deviation = (s.last_price - current_vwap) / current_vwap;
            }
        }
    }
    __syncthreads();

    // === Monte Carlo VaR Simulation (ALL threads participate) ===
    // Each thread runs one simulation path — this is where GPU parallelism shines.
    __shared__ float mc_returns[MC_PATHS];

    if (n >= 2 && tid < MC_PATHS) {
        float vol = shared_feat.volatility;
        if (vol < 1e-6f) vol = 0.01f; // minimum volatility
        float price = s.last_price;
        if (price <= 0) price = 1.0f;

        float dt = 1.0f / 525600.0f;  // 1-minute step
        float sqrt_dt = sqrtf(dt);
        float drift = -0.5f * vol * vol * dt;

        // XorShift32 PRNG (seeded per thread + symbol for reproducibility)
        uint32_t rng = (uint32_t)(tid + 1) * 2654435761u +
                       (uint32_t)sid * 1103515245u + 12345u;

        float sim_price = price;

        for (int step = 0; step < MC_STEPS; step++) {
            // XorShift32
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            float u1 = (float)(rng & 0x7FFFFFFF) / (float)0x7FFFFFFF + 1e-10f;
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            float u2 = (float)(rng & 0x7FFFFFFF) / (float)0x7FFFFFFF;

            // Box-Muller transform → standard normal
            float z = sqrtf(-2.0f * logf(u1)) * cosf(6.28318530718f * u2);

            // Geometric Brownian Motion step
            sim_price *= expf(drift + vol * sqrt_dt * z);
        }

        mc_returns[tid] = (sim_price - price) / price;
    } else if (tid < MC_PATHS) {
        mc_returns[tid] = 0.0f;
    }
    __syncthreads();

    // Thread 0: compute VaR and Expected Shortfall from MC results
    if (tid == 0 && n >= 2) {
        float sum = 0, sum2 = 0;
        for (int i = 0; i < MC_PATHS; i++) {
            sum += mc_returns[i];
            sum2 += mc_returns[i] * mc_returns[i];
        }
        float mc_mean = sum / MC_PATHS;
        float mc_var = sum2 / MC_PATHS - mc_mean * mc_mean;
        float mc_std = sqrtf(fmaxf(mc_var, 0.0f));

        // Parametric VaR at 95% confidence
        shared_feat.var_95 = (mc_mean - 1.645f * mc_std) * s.last_price;

        // Expected Shortfall: average of returns below VaR threshold
        float var_threshold = mc_mean - 1.645f * mc_std;
        float es_sum = 0;
        int es_count = 0;
        for (int i = 0; i < MC_PATHS; i++) {
            if (mc_returns[i] <= var_threshold) {
                es_sum += mc_returns[i];
                es_count++;
            }
        }
        shared_feat.expected_shortfall = (es_count > 0)
            ? (es_sum / es_count) * s.last_price
            : shared_feat.var_95;
    }
    __syncthreads();

    // Write result
    if (tid == 0) {
        features[sid] = shared_feat;
    }
}

// Kernel 3: Multi-factor strategy evaluation — one thread per symbol
__global__ void evaluate_strategy_kernel(
    const PerSymbolState* states,
    const FeatureVector* features,
    int n_symbols,
    Order* orders_out,
    int* order_count)
{
    int sid = blockIdx.x * blockDim.x + threadIdx.x;
    if (sid >= n_symbols) return;

    const PerSymbolState& s = states[sid];
    const FeatureVector& f = features[sid];

    if (s.closed_count < 3 || s.candle_trade_count == 0) return;

    // Multi-factor signal computation
    float signal = 0.0f;

    // Factor 1: EMA crossover (short above long = bullish)
    if (f.ema_20 > 0) {
        signal += 0.25f * (f.ema_5 - f.ema_20) / f.ema_20;
    }

    // Factor 2: RSI (oversold < 30 = buy, overbought > 70 = sell)
    signal += 0.20f * (50.0f - f.rsi) / 50.0f;

    // Factor 3: Bollinger Band position
    float bb_width = f.bb_upper - f.bb_lower;
    if (bb_width > 0) {
        float bb_pos = (s.last_price - f.bb_middle) / (bb_width * 0.5f);
        signal -= 0.15f * bb_pos; // mean reversion
    }

    // Factor 4: MACD histogram direction
    signal += 0.15f * (f.macd_hist > 0 ? 1.0f : -1.0f) *
              fminf(fabsf(f.macd_hist) / fmaxf(f.atr, 0.01f), 1.0f);

    // Factor 5: Volume confirmation
    signal += 0.10f * fminf(f.volume_ratio - 1.0f, 2.0f) *
              (signal > 0 ? 1.0f : -1.0f);

    // Factor 6: VWAP deviation
    signal += 0.10f * f.vwap_deviation;

    // Factor 7: Risk-adjusted (penalize high VaR)
    float risk_penalty = fmaxf(-f.var_95 / fmaxf(s.last_price, 1.0f), 0.0f);
    signal *= fmaxf(1.0f - risk_penalty, 0.1f);

    // Generate order if signal is strong enough
    float threshold = 0.001f;
    if (fabsf(signal) > threshold) {
        Order o;
        o.symbol_id = sid;
        o.ts_ns = 0;
        o.price = s.last_price;
        o.qty = 0.01f;
        o.order_type = 0;
        o.side = (signal > 0) ? 0 : 1; // positive = buy

        int idx = atomicAdd(order_count, 1);
        if (idx < n_symbols * 2) {
            orders_out[idx] = o;
        }
    }
}

// Kernel 4: Pack orders + compute stats
__global__ void pack_orders_kernel(
    const Order* in, int n, OrderStats* stats)
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
        if (in[i].side == 0) atomicAdd(&stats->buy_count, 1);
        else                 atomicAdd(&stats->sell_count, 1);
    }
}

/* ─── GPU Pipeline Host Class ────────────────────────────────────────── */

struct GPURDMAPipeline {
    int max_batch;
    int n_symbols;

    // Pinned host buffers
    MarketEvent*   h_events;
    Order*         h_orders;
    OrderStats*    h_stats;
    int*           h_order_count;

    // Device buffers
    MarketEvent*    d_events;
    PerSymbolState* d_states;
    FeatureVector*  d_features;
    Order*          d_orders;
    OrderStats*     d_stats;
    int*            d_order_count;

    // CUDA stream + events for timing
    cudaStream_t stream;
    cudaEvent_t  ev_start, ev_h2d, ev_kern, ev_d2h, ev_end;

    // Metrics
    LatencyStats    latency;
    ThroughputMeter throughput;
    PnLTracker      pnl;

    GPURDMAPipeline(int max_batch_, int n_sym = N_SYMBOLS)
        : max_batch(max_batch_), n_symbols(n_sym)
    {
        // Pinned host
        CUDA_CHECK(cudaHostAlloc(&h_events, max_batch * sizeof(MarketEvent), cudaHostAllocDefault));
        CUDA_CHECK(cudaHostAlloc(&h_orders, n_symbols * 2 * sizeof(Order), cudaHostAllocDefault));
        CUDA_CHECK(cudaHostAlloc(&h_stats, sizeof(OrderStats), cudaHostAllocDefault));
        CUDA_CHECK(cudaHostAlloc(&h_order_count, sizeof(int), cudaHostAllocDefault));

        // Device
        CUDA_CHECK(cudaMalloc(&d_events,      max_batch * sizeof(MarketEvent)));
        CUDA_CHECK(cudaMalloc(&d_states,      n_symbols * sizeof(PerSymbolState)));
        CUDA_CHECK(cudaMalloc(&d_features,    n_symbols * sizeof(FeatureVector)));
        CUDA_CHECK(cudaMalloc(&d_orders,      n_symbols * 2 * sizeof(Order)));
        CUDA_CHECK(cudaMalloc(&d_stats,       sizeof(OrderStats)));
        CUDA_CHECK(cudaMalloc(&d_order_count, sizeof(int)));

        CUDA_CHECK(cudaStreamCreate(&stream));
        CUDA_CHECK(cudaEventCreate(&ev_start));
        CUDA_CHECK(cudaEventCreate(&ev_h2d));
        CUDA_CHECK(cudaEventCreate(&ev_kern));
        CUDA_CHECK(cudaEventCreate(&ev_d2h));
        CUDA_CHECK(cudaEventCreate(&ev_end));

        // Properly initialize states (fixes candle_low = 1e9f)
        init_states_kernel<<<1, n_symbols>>>(d_states, n_symbols);
        CUDA_CHECK(cudaDeviceSynchronize());
    }

    ~GPURDMAPipeline() {
        cudaFreeHost(h_events); cudaFreeHost(h_orders);
        cudaFreeHost(h_stats); cudaFreeHost(h_order_count);
        cudaFree(d_events); cudaFree(d_states); cudaFree(d_features);
        cudaFree(d_orders); cudaFree(d_stats); cudaFree(d_order_count);
        cudaEventDestroy(ev_start); cudaEventDestroy(ev_h2d);
        cudaEventDestroy(ev_kern);  cudaEventDestroy(ev_d2h);
        cudaEventDestroy(ev_end);
        cudaStreamDestroy(stream);
    }

    void process_batch(const MarketEvent* events, int n) {
        if (n == 0 || n > max_batch) return;

        // Record H2D start
        CUDA_CHECK(cudaEventRecord(ev_start, stream));

        // H2D transfer
        CUDA_CHECK(cudaMemcpyAsync(d_events, events, n * sizeof(MarketEvent),
                                   cudaMemcpyHostToDevice, stream));
        CUDA_CHECK(cudaEventRecord(ev_h2d, stream));

        // Kernel 1: Aggregate candles — one block per symbol
        aggregate_candles_kernel<<<n_symbols, 1, 0, stream>>>(
            d_events, n, d_states, n_symbols);

        // Kernel 2: Compute features — one block of MC_PATHS threads per symbol
        compute_features_kernel<<<n_symbols, MC_PATHS, 0, stream>>>(
            d_states, d_features, n_symbols);

        // Kernel 3: Evaluate strategy
        CUDA_CHECK(cudaMemsetAsync(d_order_count, 0, sizeof(int), stream));
        evaluate_strategy_kernel<<<1, n_symbols, 0, stream>>>(
            d_states, d_features, n_symbols, d_orders, d_order_count);

        CUDA_CHECK(cudaEventRecord(ev_kern, stream));

        // D2H: copy order count first, then orders and stats
        CUDA_CHECK(cudaMemcpyAsync(h_order_count, d_order_count, sizeof(int),
                                   cudaMemcpyDeviceToHost, stream));
        CUDA_CHECK(cudaStreamSynchronize(stream));

        int n_orders = *h_order_count;
        if (n_orders > n_symbols * 2) n_orders = n_symbols * 2;

        // Kernel 4: Pack orders + stats
        if (n_orders > 0) {
            OrderStats zeros = {0, 0, 0, 0.0f};
            CUDA_CHECK(cudaMemcpyAsync(d_stats, &zeros, sizeof(OrderStats),
                                       cudaMemcpyHostToDevice, stream));
            pack_orders_kernel<<<1, 32, 0, stream>>>(d_orders, n_orders, d_stats);

            CUDA_CHECK(cudaMemcpyAsync(h_stats, d_stats, sizeof(OrderStats),
                                       cudaMemcpyDeviceToHost, stream));
            CUDA_CHECK(cudaMemcpyAsync(h_orders, d_orders, n_orders * sizeof(Order),
                                       cudaMemcpyDeviceToHost, stream));
        } else {
            memset(h_stats, 0, sizeof(OrderStats));
        }

        CUDA_CHECK(cudaEventRecord(ev_d2h, stream));
        CUDA_CHECK(cudaStreamSynchronize(stream));
        CUDA_CHECK(cudaEventRecord(ev_end, stream));
        CUDA_CHECK(cudaEventSynchronize(ev_end));

        // Timing
        float total_ms;
        cudaEventElapsedTime(&total_ms, ev_start, ev_end);
        latency.record_us((double)total_ms * 1000.0);
        throughput.add_batch(n);

        // PnL
        pnl.process_orders(h_orders, n_orders);
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

        printf("Mode: File replay from %s (batch=%d, GPU 1)\n", path, batch_size);

        GPURDMAPipeline pipeline(batch_size);
        FileReplayFeed feed;
        if (!feed.load(path)) return 1;
        printf("Loaded %zu events from %s\n", feed.events.size(), path);

        while (true) {
            std::vector<MarketEvent> batch(batch_size);
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
                printf("[GPU LIVE] Batch %d: %d events | PnL=$%.4f | %.0f ev/s\n",
                       batch_num, n, pipeline.pnl.cumulative_pnl,
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
