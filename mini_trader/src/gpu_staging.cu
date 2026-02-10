#include <iostream>
#include <vector>
#include <cuda_runtime.h>
#include "market_event.h"

// Dummy kernel pipeline: decode_parse, apply_events, strategy, pack_orders
__global__ void decode_parse_kernel(const MarketEvent* in, int n) {
    // No-op for now
}

__global__ void apply_events_kernel(const MarketEvent* in, int n, float* per_symbol_state) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        // Dummy: accumulate price per symbol
        atomicAdd(&per_symbol_state[in[i].symbol_id], in[i].price);
    }
}

__global__ void strategy_kernel(const float* per_symbol_state, int n, int* orders_out) {
    int i = threadIdx.x;
    if (i < n) {
        // Dummy: fire order if price sum > threshold
        orders_out[i] = (per_symbol_state[i] > 100000.0f) ? 1 : 0;
    }
}

__global__ void pack_orders_kernel(const int* orders_in, int n, int* packed_out) {
    int i = threadIdx.x;
    if (i < n) packed_out[i] = orders_in[i];
}

int main(int argc, char** argv) {
    int n = (argc > 1) ? std::stoi(argv[1]) : 10000;
    std::vector<MarketEvent> events(n);
    for (int i = 0; i < n; ++i) {
        events[i].symbol_id = i % 10;
        events[i].price = 10000.0f + i;
    }
    MarketEvent* d_events;
    float* d_state;
    int* d_orders;
    int* d_packed;
    cudaMalloc(&d_events, n * sizeof(MarketEvent));
    cudaMalloc(&d_state, 10 * sizeof(float));
    cudaMalloc(&d_orders, 10 * sizeof(int));
    cudaMalloc(&d_packed, 10 * sizeof(int));
    cudaMemcpy(d_events, events.data(), n * sizeof(MarketEvent), cudaMemcpyHostToDevice);
    cudaMemset(d_state, 0, 10 * sizeof(float));
    decode_parse_kernel<<<1, n>>>(d_events, n);
    apply_events_kernel<<<1, n>>>(d_events, n, d_state);
    strategy_kernel<<<1, 10>>>(d_state, 10, d_orders);
    pack_orders_kernel<<<1, 10>>>(d_orders, 10, d_packed);
    int packed[10];
    cudaMemcpy(packed, d_packed, 10 * sizeof(int), cudaMemcpyDeviceToHost);
    std::cout << "Packed orders: ";
    for (int i = 0; i < 10; ++i) std::cout << packed[i] << " ";
    std::cout << "\n";
    cudaFree(d_events);
    cudaFree(d_state);
    cudaFree(d_orders);
    cudaFree(d_packed);
    return 0;
}
