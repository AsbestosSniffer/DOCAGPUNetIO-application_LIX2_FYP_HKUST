/*
 * System 1: CPU Baseline Pipeline
 * ─────────────────────────────────
 * Pure CPU processing for benchmark comparison.
 * Implements the same 4-stage pipeline as the GPU version:
 *   1. Decode/Parse (validation)
 *   2. Apply Events (candle aggregation)
 *   3. Strategy (momentum + VWAP signals)
 *   4. Pack Orders (compact + stats)
 *
 * All processing is single-threaded to model the CPU bottleneck scenario
 * described in the project requirements.
 *
 * Usage:
 *   ./cpu_baseline [total_events] [batch_size] [n_symbols]
 *   ./cpu_baseline --udp [port] [batch_size]
 *   ./cpu_baseline --file [path.bin] [batch_size]
 *   ./cpu_baseline --live [batch_size]
 *
 * The --live mode connects to Binance WebSocket and processes
 * real-time trades. Requires libwebsockets and nlohmann-json.
 */

#include "../common/market_event.h"
#include "../common/benchmark.h"
#include "../common/pnl_tracker.h"
#include "../common/binance_feed.h"

#ifdef HAS_WEBSOCKETS
#include "../common/binance_ws_feed.h"
#endif

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>

/* ─── CPU Pipeline ───────────────────────────────────────────────────── */

struct CPUPipeline {
    PerSymbolState states[N_SYMBOLS];
    Order          orders[N_SYMBOLS * 2];
    OrderStats     stats;
    int            order_count;

    LatencyStats   latency;
    ThroughputMeter throughput;
    PnLTracker     pnl;

    CPUPipeline() {
        for (int i = 0; i < N_SYMBOLS; ++i) states[i].init();
    }

    /* Stage 1: Decode/Parse (validation pass-through) */
    void decode_parse(const MarketEvent* in, MarketEvent* out, int n) {
        for (int i = 0; i < n; ++i) {
            out[i] = in[i]; // validation pass-through
        }
    }

    /* Stage 2: Apply events → candle aggregation + feature update */
    void apply_events(const MarketEvent* events, int n) {
        for (int i = 0; i < n; ++i) {
            const MarketEvent& ev = events[i];
            if (ev.symbol_id >= N_SYMBOLS) continue;

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

            s.candle_high = std::max(s.candle_high, ev.price);
            s.candle_low  = std::min(s.candle_low,  ev.price);
            s.candle_close = ev.price;
            s.candle_volume += ev.qty;
            s.candle_trade_count++;

            s.last_price = ev.price;
            s.total_trades++;
            s.vwap = (s.vwap * (s.total_trades - 1) + ev.price) / s.total_trades;
        }
    }

    /* Stage 3: Strategy evaluation (momentum + VWAP) */
    void strategy(int n_symbols) {
        order_count = 0;
        for (int i = 0; i < n_symbols; ++i) {
            const PerSymbolState& s = states[i];
            if (s.candle_trade_count == 0) continue;

            if (s.closed_count > 0) {
                const Candle& prev = s.closed_candles[s.closed_count - 1];
                float price_change = (s.candle_close - prev.close) / prev.close;

                Order o;
                o.symbol_id = i;
                o.ts_ns = 0;
                o.price = s.last_price;
                o.qty = 0.01f;
                o.order_type = 0;

                if (price_change > 0.001f && s.last_price > s.vwap) {
                    o.side = 0; // BUY
                    orders[order_count++] = o;
                } else if (price_change < -0.001f && s.last_price < s.vwap) {
                    o.side = 1; // SELL
                    orders[order_count++] = o;
                }
            }
        }
    }

    /* Stage 4: Pack orders + compute stats */
    void pack_orders() {
        stats.total_signals = order_count;
        stats.buy_count = 0;
        stats.sell_count = 0;
        stats.total_qty = 0;
        for (int i = 0; i < order_count; ++i) {
            if (orders[i].side == 0) stats.buy_count++;
            else stats.sell_count++;
            stats.total_qty += orders[i].qty;
        }
    }

    /* Full pipeline: one batch */
    void process_batch(const MarketEvent* events, int n) {
        if (n == 0) return;

        uint64_t t0 = now_ns();

        // Allocate parsed buffer on stack for small batches
        std::vector<MarketEvent> parsed(n);
        decode_parse(events, parsed.data(), n);
        apply_events(parsed.data(), n);
        strategy(N_SYMBOLS);
        pack_orders();

        uint64_t t1 = now_ns();
        latency.record(t0, t1);
        throughput.add_batch(n);

        // PnL tracking
        pnl.process_orders(orders, order_count);
    }

    void print_results() {
        printf("\n=== CPU Baseline Results ===\n");
        latency.print("CPU Latency");
        throughput.print("CPU Throughput");
        pnl.print_summary();
    }
};

/* ─── Main ───────────────────────────────────────────────────────────── */

int main(int argc, char** argv) {
    printf("╔══════════════════════════════════════╗\n");
    printf("║   System 1: CPU Baseline Pipeline    ║\n");
    printf("╚══════════════════════════════════════╝\n\n");

    // Default: synthetic mode
    int total_events = 1000000;
    int batch_size = 1000;
    int n_symbols = N_SYMBOLS;

    if (argc > 1 && strcmp(argv[1], "--udp") == 0) {
        // UDP receive mode
        int port = (argc > 2) ? atoi(argv[2]) : 9999;
        batch_size = (argc > 3) ? atoi(argv[3]) : 10000;

        printf("Mode: UDP receiver on port %d\n", port);

        CPUPipeline pipeline;
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
                printf("[CPU] Batch %d: %d events, %d signals (%dB/%dS) | PnL=$%.4f\n",
                       batch_num, n, pipeline.stats.total_signals,
                       pipeline.stats.buy_count, pipeline.stats.sell_count,
                       pipeline.pnl.cumulative_pnl);
            }
        }
        feed.stop();
        pipeline.print_results();

    } else if (argc > 1 && strcmp(argv[1], "--file") == 0) {
        // File replay mode
        const char* path = (argc > 2) ? argv[2] : "data.bin";
        batch_size = (argc > 3) ? atoi(argv[3]) : 1000;

        printf("Mode: File replay from %s (batch_size=%d)\n", path, batch_size);

        CPUPipeline pipeline;
        FileReplayFeed feed;
        if (!feed.load(path)) return 1;

        std::vector<MarketEvent> batch(batch_size);
        int batch_num = 0;
        while (true) {
            int n = feed.next_batch(batch.data(), batch_size);
            if (n == 0) break;
            pipeline.process_batch(batch.data(), n);
            batch_num++;
        }
        pipeline.print_results();

#ifdef HAS_WEBSOCKETS
    } else if (argc > 1 && strcmp(argv[1], "--live") == 0) {
        // Live Binance WebSocket mode
        batch_size = (argc > 2) ? atoi(argv[2]) : 1000;

        printf("Mode: LIVE Binance WebSocket (batch_size=%d)\n", batch_size);
        printf("Press Ctrl+C to stop.\n\n");

        CPUPipeline pipeline;
        BinanceWSFeed feed;

        // Handle Ctrl+C
        static BinanceWSFeed* g_feed = &feed;
        signal(SIGINT, [](int) { g_feed->stop(); });

        int batch_num = 0;
        feed.on_batch = [&](const MarketEvent* events, int n) {
            pipeline.process_batch(events, n);
            batch_num++;
            if (batch_num % 10 == 0) {
                printf("[CPU LIVE] Batch %d: %d events, %d signals (%dB/%dS) | PnL=$%.4f | %.0f ev/s\n",
                       batch_num, n, pipeline.stats.total_signals,
                       pipeline.stats.buy_count, pipeline.stats.sell_count,
                       pipeline.pnl.cumulative_pnl,
                       pipeline.throughput.events_per_sec());
            }
        };

        feed.start(batch_size);
        pipeline.print_results();
#endif

    } else {
        // Synthetic benchmark mode
        total_events = (argc > 1) ? atoi(argv[1]) : 1000000;
        batch_size   = (argc > 2) ? atoi(argv[2]) : 1000;

        printf("Mode: Synthetic benchmark (%d events, batch_size=%d)\n",
               total_events, batch_size);

        CPUPipeline pipeline;
        SyntheticFeed gen(total_events);

        // Generate all events
        std::vector<MarketEvent> all_events(total_events);
        gen.generate(all_events.data(), total_events);

        // Process in batches
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
