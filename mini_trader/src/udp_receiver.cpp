#include <iostream>
#include <vector>
#include <thread>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <atomic>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <cuda_runtime.h>
#include "market_event.h"

// ============================================================================
// GPU Pipeline (incorporated from gpu_staging.cu)
// ============================================================================

static const uint64_t CANDLE_INTERVAL_NS = 60000000000ULL;

__global__ void decode_parse_kernel(const MarketEvent* in, int n, MarketEvent* out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        out[i] = in[i];
    }
}

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

    uint64_t candle_ts = (ev.ts_ns / CANDLE_INTERVAL_NS) * CANDLE_INTERVAL_NS;

    if (state.candle_trade_count == 0) {
        state.candle_start_ts = candle_ts;
        state.candle_open = ev.price;
        state.candle_high = ev.price;
        state.candle_low = ev.price;
    }
    else if (candle_ts != state.candle_start_ts) {
        state.close_candle();
        state.candle_start_ts = candle_ts;
        state.candle_open = ev.price;
        state.candle_high = ev.price;
        state.candle_low = ev.price;
    }

    state.candle_high = fmaxf(state.candle_high, ev.price);
    state.candle_low = fminf(state.candle_low, ev.price);
    state.candle_close = ev.price;
    state.candle_volume += ev.qty;
    state.candle_trade_count++;

    state.last_price = ev.price;
    state.total_trades++;
    state.vwap = (state.vwap * (state.total_trades - 1) + ev.price) / state.total_trades;
}

__global__ void strategy_kernel(
    const PerSymbolState* states,
    int n_symbols,
    Order* orders_out,
    int* order_count
) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_symbols) return;

    const PerSymbolState& state = states[i];
    if (state.candle_trade_count == 0) return;

    Order order;
    order.symbol_id = i;
    order.ts_ns = 0;
    order.price = state.last_price;
    order.qty = 0.01f;

    bool should_order = false;

    if (state.closed_count > 0) {
        const Candle& prev = state.closed_candles[state.closed_count - 1];
        float price_change = (state.candle_close - prev.close) / prev.close;

        if (price_change > 0.001f && state.last_price > state.vwap) {
            order.side = 0;
            should_order = true;
        }
        else if (price_change < -0.001f && state.last_price < state.vwap) {
            order.side = 1;
            should_order = true;
        }
    }

    if (should_order) {
        int idx = atomicAdd(order_count, 1);
        if (idx < n_symbols * 2) {
            orders_out[idx] = order;
        }
    }
}

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

struct PipelineConfig {
    int max_events_per_batch;
    int n_symbols;
    uint64_t candle_interval_ns;
};

struct GPUPipeline {
    PipelineConfig config;

    MarketEvent* h_events;
    PerSymbolState* h_states;
    Order* h_orders;
    OrderStats* h_stats;

    MarketEvent* d_events;
    MarketEvent* d_parsed;
    PerSymbolState* d_states;
    Order* d_orders;
    OrderStats* d_stats;
    int* d_order_count;

    cudaStream_t stream;

    std::atomic<uint64_t> total_events_processed{0};
    std::atomic<uint64_t> total_batches{0};

    GPUPipeline(const PipelineConfig& cfg) : config(cfg) {
        cudaHostAlloc(&h_events, cfg.max_events_per_batch * sizeof(MarketEvent),
                      cudaHostAllocDefault);
        cudaHostAlloc(&h_states, cfg.n_symbols * sizeof(PerSymbolState),
                      cudaHostAllocDefault);
        cudaHostAlloc(&h_orders, cfg.n_symbols * 2 * sizeof(Order),
                      cudaHostAllocDefault);
        cudaHostAlloc(&h_stats, sizeof(OrderStats), cudaHostAllocDefault);

        cudaMalloc(&d_events, cfg.max_events_per_batch * sizeof(MarketEvent));
        cudaMalloc(&d_parsed, cfg.max_events_per_batch * sizeof(MarketEvent));
        cudaMalloc(&d_states, cfg.n_symbols * sizeof(PerSymbolState));
        cudaMalloc(&d_orders, cfg.n_symbols * 2 * sizeof(Order));
        cudaMalloc(&d_stats, sizeof(OrderStats));
        cudaMalloc(&d_order_count, sizeof(int));

        cudaStreamCreate(&stream);
        cudaMemset(d_states, 0, cfg.n_symbols * sizeof(PerSymbolState));

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

    void process_batch(const MarketEvent* events, int n_events) {
        if (n_events == 0) return;
        if (n_events > config.max_events_per_batch) {
            std::cerr << "Batch too large: " << n_events << "\n";
            return;
        }

        auto start = std::chrono::high_resolution_clock::now();

        cudaMemcpyAsync(d_events, events, n_events * sizeof(MarketEvent),
                       cudaMemcpyHostToDevice, stream);

        int block_size = 256;
        int grid_size = (n_events + block_size - 1) / block_size;
        decode_parse_kernel<<<grid_size, block_size, 0, stream>>>(
            d_events, n_events, d_parsed
        );

        apply_events_kernel<<<grid_size, block_size, 0, stream>>>(
            d_parsed, n_events, d_states, config.n_symbols
        );

        int strategy_grid = (config.n_symbols + block_size - 1) / block_size;
        cudaMemsetAsync(d_order_count, 0, sizeof(int), stream);
        strategy_kernel<<<strategy_grid, block_size, 0, stream>>>(
            d_states, config.n_symbols, d_orders, d_order_count
        );

        OrderStats zeros = {0, 0, 0, 0.0f};
        cudaMemcpyAsync(d_stats, &zeros, sizeof(OrderStats),
                       cudaMemcpyHostToDevice, stream);
        pack_orders_kernel<<<strategy_grid, block_size, 0, stream>>>(
            d_orders, config.n_symbols, d_orders, d_stats
        );

        cudaMemcpyAsync(h_stats, d_stats, sizeof(OrderStats),
                       cudaMemcpyDeviceToHost, stream);

        cudaStreamSynchronize(stream);

        auto end = std::chrono::high_resolution_clock::now();
        auto ms = std::chrono::duration<double, std::milli>(end - start).count();

        total_events_processed += n_events;
        total_batches++;

        std::cout << "[GPU] Batch " << total_batches << ": " << n_events << " events, "
                  << h_stats->total_signals << " signals ("
                  << h_stats->buy_count << "B/" << h_stats->sell_count << "S), "
                  << ms << "ms\n";
    }

    void print_stats() {
        std::cout << "\n=== Final Statistics ===\n";
        std::cout << "Total events: " << total_events_processed << "\n";
        std::cout << "Total batches: " << total_batches << "\n";
        if (total_batches > 0) {
            std::cout << "Avg batch size: " << (total_events_processed / total_batches) << "\n";
        }
    }
};

// ============================================================================
// UDP Receiver with GPU Integration
// ============================================================================

struct PacketHeader {
    uint32_t magic;
    uint16_t version;
    uint32_t packet_seq;
    uint32_t event_count;
};

int main(int argc, char** argv) {
    int port = (argc > 1) ? std::stoi(argv[1]) : 9999;
    int batch_limit = (argc > 2) ? std::stoi(argv[2]) : 10000;
    int max_batches = (argc > 3) ? std::stoi(argv[3]) : -1;  // -1 = run forever

    std::cout << "UDP Receiver + GPU Pipeline\n";
    std::cout << "Listening on port " << port << " (batch_limit=" << batch_limit << ")\n";

    // Initialize GPU pipeline
    PipelineConfig cfg;
    cfg.max_events_per_batch = batch_limit;
    cfg.n_symbols = 10;
    cfg.candle_interval_ns = CANDLE_INTERVAL_NS;

    std::cout << "Initializing GPU pipeline...\n";
    GPUPipeline pipeline(cfg);

    // Setup UDP socket
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sock);
        return 1;
    }

    std::cout << "Ready to receive UDP packets...\n\n";

    std::vector<char> buf(sizeof(PacketHeader) + batch_limit * sizeof(MarketEvent));
    int total_events = 0;
    int total_packets = 0;
    int batch_count = 0;

    while (true) {
        if (max_batches > 0 && batch_count >= max_batches) {
            std::cout << "\nMax batches reached (" << max_batches << "), exiting...\n";
            break;
        }

        ssize_t r = recv(sock, buf.data(), buf.size(), 0);
        if (r < (ssize_t)sizeof(PacketHeader)) {
            std::cerr << "Short packet: " << r << " bytes\n";
            continue;
        }

        PacketHeader hdr;
        std::memcpy(&hdr, buf.data(), sizeof(PacketHeader));

        if (hdr.magic != 0xDEADBEEF) {
            std::cerr << "Bad magic: 0x" << std::hex << hdr.magic << std::dec << "\n";
            continue;
        }

        int n = hdr.event_count;
        if (n <= 0 || r < (ssize_t)(sizeof(PacketHeader) + n * sizeof(MarketEvent))) {
            std::cerr << "Bad event count: " << n << "\n";
            continue;
        }

        // Extract events and process
        MarketEvent* events = (MarketEvent*)(buf.data() + sizeof(PacketHeader));
        pipeline.process_batch(events, n);

        total_events += n;
        total_packets++;
        batch_count++;
    }

    close(sock);
    pipeline.print_stats();

    return 0;
}
