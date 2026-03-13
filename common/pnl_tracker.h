#pragma once
#include "market_event.h"
#include <vector>
#include <cstdio>
#include <algorithm>
#include <cmath>

/* ─── Unified PnL Tracker ────────────────────────────────────────────── */
// Used by all three systems so trading results are directly comparable.

struct PnLTracker {
    // Per-symbol open buy orders (FIFO queue for matching)
    std::vector<Order> open_buys[N_SYMBOLS];

    float cumulative_pnl  = 0;
    float peak_pnl        = 0;
    int   total_trades    = 0;
    int   winning_trades  = 0;

    void process_orders(const Order* orders, int n_orders) {
        for (int i = 0; i < n_orders; ++i) {
            const Order& o = orders[i];
            if (o.symbol_id >= N_SYMBOLS) continue;

            if (o.side == 0) { // BUY
                open_buys[o.symbol_id].push_back(o);
            } else { // SELL
                auto& q = open_buys[o.symbol_id];
                if (!q.empty()) {
                    Order buy = q.front();
                    q.erase(q.begin());
                    float pnl = (o.price - buy.price) * buy.qty;
                    cumulative_pnl += pnl;
                    total_trades++;
                    if (pnl > 0) winning_trades++;
                    peak_pnl = std::max(peak_pnl, cumulative_pnl);
                }
            }
        }
    }

    float win_rate() const {
        return total_trades > 0 ? 100.0f * winning_trades / total_trades : 0;
    }

    float max_drawdown() const {
        return std::max(0.0f, peak_pnl - cumulative_pnl);
    }

    void print_summary() const {
        printf("\n=== Trade Performance ===\n");
        printf("  Total closed trades : %d\n", total_trades);
        printf("  Winning trades      : %d (%.1f%%)\n", winning_trades, win_rate());
        printf("  Cumulative PnL      : $%.4f\n", cumulative_pnl);
        printf("  Peak PnL            : $%.4f\n", peak_pnl);
        printf("  Max Drawdown        : $%.4f\n", max_drawdown());
    }
};
