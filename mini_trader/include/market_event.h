#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>

// Binary event struct for all modules
struct MarketEvent {
    uint64_t ts_ns;      // nanosecond timestamp
    uint32_t symbol_id;  // mapped from ticker
    float price;
    float qty;
    uint8_t side;        // 0=buyer, 1=seller (from isBuyerMaker)
    uint64_t trade_id;   // optional, for deduplication
};

// Symbol mapping for 10 tickers
static const char* SYMBOLS[10] = {
    "BTCUSDT", "ETHUSDT", "BNBUSDT", "SOLUSDT", "XRPUSDT",
    "ADAUSDT", "DOGEUSDT", "TRXUSDT", "AVAXUSDT", "DOTUSDT"
};

inline uint32_t symbol_to_id(const std::string& sym) {
    for (uint32_t i = 0; i < 10; ++i) {
        if (sym == SYMBOLS[i]) return i;
    }
    return UINT32_MAX; // not found
}

inline std::string id_to_symbol(uint32_t id) {
    if (id < 10) return SYMBOLS[id];
    return "UNKNOWN";
}

// Candle (OHLCV) structure for fixed time intervals
struct Candle {
    uint64_t ts_start_ns;   // start of candle interval
    float open;
    float high;
    float low;
    float close;
    float volume;
    uint32_t trade_count;
};

// Per-symbol state for tracking candles and features
struct PerSymbolState {
    // Current candle in progress (being accumulated)
    float candle_open;
    float candle_high;
    float candle_low;
    float candle_close;
    float candle_volume;
    uint32_t candle_trade_count;
    uint64_t candle_start_ts;   // when current candle started (ns)

    // Closed candles (ring buffer, last N)
    static const int MAX_HISTORY = 10;
    Candle closed_candles[MAX_HISTORY];
    int closed_count;   // number of valid entries

    // Simple features for strategy
    float vwap;         // volume-weighted average price
    float last_price;
    uint32_t total_trades;

    // Initialize state
    __device__ __host__ void init() {
        candle_open = 0;
        candle_high = 0;
        candle_low = 1e9f;
        candle_close = 0;
        candle_volume = 0;
        candle_trade_count = 0;
        candle_start_ts = 0;
        closed_count = 0;
        vwap = 0;
        last_price = 0;
        total_trades = 0;
    }

    // Close current candle and move to history
    __device__ __host__ void close_candle() {
        if (candle_trade_count == 0) return;

        Candle c;
        c.ts_start_ns = candle_start_ts;
        c.open = candle_open;
        c.high = candle_high;
        c.low = candle_low;
        c.close = candle_close;
        c.volume = candle_volume;
        c.trade_count = candle_trade_count;

        if (closed_count < MAX_HISTORY) {
            closed_candles[closed_count] = c;
            closed_count++;
        } else {
            // Ring buffer: shift and add
            for (int i = 0; i < MAX_HISTORY - 1; ++i) {
                closed_candles[i] = closed_candles[i + 1];
            }
            closed_candles[MAX_HISTORY - 1] = c;
        }

        // Reset current candle
        candle_open = 0;
        candle_high = 0;
        candle_low = 1e9f;
        candle_close = 0;
        candle_volume = 0;
        candle_trade_count = 0;
    }
};

// Order structure for trading decisions
struct Order {
    uint32_t symbol_id;
    uint8_t side;        // 0=buy, 1=sell
    float price;
    float qty;
    uint64_t ts_ns;
    uint8_t order_type;  // 0=market, 1=limit (for later)

    Order() = default;
    Order(uint32_t sid, uint8_t s, float p, float q, uint64_t ts)
        : symbol_id(sid), side(s), price(p), qty(q), ts_ns(ts), order_type(0) {}
};
