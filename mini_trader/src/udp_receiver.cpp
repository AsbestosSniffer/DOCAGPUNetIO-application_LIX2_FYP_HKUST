#include <iostream>
#include <vector>
#include <thread>
#include <cstring>
#include <cstdint>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include "market_event.h"

struct PacketHeader {
    uint32_t magic;
    uint16_t version;
    uint32_t packet_seq;
    uint32_t event_count;
};

int main(int argc, char** argv) {
    int port = (argc > 1) ? std::stoi(argv[1]) : 9999;
    int batch_limit = (argc > 2) ? std::stoi(argv[2]) : 10000;
    std::cout << "UDP receiver listening on port " << port << ", batch_limit=" << batch_limit << "\n";

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }
    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sock);
        return 1;
    }

    std::vector<MarketEvent> batch;
    int total_events = 0;
    int total_packets = 0;
    while (true) {
        std::vector<char> buf(sizeof(PacketHeader) + batch_limit * sizeof(MarketEvent));
        ssize_t r = recv(sock, buf.data(), buf.size(), 0);
        if (r < (ssize_t)sizeof(PacketHeader)) {
            std::cerr << "Short packet received: " << r << " bytes\n";
            continue;
        }
        PacketHeader hdr;
        std::memcpy(&hdr, buf.data(), sizeof(PacketHeader));
        if (hdr.magic != 0xDEADBEEF) {
            std::cerr << "Bad magic in packet\n";
            continue;
        }
        int n = hdr.event_count;
        if (n <= 0 || r < (ssize_t)(sizeof(PacketHeader) + n * sizeof(MarketEvent))) {
            std::cerr << "Bad event count or short packet\n";
            continue;
        }
        batch.resize(n);
        std::memcpy(batch.data(), buf.data() + sizeof(PacketHeader), n * sizeof(MarketEvent));
        total_events += n;
        total_packets++;
        std::cout << "Received packet_seq=" << hdr.packet_seq << " events=" << n << " total_events=" << total_events << "\n";
        // Here: pass batch to GPU pipeline (stub)
        std::this_thread::sleep_for(std::chrono::milliseconds(1)); // simulate GPU processing
    }
    close(sock);
    return 0;
}
