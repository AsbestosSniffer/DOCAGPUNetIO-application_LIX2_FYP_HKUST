#pragma once
#include "market_event.h"
#include <vector>
#include <deque>
#include <cstdio>
#include <algorithm>
#include <cmath>

/* ─── Unified PnL Tracker ────────────────────────────────────────────── */
// Used by all three systems so trading results are directly comparable.

struct PnLTracker {
    // Per-symbol open buy orders (FIFO queue for matching)
    std::deque<Order> open_buys[N_SYMBOLS];

    double cumulative_pnl  = 0;
    double peak_pnl        = 0;
    int    total_trades    = 0;
    int    winning_trades  = 0;

    void process_orders(const Order* orders, int n_orders) {
        for (int i = 0; i < n_orders; ++i) {
            const Order& o = orders[i];
            if (o.symbol_id >= (uint32_t)N_SYMBOLS) continue;

            if (o.side == 0) { // BUY
                open_buys[o.symbol_id].push_back(o);
            } else { // SELL
                auto& q = open_buys[o.symbol_id];
                if (!q.empty()) {
                    Order buy = q.front();
                    q.pop_front();
                    double pnl = (double)(o.price - buy.price) * (double)std::min(o.qty, buy.qty);
                    cumulative_pnl += pnl;
                    total_trades++;
                    if (pnl > 0) winning_trades++;
                    peak_pnl = std::max(peak_pnl, cumulative_pnl);
                }
            }
        }
    }

    double win_rate() const {
        return total_trades > 0 ? 100.0 * winning_trades / total_trades : 0;
    }

    double max_drawdown() const {
        return std::max(0.0, peak_pnl - cumulative_pnl);
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
