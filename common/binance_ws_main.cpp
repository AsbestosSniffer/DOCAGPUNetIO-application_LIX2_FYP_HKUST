/*
 * Binance WebSocket Live Feed — Standalone Test
 * ───────────────────────────────────────────────
 * Connects to Binance and prints live trade events.
 * Use this to verify WebSocket connectivity before integrating
 * with the CPU or GPU pipelines.
 *
 * Usage:
 *   ./binance_ws_test                   # Print trades as they arrive
 *   ./binance_ws_test --dump 1000       # Print first 1000 events then exit
 *   ./binance_ws_test --bin output.bin  # Save events to binary file
 *
 * Build:
 *   g++ -O3 -std=c++17 -Icommon common/binance_ws_main.cpp \
 *       -lwebsockets -lssl -lcrypto -lpthread -o binance_ws_test
 */

#include "binance_ws_feed.h"
#include "benchmark.h"
#include <cstdio>
#include <cstring>
#include <csignal>
#include <vector>

static BinanceWSFeed* g_feed = nullptr;

static void signal_handler(int) {
    if (g_feed) g_feed->stop();
}

int main(int argc, char** argv) {
    printf("╔══════════════════════════════════════╗\n");
    printf("║  Binance WebSocket Live Feed Test    ║\n");
    printf("╚══════════════════════════════════════╝\n\n");

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    bool dump_mode = false;
    int max_events = 0;
    const char* bin_output = nullptr;
    FILE* bin_file = nullptr;

    // Parse args
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--dump") == 0 && i + 1 < argc) {
            dump_mode = true;
            max_events = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--bin") == 0 && i + 1 < argc) {
            bin_output = argv[++i];
        }
    }

    if (bin_output) {
        bin_file = fopen(bin_output, "wb");
        if (!bin_file) {
            fprintf(stderr, "Cannot open %s for writing\n", bin_output);
            return 1;
        }
        printf("Saving events to: %s\n", bin_output);
    }

    // Statistics
    ThroughputMeter meter;
    uint64_t event_count = 0;
    auto start_time = std::chrono::steady_clock::now();

    BinanceWSFeed feed;
    g_feed = &feed;

    feed.on_batch = [&](const MarketEvent* events, int n) {
        meter.add_batch(n);
        event_count += n;

        // Print sample events
        for (int i = 0; i < n; ++i) {
            const MarketEvent& ev = events[i];
            const char* side_str = (ev.side == 0) ? "BUY " : "SELL";
            const char* sym = (ev.symbol_id < N_SYMBOLS) ? SYMBOL_NAMES[ev.symbol_id] : "???";

            printf("[%s] %s  price=%.4f  qty=%.6f  trade_id=%lu\n",
                   sym, side_str, ev.price, ev.qty,
                   (unsigned long)ev.trade_id);

            // Save to binary file
            if (bin_file) {
                fwrite(&ev, sizeof(MarketEvent), 1, bin_file);
            }
        }

        // Print stats every 100 events
        if (event_count % 100 < (uint64_t)n) {
            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start_time).count();
            printf("--- %lu events in %.1fs (%.0f ev/s) ---\n",
                   (unsigned long)event_count, elapsed, event_count / elapsed);
        }

        // Stop if dump mode and reached limit
        if (dump_mode && (int)event_count >= max_events) {
            feed.stop();
        }
    };

    // Start (blocking)
    int batch_size = dump_mode ? std::min(max_events, 100) : 100;
    feed.start(batch_size);

    // Final stats
    printf("\n=== Final Statistics ===\n");
    meter.print("Live Feed");
    feed.print_stats();

    if (bin_file) {
        fclose(bin_file);
        printf("Saved %lu events to %s (%.1f KB)\n",
               (unsigned long)event_count, bin_output,
               event_count * sizeof(MarketEvent) / 1024.0);
    }

    g_feed = nullptr;
    return 0;
}
