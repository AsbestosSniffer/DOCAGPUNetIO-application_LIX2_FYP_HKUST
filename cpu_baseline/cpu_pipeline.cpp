/*
 * System 1: CPU Baseline Pipeline (Compute-Heavy)
 * ──────────────────────────────────────────────────
 * Pure CPU processing for benchmark comparison.
 * Implements the same computation as the GPU version:
 *   1. Candle aggregation + VWAP
 *   2. Feature engineering (EMA, RSI, BB, MACD, ATR, volatility)
 *   3. Monte Carlo VaR simulation (MC_PATHS * MC_STEPS sequential!)
 *   4. Multi-factor strategy evaluation
 *
 * All processing is single-threaded. The Monte Carlo simulation
 * runs 256 paths × 100 steps sequentially — this is where the
 * CPU bottleneck becomes apparent vs GPU parallel execution.
 *
 * Usage:
 *   ./cpu_baseline [total_events] [batch_size]
 *   ./cpu_baseline --file [path.bin] [batch_size]
 *   ./cpu_baseline --udp [port] [batch_size]
 *   ./cpu_baseline --live [batch_size]
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

/* ─── XorShift32 PRNG (matches GPU version exactly) ────────────────── */

static inline uint32_t xorshift32(uint32_t& state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

/* ─── CPU Pipeline ───────────────────────────────────────────────────── */

struct CPUPipeline {
    PerSymbolState states[N_SYMBOLS];
    FeatureVector  features[N_SYMBOLS];
    Order          orders[N_SYMBOLS * 2];
    OrderStats     stats;
    int            order_count;

    LatencyStats    latency;
    ThroughputMeter throughput;
    PnLTracker      pnl;

    CPUPipeline() {
        for (int i = 0; i < N_SYMBOLS; ++i) states[i].init();
        memset(features, 0, sizeof(features));
    }

    /* Stage 1: Candle aggregation + VWAP (sequential per symbol, correct) */
    void aggregate_candles(const MarketEvent* events, int n) {
        for (int i = 0; i < n; ++i) {
            const MarketEvent& ev = events[i];
            if (ev.symbol_id >= (uint32_t)N_SYMBOLS) continue;

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
            s.vwap_sum_pq += (double)ev.price * (double)ev.qty;
            s.vwap_sum_q  += (double)ev.qty;
        }
    }

    /* Stage 2: Feature engineering — same computation as GPU */
    void compute_features() {
        for (int sid = 0; sid < N_SYMBOLS; sid++) {
            const PerSymbolState& s = states[sid];
            FeatureVector& f = features[sid];
            memset(&f, 0, sizeof(FeatureVector));
            f.signal_side = -1;

            int n = s.closed_count;
            if (n < 2) continue;

            // Load candle data
            float closes[MAX_CANDLE_HISTORY];
            float highs[MAX_CANDLE_HISTORY];
            float lows[MAX_CANDLE_HISTORY];
            float volumes[MAX_CANDLE_HISTORY];
            for (int i = 0; i < n; i++) {
                closes[i]  = s.closed_candles[i].close;
                highs[i]   = s.closed_candles[i].high;
                lows[i]    = s.closed_candles[i].low;
                volumes[i] = s.closed_candles[i].volume;
            }

            // === EMA ===
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
            f.ema_5 = ema5; f.ema_10 = ema10;
            f.ema_20 = ema20; f.ema_50 = ema50;

            // === RSI ===
            int rsi_period = std::min(14, n - 1);
            float gains = 0, losses = 0;
            for (int i = n - rsi_period; i < n; i++) {
                float diff = closes[i] - closes[i - 1];
                if (diff > 0) gains += diff;
                else losses -= diff;
            }
            float avg_gain = gains / rsi_period;
            float avg_loss = losses / rsi_period;
            float rs = (avg_loss > 1e-8f) ? avg_gain / avg_loss : 100.0f;
            f.rsi = 100.0f - 100.0f / (1.0f + rs);

            // === Bollinger Bands ===
            int bb_period = std::min(20, n);
            float bb_sum = 0, bb_sum2 = 0;
            for (int i = n - bb_period; i < n; i++) {
                bb_sum += closes[i];
                bb_sum2 += closes[i] * closes[i];
            }
            float bb_mean = bb_sum / bb_period;
            float bb_var = bb_sum2 / bb_period - bb_mean * bb_mean;
            float bb_std = sqrtf(std::max(bb_var, 0.0f));
            f.bb_middle = bb_mean;
            f.bb_upper = bb_mean + 2.0f * bb_std;
            f.bb_lower = bb_mean - 2.0f * bb_std;

            // === MACD ===
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
            f.macd_line = ema12 - ema26;
            f.macd_signal = macd_signal;
            f.macd_hist = f.macd_line - macd_signal;

            // === ATR ===
            int atr_period = std::min(14, n);
            float atr_sum = 0;
            for (int i = n - atr_period; i < n; i++) {
                float tr = highs[i] - lows[i];
                if (i > 0) {
                    tr = std::max(tr, fabsf(highs[i] - closes[i - 1]));
                    tr = std::max(tr, fabsf(lows[i] - closes[i - 1]));
                }
                atr_sum += tr;
            }
            f.atr = atr_sum / atr_period;

            // === Volatility ===
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
                f.volatility = sqrtf(std::max(lr_var, 0.0f)) * sqrtf(525600.0f);
            }

            // === Volume ratio ===
            float vol_sum = 0;
            for (int i = 0; i < n; i++) vol_sum += volumes[i];
            float avg_vol = vol_sum / n;
            f.volume_ratio = (avg_vol > 0) ? s.candle_volume / avg_vol : 1.0f;

            // === Momentum ===
            int mom_lookback = std::min(10, n);
            float old_close = closes[n - mom_lookback];
            if (old_close > 0) {
                f.momentum = (closes[n - 1] - old_close) / old_close;
            }

            // === VWAP deviation ===
            float current_vwap = s.vwap();
            if (current_vwap > 0) {
                f.vwap_deviation = (s.last_price - current_vwap) / current_vwap;
            }

            // === Monte Carlo VaR Simulation ===
            // THIS IS THE CPU BOTTLENECK: 256 paths × 100 steps, SEQUENTIAL
            float vol = f.volatility;
            if (vol < 1e-6f) vol = 0.01f;
            float price = s.last_price;
            if (price <= 0) price = 1.0f;

            float dt = 1.0f / 525600.0f;
            float sqrt_dt = sqrtf(dt);
            float drift = -0.5f * vol * vol * dt;

            float mc_returns[MC_PATHS];

            for (int path = 0; path < MC_PATHS; path++) {
                uint32_t rng = (uint32_t)(path + 1) * 2654435761u +
                               (uint32_t)sid * 1103515245u + 12345u;

                float sim_price = price;

                for (int step = 0; step < MC_STEPS; step++) {
                    // XorShift32 (same as GPU)
                    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
                    float u1 = (float)(rng & 0x7FFFFFFF) / (float)0x7FFFFFFF + 1e-10f;
                    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
                    float u2 = (float)(rng & 0x7FFFFFFF) / (float)0x7FFFFFFF;

                    // Box-Muller
                    float z = sqrtf(-2.0f * logf(u1)) * cosf(6.28318530718f * u2);

                    // GBM step
                    sim_price *= expf(drift + vol * sqrt_dt * z);
                }

                mc_returns[path] = (sim_price - price) / price;
            }

            // Compute VaR and ES from MC results
            float mc_sum = 0, mc_sum2 = 0;
            for (int i = 0; i < MC_PATHS; i++) {
                mc_sum += mc_returns[i];
                mc_sum2 += mc_returns[i] * mc_returns[i];
            }
            float mc_mean = mc_sum / MC_PATHS;
            float mc_var = mc_sum2 / MC_PATHS - mc_mean * mc_mean;
            float mc_std = sqrtf(std::max(mc_var, 0.0f));

            f.var_95 = (mc_mean - 1.645f * mc_std) * price;

            float var_threshold = mc_mean - 1.645f * mc_std;
            float es_sum = 0;
            int es_count = 0;
            for (int i = 0; i < MC_PATHS; i++) {
                if (mc_returns[i] <= var_threshold) {
                    es_sum += mc_returns[i];
                    es_count++;
                }
            }
            f.expected_shortfall = (es_count > 0)
                ? (es_sum / es_count) * price
                : f.var_95;
        }
    }

    /* Stage 3: Multi-factor strategy evaluation (same as GPU) */
    void evaluate_strategy() {
        order_count = 0;
        for (int sid = 0; sid < N_SYMBOLS; ++sid) {
            const PerSymbolState& s = states[sid];
            const FeatureVector& f = features[sid];

            if (s.closed_count < 3 || s.candle_trade_count == 0) continue;

            float signal = 0.0f;

            // Factor 1: EMA crossover
            if (f.ema_20 > 0) {
                signal += 0.25f * (f.ema_5 - f.ema_20) / f.ema_20;
            }

            // Factor 2: RSI
            signal += 0.20f * (50.0f - f.rsi) / 50.0f;

            // Factor 3: Bollinger Band position
            float bb_width = f.bb_upper - f.bb_lower;
            if (bb_width > 0) {
                float bb_pos = (s.last_price - f.bb_middle) / (bb_width * 0.5f);
                signal -= 0.15f * bb_pos;
            }

            // Factor 4: MACD histogram
            signal += 0.15f * (f.macd_hist > 0 ? 1.0f : -1.0f) *
                      std::min(fabsf(f.macd_hist) / std::max(f.atr, 0.01f), 1.0f);

            // Factor 5: Volume confirmation
            signal += 0.10f * std::min(f.volume_ratio - 1.0f, 2.0f) *
                      (signal > 0 ? 1.0f : -1.0f);

            // Factor 6: VWAP deviation
            signal += 0.10f * f.vwap_deviation;

            // Factor 7: Risk-adjusted
            float risk_penalty = std::max(-f.var_95 / std::max(s.last_price, 1.0f), 0.0f);
            signal *= std::max(1.0f - risk_penalty, 0.1f);

            // Generate order if signal is strong enough
            float threshold = 0.001f;
            if (fabsf(signal) > threshold) {
                Order& o = orders[order_count++];
                o.symbol_id = sid;
                o.ts_ns = 0;
                o.price = s.last_price;
                o.qty = 0.01f;
                o.order_type = 0;
                o.side = (signal > 0) ? 0 : 1;
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

        aggregate_candles(events, n);
        compute_features();
        evaluate_strategy();
        pack_orders();

        uint64_t t1 = now_ns();
        latency.record(t0, t1);
        throughput.add_batch(n);

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

    int total_events = 1000000;
    int batch_size = 1000;

    if (argc > 1 && strcmp(argv[1], "--udp") == 0) {
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
        const char* path = (argc > 2) ? argv[2] : "data.bin";
        batch_size = (argc > 3) ? atoi(argv[3]) : 1000;

        printf("Mode: File replay from %s (batch_size=%d)\n", path, batch_size);

        CPUPipeline pipeline;
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

        printf("Mode: LIVE Binance WebSocket (batch_size=%d)\n", batch_size);
        printf("Press Ctrl+C to stop.\n\n");

        CPUPipeline pipeline;
        BinanceWSFeed feed;

        static BinanceWSFeed* g_feed = &feed;
        signal(SIGINT, [](int) { g_feed->stop(); });

        int batch_num = 0;
        feed.on_batch = [&](const MarketEvent* events, int n) {
            pipeline.process_batch(events, n);
            batch_num++;
            if (batch_num % 10 == 0) {
                printf("[CPU LIVE] Batch %d: %d events | PnL=$%.4f | %.0f ev/s\n",
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

        printf("Mode: Synthetic benchmark (%d events, batch_size=%d)\n",
               total_events, batch_size);

        CPUPipeline pipeline;
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
