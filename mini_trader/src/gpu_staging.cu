#include <iostream>
#include <vector>
#include <chrono>
#include <cuda_runtime.h>
#include <cstring>
#include "market_event.h"

// ============================================================================
// GPU Kernels
// ============================================================================

// Candle interval: 60 seconds (in nanoseconds)
static const uint64_t CANDLE_INTERVAL_NS = 60000000000ULL;

/**
 * decode_parse_kernel: Validate and reformat events (currently a pass-through)
 * Could be used for decompression or format conversion later.
 */
__global__ void decode_parse_kernel(const MarketEvent* in, int n, MarketEvent* out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        out[i] = in[i];  // Pass-through validation
    }
}

/**
 * apply_events_kernel: Update per-symbol state and aggregate candles
 * For each event:
 *  - Check if candle interval changed
 *  - Update current candle (OHLCV)
 *  - Update features (VWAP, last price)
 */
__global__ void apply_events_kernel(
    const MarketEvent* events,
    int n_events,
    PerSymbolState* states,
    int n_symbols
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_events) return;

    const MarketEvent& ev = events[idx];
    if (ev.symbol_id >= (uint32_t)n_symbols) return;

    PerSymbolState& state = states[ev.symbol_id];

    // Determine if we need to close the current candle
    uint64_t candle_ts = (ev.ts_ns / CANDLE_INTERVAL_NS) * CANDLE_INTERVAL_NS;

    // Initialize candle if first event for this symbol
    if (state.candle_trade_count == 0) {
        state.candle_start_ts = candle_ts;
        state.candle_open = ev.price;
        state.candle_high = ev.price;
        state.candle_low = ev.price;
    }
    // Close candle if interval changed
    else if (candle_ts != state.candle_start_ts) {
        state.close_candle();
        state.candle_start_ts = candle_ts;
        state.candle_open = ev.price;
        state.candle_high = ev.price;
        state.candle_low = ev.price;
    }

    // Update current candle
    state.candle_high = fmaxf(state.candle_high, ev.price);
    state.candle_low = fminf(state.candle_low, ev.price);
    state.candle_close = ev.price;
    state.candle_volume += ev.qty;
    state.candle_trade_count++;

    // Update features
    state.last_price = ev.price;
    state.total_trades++;

    // Simple VWAP (could be more sophisticated)
    state.vwap = (state.vwap * (state.total_trades - 1) + ev.price) / state.total_trades;
}

/**
 * strategy_kernel: Generate trading signals/orders based on state
 * Simple strategy:
 *  - BUY if: price > VWAP and candle volume increasing
 *  - SELL if: price < VWAP and momentum negative
 */
__global__ void strategy_kernel(
    const PerSymbolState* states,
    int n_symbols,
    Order* orders_out,
    int* order_count
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_symbols) return;

    const PerSymbolState& state = states[i];
    if (state.candle_trade_count == 0) return;  // No data for this symbol

    Order order;
    order.symbol_id = i;
    order.ts_ns = 0;
    order.price = state.last_price;
    order.qty = 0.01f;  // Fixed qty for now

    bool should_order = false;

    // Simple threshold-based strategy
    if (state.closed_count > 0) {
        const Candle& prev = state.closed_candles[state.closed_count - 1];
        float price_change = (state.candle_close - prev.close) / prev.close;

        // BUY signal: positive momentum and price above VWAP
        if (price_change > 0.001f && state.last_price > state.vwap) {
            order.side = 0;  // BUY
            should_order = true;
        }
        // SELL signal: negative momentum or price below VWAP
        else if (price_change < -0.001f && state.last_price < state.vwap) {
            order.side = 1;  // SELL
            should_order = true;
        }
    }

    if (should_order) {
        int idx = atomicAdd(order_count, 1);
        if (idx < n_symbols * 2) {  // Safety limit
            orders_out[idx] = order;
        }
    }
}

/**
 * pack_orders_kernel: Compact valid orders and compute statistics
 * Input: all generated orders
 * Output: packed valid orders and stats
 */
struct OrderStats {
    uint32_t total_signals;
    uint32_t buy_count;
    uint32_t sell_count;
    float total_qty;
};

__global__ void pack_orders_kernel(
    const Order* orders_in,
    int n_orders,
    Order* orders_out,
    OrderStats* stats
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i == 0) {
        stats->total_signals = n_orders;
        stats->buy_count = 0;
        stats->sell_count = 0;
        stats->total_qty = 0;
    }
    __syncthreads();

    if (i < n_orders) {
        const Order& o = orders_in[i];
        orders_out[i] = o;

        if (o.side == 0) {
            atomicAdd(&stats->buy_count, 1);
        } else {
            atomicAdd(&stats->sell_count, 1);
        }
        atomicAdd((unsigned int*)&stats->total_qty, (unsigned int)o.qty);
    }
}

// ============================================================================
// Host Staging and Pipeline
// ============================================================================

struct PipelineConfig {
    int max_events_per_batch;
    int n_symbols;
    uint64_t candle_interval_ns;
};

struct GPUPipeline {
    PipelineConfig config;

    // Host pinned buffers
    MarketEvent* h_events;
    PerSymbolState* h_states;
    Order* h_orders;
    OrderStats* h_stats;

    // Device buffers
    MarketEvent* d_events;
    MarketEvent* d_parsed;
    PerSymbolState* d_states;
    Order* d_orders;
    OrderStats* d_stats;
    int* d_order_count;

    // CUDA stream for async operations
    cudaStream_t stream;

    GPUPipeline(const PipelineConfig& cfg) : config(cfg) {
        // Allocate pinned host memory
        cudaHostAlloc(&h_events, cfg.max_events_per_batch * sizeof(MarketEvent),
                      cudaHostAllocDefault);
        cudaHostAlloc(&h_states, cfg.n_symbols * sizeof(PerSymbolState),
                      cudaHostAllocDefault);
        cudaHostAlloc(&h_orders, cfg.n_symbols * 2 * sizeof(Order),
                      cudaHostAllocDefault);
        cudaHostAlloc(&h_stats, sizeof(OrderStats), cudaHostAllocDefault);

        // Allocate device memory
        cudaMalloc(&d_events, cfg.max_events_per_batch * sizeof(MarketEvent));
        cudaMalloc(&d_parsed, cfg.max_events_per_batch * sizeof(MarketEvent));
        cudaMalloc(&d_states, cfg.n_symbols * sizeof(PerSymbolState));
        cudaMalloc(&d_orders, cfg.n_symbols * 2 * sizeof(Order));
        cudaMalloc(&d_stats, sizeof(OrderStats));
        cudaMalloc(&d_order_count, sizeof(int));

        // Create stream
        cudaStreamCreate(&stream);

        // Initialize states on device
        cudaMemset(d_states, 0, cfg.n_symbols * sizeof(PerSymbolState));

        // Initialize host states
        for (int i = 0; i < cfg.n_symbols; ++i) {
            h_states[i].init();
        }
    }

    ~GPUPipeline() {
        cudaFreeHost(h_events);
        cudaFreeHost(h_states);
        cudaFreeHost(h_orders);
        cudaFreeHost(h_stats);

        cudaFree(d_events);
        cudaFree(d_parsed);
        cudaFree(d_states);
        cudaFree(d_orders);
        cudaFree(d_stats);
        cudaFree(d_order_count);

        cudaStreamDestroy(stream);
    }

    /**
     * Process a batch of market events through the entire pipeline
     */
    void process_batch(const MarketEvent* events, int n_events) {
        if (n_events == 0) return;
        if (n_events > config.max_events_per_batch) {
            std::cerr << "Batch too large: " << n_events << " > "
                      << config.max_events_per_batch << "\n";
            return;
        }

        auto batch_start = std::chrono::high_resolution_clock::now();

        // H2D: Copy events
        cudaMemcpyAsync(d_events, events, n_events * sizeof(MarketEvent),
                       cudaMemcpyHostToDevice, stream);

        // Kernel 1: Decode/Parse (pass-through for now)
        int block_size = 256;
        int grid_size = (n_events + block_size - 1) / block_size;
        decode_parse_kernel<<<grid_size, block_size, 0, stream>>>(
            d_events, n_events, d_parsed
        );

        // Kernel 2: Apply Events (candle aggregation)
        apply_events_kernel<<<grid_size, block_size, 0, stream>>>(
            d_parsed, n_events, d_states, config.n_symbols
        );

        // Kernel 3: Strategy (generate signals)
        int strategy_grid = (config.n_symbols + block_size - 1) / block_size;
        cudaMemsetAsync(d_order_count, 0, sizeof(int), stream);
        strategy_kernel<<<strategy_grid, block_size, 0, stream>>>(
            d_states, config.n_symbols, d_orders, d_order_count
        );

        // Kernel 4: Pack Orders (already in d_orders, stats computation)
        OrderStats zeros = {0, 0, 0, 0.0f};
        cudaMemcpyAsync(d_stats, &zeros, sizeof(OrderStats),
                       cudaMemcpyHostToDevice, stream);
        pack_orders_kernel<<<strategy_grid, block_size, 0, stream>>>(
            d_orders, config.n_symbols, d_orders, d_stats
        );

        // D2H: Copy results
        cudaMemcpyAsync(h_stats, d_stats, sizeof(OrderStats),
                       cudaMemcpyDeviceToHost, stream);
        cudaMemcpyAsync(h_orders, d_orders, config.n_symbols * 2 * sizeof(Order),
                       cudaMemcpyDeviceToHost, stream);

        // Wait for async operations
        cudaStreamSynchronize(stream);

        auto batch_end = std::chrono::high_resolution_clock::now();
        auto batch_time_ms = std::chrono::duration<double, std::milli>(batch_end - batch_start).count();

        // Log results
        std::cout << "[GPU Pipeline] Batch: "
                  << n_events << " events, "
                  << h_stats->total_signals << " signals ("
                  << h_stats->buy_count << " buy, "
                  << h_stats->sell_count << " sell), "
                  << batch_time_ms << " ms\n";
    }
};

// ============================================================================
// Main: Sanity test
// ============================================================================

int main(int argc, char** argv) {
    int n_events = (argc > 1) ? std::stoi(argv[1]) : 10000;
    int max_batch = (argc > 2) ? std::stoi(argv[2]) : 50000;

    std::cout << "GPU Pipeline Staging Test\n";
    std::cout << "Events: " << n_events << ", Max batch: " << max_batch << "\n";

    PipelineConfig cfg;
    cfg.max_events_per_batch = max_batch;
    cfg.n_symbols = 10;
    cfg.candle_interval_ns = CANDLE_INTERVAL_NS;

    GPUPipeline pipeline(cfg);

    // Generate fake batch
    std::vector<MarketEvent> events(n_events);
    for (int i = 0; i < n_events; ++i) {
        events[i].ts_ns = 1640995200000000000ULL + (uint64_t)i * 100000ULL;  // 0.1ms apart
        events[i].symbol_id = i % 10;
        events[i].price = 30000.0f + (i % 1000) * 0.1f;
        events[i].qty = 0.1f + (i % 10) * 0.01f;
        events[i].side = i % 2;
        events[i].trade_id = i;
    }

    // Process in batches
    int batch_size = 1000;
    int batches = (n_events + batch_size - 1) / batch_size;
    std::cout << "Processing " << batches << " batches of " << batch_size << " events\n\n";

    for (int b = 0; b < batches; ++b) {
        int offset = b * batch_size;
        int n = std::min(batch_size, n_events - offset);
        pipeline.process_batch(events.data() + offset, n);
    }

    std::cout << "\nTest completed successfully!\n";
    return 0;
}
