#pragma once
/*
 * Binance WebSocket Live Feed
 * ─────────────────────────────
 * Connects to wss://stream.binance.com:9443 and receives real-time
 * trade events for all 10 symbols. Parses JSON into MarketEvent structs
 * and delivers them in batches to a callback.
 *
 * Dependencies:
 *   libwebsockets  (sudo apt install libwebsockets-dev)
 *   nlohmann/json  (sudo apt install nlohmann-json3-dev)
 *
 * Usage:
 *   BinanceWSFeed feed;
 *   feed.on_batch = [](const MarketEvent* events, int n) { ... };
 *   feed.start(1000);  // batch size 1000, blocks until stop() called
 */

#include "market_event.h"
#include <libwebsockets.h>
#include <nlohmann/json.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <functional>
#include <atomic>
#include <mutex>
#include <chrono>

using json = nlohmann::json;

/* ─── Configuration ──────────────────────────────────────────────────── */

static const char* BINANCE_WS_HOST = "stream.binance.com";
static const int   BINANCE_WS_PORT = 9443;

// Combined stream path for all 10 symbols
// Format: /stream?streams=btcusdt@trade/ethusdt@trade/...
static std::string build_stream_path() {
    // Lowercase symbol names for Binance WebSocket API
    const char* symbols_lower[N_SYMBOLS] = {
        "btcusdt", "ethusdt", "bnbusdt", "solusdt", "xrpusdt",
        "adausdt", "dogeusdt", "trxusdt", "avaxusdt", "dotusdt"
    };
    std::string path = "/stream?streams=";
    for (int i = 0; i < N_SYMBOLS; ++i) {
        if (i > 0) path += "/";
        path += symbols_lower[i];
        path += "@trade";
    }
    return path;
}

/* ─── Symbol Lookup (fast, lowercase) ────────────────────────────────── */

static uint32_t symbol_from_binance(const char* sym, int len) {
    // Binance sends uppercase symbol in JSON "s" field
    // Match against our SYMBOL_NAMES array
    for (uint32_t i = 0; i < N_SYMBOLS; ++i) {
        if (strncmp(sym, SYMBOL_NAMES[i], len) == 0 &&
            SYMBOL_NAMES[i][len] == '\0') {
            return i;
        }
    }
    return UINT32_MAX;
}

/* ─── Feed Class ─────────────────────────────────────────────────────── */

struct BinanceWSFeed {
    // Callback: called when batch_size events have accumulated
    std::function<void(const MarketEvent* events, int n)> on_batch;

    // Internal state
    std::vector<MarketEvent> batch_buffer;
    int batch_size = 1000;
    std::mutex batch_mutex;
    std::atomic<bool> running{false};
    std::atomic<uint64_t> total_events{0};
    std::atomic<uint64_t> total_messages{0};
    std::atomic<uint64_t> parse_errors{0};

    // libwebsockets context
    struct lws_context* lws_ctx = nullptr;
    struct lws* wsi = nullptr;

    // Receive buffer for fragmented messages
    std::string rx_buffer;

    /* ── Parse a single Binance trade JSON message ── */
    bool parse_trade(const char* data, int len, MarketEvent* out) {
        try {
            json j = json::parse(data, data + len);

            // Combined stream wraps in {"stream":"...","data":{...}}
            const json* trade = &j;
            if (j.contains("data")) {
                trade = &j["data"];
            }

            // Verify it's a trade event
            if (!trade->contains("e") || (*trade)["e"] != "trade") {
                return false;
            }

            // Extract fields
            std::string sym = (*trade)["s"].get<std::string>();
            out->symbol_id = symbol_from_binance(sym.c_str(), (int)sym.size());
            if (out->symbol_id == UINT32_MAX) return false;

            // Price and quantity are strings in Binance JSON
            out->price = std::stof((*trade)["p"].get<std::string>());
            out->qty   = std::stof((*trade)["q"].get<std::string>());

            // Trade time in milliseconds -> nanoseconds
            uint64_t trade_time_ms = (*trade)["T"].get<uint64_t>();
            out->ts_ns = trade_time_ms * 1000000ULL;

            // isBuyerMaker: true = seller initiated, false = buyer initiated
            // Our convention: side 0 = buyer, side 1 = seller
            out->side = (*trade)["m"].get<bool>() ? 1 : 0;

            // Trade ID
            out->trade_id = (*trade)["t"].get<uint64_t>();

            return true;
        } catch (...) {
            return false;
        }
    }

    /* ── Process received WebSocket message ── */
    void on_message(const char* data, int len) {
        total_messages++;

        MarketEvent ev;
        if (!parse_trade(data, len, &ev)) {
            parse_errors++;
            return;
        }

        total_events++;

        std::lock_guard<std::mutex> lock(batch_mutex);
        batch_buffer.push_back(ev);

        if ((int)batch_buffer.size() >= batch_size && on_batch) {
            on_batch(batch_buffer.data(), (int)batch_buffer.size());
            batch_buffer.clear();
        }
    }

    /* ── Flush any remaining events in the buffer ── */
    void flush() {
        std::lock_guard<std::mutex> lock(batch_mutex);
        if (!batch_buffer.empty() && on_batch) {
            on_batch(batch_buffer.data(), (int)batch_buffer.size());
            batch_buffer.clear();
        }
    }

    /* ── Start the WebSocket connection (blocking) ── */
    void start(int batch_sz = 1000) {
        batch_size = batch_sz;
        batch_buffer.reserve(batch_sz * 2);
        running = true;

        printf("[BinanceWS] Connecting to %s:%d...\n", BINANCE_WS_HOST, BINANCE_WS_PORT);

        // Setup libwebsockets
        struct lws_context_creation_info ctx_info;
        memset(&ctx_info, 0, sizeof(ctx_info));

        // Protocol definition
        static struct lws_protocols protocols[] = {
            {
                "binance-ws",
                BinanceWSFeed::lws_callback,
                0,       // per-session data size
                65536,   // rx buffer size
                0, nullptr, 0
            },
            LWS_PROTOCOL_MAP_SENTINEL
        };

        ctx_info.port = CONTEXT_PORT_NO_LISTEN;
        ctx_info.protocols = protocols;
        ctx_info.options = LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT;
        ctx_info.user = this;

        lws_ctx = lws_create_context(&ctx_info);
        if (!lws_ctx) {
            fprintf(stderr, "[BinanceWS] Failed to create context\n");
            return;
        }

        // Connect
        std::string path = build_stream_path();

        struct lws_client_connect_info conn_info;
        memset(&conn_info, 0, sizeof(conn_info));
        conn_info.context = lws_ctx;
        conn_info.address = BINANCE_WS_HOST;
        conn_info.port = BINANCE_WS_PORT;
        conn_info.path = path.c_str();
        conn_info.host = BINANCE_WS_HOST;
        conn_info.origin = BINANCE_WS_HOST;
        conn_info.ssl_connection = LCCSCF_USE_SSL;
        conn_info.protocol = "binance-ws";
        conn_info.userdata = this;

        wsi = lws_client_connect_via_info(&conn_info);
        if (!wsi) {
            fprintf(stderr, "[BinanceWS] Failed to connect\n");
            lws_context_destroy(lws_ctx);
            lws_ctx = nullptr;
            return;
        }

        printf("[BinanceWS] Connected. Streaming %d symbols.\n", N_SYMBOLS);
        printf("[BinanceWS] Batch size: %d events\n", batch_size);

        // Event loop
        while (running && lws_ctx) {
            lws_service(lws_ctx, 100); // 100ms timeout
        }

        // Flush remaining
        flush();

        // Cleanup
        if (lws_ctx) {
            lws_context_destroy(lws_ctx);
            lws_ctx = nullptr;
        }

        printf("[BinanceWS] Disconnected. Total: %lu events, %lu messages, %lu parse errors\n",
               (unsigned long)total_events.load(),
               (unsigned long)total_messages.load(),
               (unsigned long)parse_errors.load());
    }

    /* ── Stop the feed ── */
    void stop() {
        running = false;
    }

    /* ── Print statistics ── */
    void print_stats() const {
        printf("[BinanceWS] Events: %lu  Messages: %lu  Parse errors: %lu  Buffer: %zu\n",
               (unsigned long)total_events.load(),
               (unsigned long)total_messages.load(),
               (unsigned long)parse_errors.load(),
               batch_buffer.size());
    }

    /* ── libwebsockets callback (static) ── */
    static int lws_callback(struct lws* wsi, enum lws_callback_reasons reason,
                            void* user, void* in, size_t len)
    {
        // Get feed instance from context userdata
        struct lws_context* ctx = lws_get_context(wsi);
        BinanceWSFeed* feed = nullptr;
        if (ctx) {
            feed = (BinanceWSFeed*)lws_context_user(ctx);
        }

        switch (reason) {
        case LWS_CALLBACK_CLIENT_ESTABLISHED:
            if (feed) {
                printf("[BinanceWS] WebSocket connection established\n");
            }
            break;

        case LWS_CALLBACK_CLIENT_RECEIVE:
            if (feed && in && len > 0) {
                // Handle message fragmentation
                int is_final = lws_is_final_fragment(wsi);
                feed->rx_buffer.append((const char*)in, len);

                if (is_final) {
                    feed->on_message(feed->rx_buffer.c_str(),
                                     (int)feed->rx_buffer.size());
                    feed->rx_buffer.clear();
                }
            }
            break;

        case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
            fprintf(stderr, "[BinanceWS] Connection error: %s\n",
                    in ? (const char*)in : "unknown");
            if (feed) feed->running = false;
            break;

        case LWS_CALLBACK_CLIENT_CLOSED:
            printf("[BinanceWS] Connection closed\n");
            if (feed) feed->running = false;
            break;

        default:
            break;
        }

        return 0;
    }
};
