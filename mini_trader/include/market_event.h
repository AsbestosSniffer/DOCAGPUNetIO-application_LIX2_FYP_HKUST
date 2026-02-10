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
