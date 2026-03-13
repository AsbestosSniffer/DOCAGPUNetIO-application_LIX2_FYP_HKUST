#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cstdint>
#include <algorithm>
#include "market_event.h"

// Binance trade CSV columns: trade_id,price,qty,quoteQty,time,isBuyerMaker,isBestMatch
// Example: 123456,30000.0,0.01,300.0,1640995200000,true,true

int main(int argc, char** argv) {
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0] << " <input.csv> <symbol> <output.bin>\n";
        return 1;
    }
    std::string input_csv = argv[1];
    std::string symbol = argv[2];
    std::string output_bin = argv[3];

    uint32_t symbol_id = symbol_to_id(symbol);
    if (symbol_id == UINT32_MAX) {
        std::cerr << "Unknown symbol: " << symbol << "\n";
        return 1;
    }

    std::ifstream fin(input_csv);
    if (!fin) {
        std::cerr << "Failed to open input CSV: " << input_csv << "\n";
        return 1;
    }

    std::vector<MarketEvent> events;
    std::string line;
    int line_num = 0;
    while (std::getline(fin, line)) {
        ++line_num;
        if (line.empty() || line[0] < '0') continue; // skip header or blank
        std::istringstream ss(line);
        std::string field;
        std::vector<std::string> fields;
        while (std::getline(ss, field, ',')) fields.push_back(field);
        if (fields.size() < 7) continue;
        try {
            uint64_t trade_id = std::stoull(fields[0]);
            float price = std::stof(fields[1]);
            float qty = std::stof(fields[2]);
            uint64_t ts_ms = std::stoull(fields[4]);
            uint8_t side = (fields[5] == "true" || fields[5] == "1") ? 1 : 0;
            MarketEvent ev;
            ev.ts_ns = ts_ms * 1000000ULL;
            ev.symbol_id = symbol_id;
            ev.price = price;
            ev.qty = qty;
            ev.side = side;
            ev.trade_id = trade_id;
            events.push_back(ev);
        } catch (...) {
            std::cerr << "Parse error at line " << line_num << "\n";
            continue;
        }
    }
    fin.close();

    // Sort by timestamp
    std::sort(events.begin(), events.end(), [](const MarketEvent& a, const MarketEvent& b) {
        return a.ts_ns < b.ts_ns;
    });

    std::ofstream fout(output_bin, std::ios::binary);
    if (!fout) {
        std::cerr << "Failed to open output BIN: " << output_bin << "\n";
        return 1;
    }
    fout.write(reinterpret_cast<const char*>(events.data()), events.size() * sizeof(MarketEvent));
    fout.close();

    std::cout << "Converted " << events.size() << " events for " << symbol << " to " << output_bin << "\n";
    return 0;
}
