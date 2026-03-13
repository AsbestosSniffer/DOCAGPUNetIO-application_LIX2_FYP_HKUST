#pragma once
#include "market_event.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <functional>
#include <atomic>
#include <thread>
#include <mutex>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

/* ─── Data Source Abstraction ─────────────────────────────────────────── */
// Provides market events from: (1) .bin file replay, (2) UDP socket,
// or (3) synthetic generator. Binance WebSocket will be added later.

enum class FeedMode { FILE_REPLAY, UDP_RECV, SYNTHETIC };

// Callback: called with a batch of events
using BatchCallback = std::function<void(const MarketEvent* events, int n)>;

/* ─── File Replay Feed ───────────────────────────────────────────────── */

struct FileReplayFeed {
    std::vector<MarketEvent> events;
    int pos = 0;

    bool load(const char* path) {
        FILE* f = fopen(path, "rb");
        if (!f) { fprintf(stderr, "Cannot open %s\n", path); return false; }
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        int n = (int)(sz / sizeof(MarketEvent));
        events.resize(n);
        fread(events.data(), sizeof(MarketEvent), n, f);
        fclose(f);
        printf("Loaded %d events from %s\n", n, path);
        return true;
    }

    // Get next batch; returns number of events (0 = done)
    int next_batch(MarketEvent* out, int max_batch) {
        if (pos >= (int)events.size()) return 0;
        int n = std::min(max_batch, (int)events.size() - pos);
        memcpy(out, events.data() + pos, n * sizeof(MarketEvent));
        pos += n;
        return n;
    }

    void reset() { pos = 0; }
    int total() const { return (int)events.size(); }
};

/* ─── UDP Receiver Feed ──────────────────────────────────────────────── */

struct UDPFeed {
    int sock = -1;
    std::vector<char> buf;

    bool start(int port, int max_batch = 10000) {
        sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (sock < 0) { perror("socket"); return false; }

        sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(port);

        if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            perror("bind"); close(sock); sock = -1; return false;
        }
        buf.resize(sizeof(PacketHeader) + max_batch * sizeof(MarketEvent));
        printf("UDP feed listening on port %d\n", port);
        return true;
    }

    // Blocking receive; returns number of events (0 = error)
    int recv_batch(MarketEvent* out) {
        ssize_t r = recv(sock, buf.data(), buf.size(), 0);
        if (r < (ssize_t)sizeof(PacketHeader)) return 0;

        PacketHeader hdr;
        memcpy(&hdr, buf.data(), sizeof(PacketHeader));
        if (hdr.magic != 0xDEADBEEF) return 0;

        int n = hdr.event_count;
        if (n <= 0 || r < (ssize_t)(sizeof(PacketHeader) + n * sizeof(MarketEvent))) return 0;

        memcpy(out, buf.data() + sizeof(PacketHeader), n * sizeof(MarketEvent));
        return n;
    }

    void stop() { if (sock >= 0) { close(sock); sock = -1; } }
};

/* ─── Synthetic Event Generator ──────────────────────────────────────── */
// Generates deterministic fake events for benchmarking.
// Both CPU and GPU systems use identical data for fair comparison.

struct SyntheticFeed {
    int total_events;
    float base_prices[N_SYMBOLS];

    SyntheticFeed(int n = 1000000) : total_events(n) {
        // Realistic base prices (approx Binance March 2026)
        base_prices[0] = 85000.0f;  // BTC
        base_prices[1] = 3200.0f;   // ETH
        base_prices[2] = 620.0f;    // BNB
        base_prices[3] = 145.0f;    // SOL
        base_prices[4] = 2.5f;      // XRP
        base_prices[5] = 0.75f;     // ADA
        base_prices[6] = 0.18f;     // DOGE
        base_prices[7] = 0.12f;     // TRX
        base_prices[8] = 38.0f;     // AVAX
        base_prices[9] = 7.5f;      // DOT
    }

    void generate(MarketEvent* out, int n, uint32_t seed = 42) {
        // Simple LCG for reproducibility (no stdlib dependency on GPU side)
        uint32_t rng = seed;
        uint64_t base_ts = 1709251200000000000ULL; // 2024-03-01 00:00 UTC

        for (int i = 0; i < n; ++i) {
            rng = rng * 1103515245U + 12345U;
            uint32_t sym = (rng >> 16) % N_SYMBOLS;

            rng = rng * 1103515245U + 12345U;
            float noise = ((float)(rng & 0xFFFF) / 65535.0f - 0.5f) * 0.002f;

            out[i].ts_ns = base_ts + (uint64_t)i * 100000ULL; // 0.1ms apart
            out[i].symbol_id = sym;
            out[i].price = base_prices[sym] * (1.0f + noise);
            out[i].qty = 0.01f + ((rng >> 8) & 0xFF) * 0.001f;
            out[i].side = (rng >> 24) & 1;
            out[i].trade_id = (uint64_t)i;
        }
    }
};
