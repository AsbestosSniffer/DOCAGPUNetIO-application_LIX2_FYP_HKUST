#pragma once
#include <stdint.h>
#include <string.h>

#ifdef __CUDACC__
  #define CUDA_CALLABLE __device__ __host__
#else
  #define CUDA_CALLABLE
#endif

/* ─── Constants ────────────────────────────────────────────────────────── */

static const int N_SYMBOLS = 10;
static const int MAX_CANDLE_HISTORY = 64;
static const uint64_t CANDLE_INTERVAL_NS = 60000000000ULL; // 60 seconds

// Monte Carlo simulation parameters
static const int MC_PATHS = 256;    // simulation paths per symbol
static const int MC_STEPS = 100;    // steps per path

// Symbol mapping for 10 Binance tickers
static const char* SYMBOL_NAMES[N_SYMBOLS] = {
    "BTCUSDT", "ETHUSDT", "BNBUSDT", "SOLUSDT", "XRPUSDT",
    "ADAUSDT", "DOGEUSDT", "TRXUSDT", "AVAXUSDT", "DOTUSDT"
};

/* ─── Core Data Structures ─────────────────────────────────────────────── */

// Binary event struct — shared by all three systems
struct __attribute__((packed)) MarketEvent {
    uint64_t ts_ns;      // nanosecond timestamp
    uint32_t symbol_id;  // 0..9
    float    price;
    float    qty;
    uint8_t  side;       // 0=buyer, 1=seller (from isBuyerMaker)
    uint64_t trade_id;
};

// Candle (OHLCV)
struct Candle {
    uint64_t ts_start_ns;
    float open, high, low, close;
    float volume;
    uint32_t trade_count;
};

// Per-symbol state for candle aggregation and features
struct PerSymbolState {
    // Current candle being built
    float candle_open, candle_high, candle_low, candle_close;
    float candle_volume;
    uint32_t candle_trade_count;
    uint64_t candle_start_ts;

    // Closed candle ring buffer
    Candle closed_candles[MAX_CANDLE_HISTORY];
    int closed_count;

    // VWAP (volume-weighted average price)
    double vwap_sum_pq;  // sum(price * qty)
    double vwap_sum_q;   // sum(qty)

    float last_price;
    uint32_t total_trades;

    CUDA_CALLABLE void init() {
        candle_open = 0; candle_high = 0; candle_low = 1e9f; candle_close = 0;
        candle_volume = 0; candle_trade_count = 0; candle_start_ts = 0;
        closed_count = 0;
        vwap_sum_pq = 0; vwap_sum_q = 0;
        last_price = 0; total_trades = 0;
    }

    CUDA_CALLABLE float vwap() const {
        return vwap_sum_q > 0 ? (float)(vwap_sum_pq / vwap_sum_q) : 0.0f;
    }

    CUDA_CALLABLE void close_candle() {
        if (candle_trade_count == 0) return;
        Candle c;
        c.ts_start_ns = candle_start_ts;
        c.open = candle_open; c.high = candle_high;
        c.low = candle_low;   c.close = candle_close;
        c.volume = candle_volume; c.trade_count = candle_trade_count;

        if (closed_count < MAX_CANDLE_HISTORY) {
            closed_candles[closed_count++] = c;
        } else {
            for (int i = 0; i < MAX_CANDLE_HISTORY - 1; ++i)
                closed_candles[i] = closed_candles[i + 1];
            closed_candles[MAX_CANDLE_HISTORY - 1] = c;
        }
        candle_open = 0; candle_high = 0; candle_low = 1e9f;
        candle_close = 0; candle_volume = 0; candle_trade_count = 0;
    }
};

// Feature vector — computed per symbol by GPU/CPU feature engineering
struct FeatureVector {
    // Exponential Moving Averages
    float ema_5, ema_10, ema_20, ema_50;

    // RSI (Relative Strength Index, 14-period)
    float rsi;

    // Bollinger Bands (20-period, 2 std dev)
    float bb_upper, bb_middle, bb_lower;

    // MACD (12, 26, signal 9)
    float macd_line, macd_signal, macd_hist;

    // ATR (Average True Range, 14-period)
    float atr;

    // Volatility (annualized realized vol from log returns)
    float volatility;

    // Volume analysis
    float volume_ratio;   // current volume vs moving average

    // Price features
    float momentum;       // rate of change
    float vwap_deviation; // price vs VWAP

    // Monte Carlo risk metrics
    float var_95;              // 95% Value at Risk
    float expected_shortfall;  // Conditional VaR (CVaR)

    // Combined signal
    float signal_strength;
    int   signal_side;    // -1=no signal, 0=buy, 1=sell
};

// Order output
struct Order {
    uint32_t symbol_id;
    uint8_t  side;       // 0=buy, 1=sell
    float    price;
    float    qty;
    uint64_t ts_ns;
    uint8_t  order_type; // 0=market, 1=limit
};

// Batch statistics
struct OrderStats {
    uint32_t total_signals;
    uint32_t buy_count;
    uint32_t sell_count;
    float    total_qty;
};

/* ─── Inline Helpers ───────────────────────────────────────────────────── */

inline uint32_t symbol_to_id(const char* sym) {
    for (uint32_t i = 0; i < N_SYMBOLS; ++i)
        if (strcmp(sym, SYMBOL_NAMES[i]) == 0) return i;
    return UINT32_MAX;
}

// UDP packet header (shared between replayer and receiver)
struct PacketHeader {
    uint32_t magic;        // 0xDEADBEEF
    uint16_t version;
    uint32_t packet_seq;
    uint32_t event_count;
};
