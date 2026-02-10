#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <chrono>
#include <iomanip>
#include <queue>
#include <algorithm>
#include "market_event.h"

/**
 * Simple results logger for trading pipeline output
 * Reads order statistics and writes detailed logs
 * Calculates PnL, Win Rate, and Max Drawdown
 */

struct OrderResult {
    uint32_t symbol_id;
    uint8_t side;        // 0=buy, 1=sell
    float price;
    float qty;
    uint64_t ts_ns;
};

struct BatchStats {
    uint64_t batch_num;
    uint32_t event_count;
    uint32_t signal_count;
    uint32_t buy_count;
    uint32_t sell_count;
    float total_qty;
    double kernel_time_ms;
};

struct TradeResult {
    float entry_price;
    float exit_price;
    float qty;
    float pnl;
    bool is_winning;
};

void log_orders_csv(const std::vector<OrderResult>& orders, const std::string& out_csv) {
    std::ofstream fout(out_csv);
    fout << "symbol,side,price,qty,timestamp_ns\n";
    for (const auto& o : orders) {
        std::string symbol = id_to_symbol(o.symbol_id);
        std::string side_str = (o.side == 0) ? "BUY" : "SELL";
        fout << symbol << "," << side_str << "," << o.price << "," << o.qty << "," << o.ts_ns << "\n";
    }
    fout.close();
    std::cout << "Orders written to " << out_csv << " (" << orders.size() << " orders)\n";
}

void log_batch_stats_csv(const std::vector<BatchStats>& stats, const std::string& out_csv) {
    std::ofstream fout(out_csv);
    fout << "batch_num,event_count,signal_count,buy_count,sell_count,total_qty,kernel_time_ms\n";

    for (const auto& s : stats) {
        fout << s.batch_num << ","
             << s.event_count << ","
             << s.signal_count << ","
             << s.buy_count << ","
             << s.sell_count << ","
             << s.total_qty << ","
             << std::fixed << std::setprecision(3) << s.kernel_time_ms << "\n";
    }
    fout.close();
    std::cout << "Batch stats written to " << out_csv << " (" << stats.size() << " batches)\n";
}

struct PnLMetrics {
    float total_pnl;
    float max_drawdown;
    int total_trades;
    int winning_trades;
    float win_rate;
};

PnLMetrics calculate_pnl_metrics(const std::vector<OrderResult>& orders) {
    PnLMetrics metrics = {0, 0, 0, 0, 0};

    // Use a queue of open BUY positions per symbol
    std::vector<std::queue<OrderResult>> open_buys(10);  // 10 symbols
    std::vector<TradeResult> closed_trades;
    float cumulative_pnl = 0;
    float peak_pnl = 0;

    for (const auto& order : orders) {
        if (order.side == 0) {  // BUY
            open_buys[order.symbol_id].push(order);
        } else {  // SELL
            if (!open_buys[order.symbol_id].empty()) {
                auto buy = open_buys[order.symbol_id].front();
                open_buys[order.symbol_id].pop();

                // Calculate PnL for this closed trade
                float pnl = (order.price - buy.price) * buy.qty;
                bool is_winning = pnl > 0;

                TradeResult trade = {buy.price, order.price, buy.qty, pnl, is_winning};
                closed_trades.push_back(trade);

                cumulative_pnl += pnl;
                peak_pnl = std::max(peak_pnl, cumulative_pnl);
                metrics.total_pnl = cumulative_pnl;

                // Track drawdown
                float drawdown = peak_pnl - cumulative_pnl;
                metrics.max_drawdown = std::max(metrics.max_drawdown, drawdown);
            }
        }
    }

    // Calculate win rate
    metrics.total_trades = closed_trades.size();
    if (metrics.total_trades > 0) {
        for (const auto& trade : closed_trades) {
            if (trade.is_winning) metrics.winning_trades++;
        }
        metrics.win_rate = 100.0f * metrics.winning_trades / metrics.total_trades;
    }

    return metrics;
}

void print_summary(const std::vector<BatchStats>& stats, const PnLMetrics& pnl) {
    if (stats.empty()) return;

    uint64_t total_events = 0;
    uint32_t total_signals = 0;
    uint32_t total_buy = 0;
    uint32_t total_sell = 0;
    double total_time = 0;

    for (const auto& s : stats) {
        total_events += s.event_count;
        total_signals += s.signal_count;
        total_buy += s.buy_count;
        total_sell += s.sell_count;
        total_time += s.kernel_time_ms;
    }

    double signal_rate = (total_signals > 0) ? (100.0 * total_signals / total_events) : 0;
    double throughput = (total_time > 0) ? (1000.0 * total_events / total_time) : 0;

    std::cout << "\n=== Trading Pipeline Summary ===\n";
    std::cout << "Total batches: " << stats.size() << "\n";
    std::cout << "Total events: " << total_events << "\n";
    std::cout << "Total signals: " << total_signals << " (" << std::fixed << std::setprecision(2)
              << signal_rate << "%)\n";
    std::cout << "  BUY signals: " << total_buy << "\n";
    std::cout << "  SELL signals: " << total_sell << "\n";
    std::cout << "Total kernel time: " << std::fixed << std::setprecision(2) << total_time << " ms\n";
    std::cout << "Throughput: " << std::fixed << std::setprecision(0) << throughput << " events/sec\n";

    if (stats.size() > 1) {
        double avg_time = total_time / stats.size();
        std::cout << "Avg kernel time per batch: " << std::fixed << std::setprecision(3)
                  << avg_time << " ms\n";
    }

    // Trading Performance
    std::cout << "\n=== Trade Performance ===\n";
    std::cout << "Total trades closed: " << pnl.total_trades << "\n";
    std::cout << "Total PnL: $" << std::fixed << std::setprecision(2) << pnl.total_pnl << "\n";
    std::cout << "Win rate: " << std::fixed << std::setprecision(1) << pnl.win_rate << "% ("
              << pnl.winning_trades << "/" << pnl.total_trades << ")\n";
    std::cout << "Max drawdown: $" << std::fixed << std::setprecision(2) << pnl.max_drawdown << "\n";
}

int main(int argc, char** argv) {
    std::string mode = (argc > 1) ? argv[1] : "print";

    if (mode == "print") {
        // Standalone mode: print hardcoded example
        std::vector<BatchStats> example_stats;
        example_stats.push_back({1, 1000, 5, 3, 2, 0.05f, 12.5});
        example_stats.push_back({2, 1000, 7, 4, 3, 0.07f, 11.8});
        example_stats.push_back({3, 1000, 6, 3, 3, 0.06f, 12.1});

        std::vector<OrderResult> example_orders;
        // Create a realistic trading sequence: BUY at 30000, SELL at 30200 (+$2 profit)
        example_orders.push_back({0, 0, 30000.0f, 0.01f, 1640995200000000000ULL});  // BUY BTC
        example_orders.push_back({0, 1, 30200.0f, 0.01f, 1640995260000000000ULL});   // SELL BTC (+$2)
        // BUY at 2000, SELL at 1950 (-$5 loss)
        example_orders.push_back({1, 0, 2000.0f, 0.1f, 1640995320000000000ULL});     // BUY ETH
        example_orders.push_back({1, 1, 1950.0f, 0.1f, 1640995380000000000ULL});     // SELL ETH (-$5)
        // BUY at 500, SELL at 520 (+$10 profit)
        example_orders.push_back({2, 0, 500.0f, 0.5f, 1640995440000000000ULL});      // BUY BNB
        example_orders.push_back({2, 1, 520.0f, 0.5f, 1640995500000000000ULL});      // SELL BNB (+$10)

        // Calculate trading metrics
        PnLMetrics pnl = calculate_pnl_metrics(example_orders);

        print_summary(example_stats, pnl);

        log_orders_csv(example_orders, "orders_example.csv");
        log_batch_stats_csv(example_stats, "batch_stats_example.csv");

        std::cout << "(This is example output. Run with real pipeline data.)\n";
    }
    else {
        std::cerr << "Usage: " << argv[0] << " [mode]\n";
        std::cerr << "  mode: print (default, shows example output)\n";
        return 1;
    }

    return 0;
}
