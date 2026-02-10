#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <thread>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <random>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include "market_event.h"

// Simple UDP replayer: reads .bin file or generates fake events, sends micro-batched UDP packets
// Usage: udp_replayer <output_host> <output_port> <bin_file|FAKE> <events_per_packet> <total_events> <pacing_mode>
// pacing_mode: 0=blast, 1=real-time (sleep 1us per event), 2=hybrid (burst then sleep)

struct PacketHeader {
    uint32_t magic = 0xDEADBEEF;
    uint16_t version = 1;
    uint32_t packet_seq = 0;
    uint32_t event_count = 0;
};

int main(int argc, char** argv) {
    if (argc < 6) {
        std::cerr << "Usage: " << argv[0] << " <host> <port> <bin_file|FAKE> <events_per_packet> <total_events> [pacing_mode]\n";
        return 1;
    }
    std::string host = argv[1];
    int port = std::stoi(argv[2]);
    std::string bin_file = argv[3];
    int events_per_packet = std::stoi(argv[4]);
    int total_events = std::stoi(argv[5]);
    int pacing_mode = (argc > 6) ? std::stoi(argv[6]) : 0;

    std::vector<MarketEvent> events;
    if (bin_file == "FAKE") {
        // Generate fake events
        std::mt19937 rng(42);
        std::uniform_real_distribution<float> price_dist(10000, 50000);
        std::uniform_real_distribution<float> qty_dist(0.001, 1.0);
        for (int i = 0; i < total_events; ++i) {
            MarketEvent ev;
            ev.ts_ns = 1640995200000000000ULL + i * 1000000ULL; // 1ms step
            ev.symbol_id = i % 10;
            ev.price = price_dist(rng);
            ev.qty = qty_dist(rng);
            ev.side = (i % 2);
            ev.trade_id = i;
            events.push_back(ev);
        }
        std::cout << "Generated " << events.size() << " fake events\n";
    } else {
        // Read .bin file
        std::ifstream fin(bin_file, std::ios::binary);
        if (!fin) {
            std::cerr << "Failed to open bin file: " << bin_file << "\n";
            return 1;
        }
        fin.seekg(0, std::ios::end);
        size_t sz = fin.tellg();
        fin.seekg(0, std::ios::beg);
        size_t n_events = sz / sizeof(MarketEvent);
        events.resize(n_events);
        fin.read(reinterpret_cast<char*>(events.data()), sz);
        fin.close();
        std::cout << "Loaded " << events.size() << " events from " << bin_file << "\n";
        if (total_events > (int)events.size()) total_events = (int)events.size();
    }

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }
    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr(host.c_str());

    int sent = 0;
    int packet_seq = 0;
    auto start = std::chrono::steady_clock::now();
    while (sent < total_events) {
        int n = std::min(events_per_packet, total_events - sent);
        PacketHeader hdr;
        hdr.packet_seq = packet_seq++;
        hdr.event_count = n;
        std::vector<char> buf(sizeof(PacketHeader) + n * sizeof(MarketEvent));
        std::memcpy(buf.data(), &hdr, sizeof(PacketHeader));
        std::memcpy(buf.data() + sizeof(PacketHeader), events.data() + sent, n * sizeof(MarketEvent));
        int r = sendto(sock, buf.data(), buf.size(), 0, (struct sockaddr*)&addr, sizeof(addr));
        if (r < 0) {
            perror("sendto");
            break;
        }
        sent += n;
        if ((packet_seq % 100) == 0) std::cout << "sent packet_seq=" << packet_seq << " sent=" << sent << "\n";
        // pacing
        if (pacing_mode == 1) std::this_thread::sleep_for(std::chrono::microseconds(n)); // 1us/event
        else if (pacing_mode == 2 && (packet_seq % 10) == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    auto end = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(end - start).count();
    std::cout << "Replay finished: " << sent << " events in " << ms << " ms\n";
    close(sock);
    return 0;
}
