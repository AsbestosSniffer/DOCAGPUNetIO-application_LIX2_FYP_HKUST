/*
 * GPU-side DOCA GPUNetIO Packet Receiver + Trading Pipeline
 * ───────────────────────────────────────────────────────────
 * This persistent CUDA kernel runs on the GPU and:
 *   1. Receives packets directly from NIC via doca_gpu_dev_eth_rxq
 *   2. Parses Ethernet/IP/TCP headers on GPU
 *   3. Extracts MarketEvent from packet payload
 *   4. Runs the trading pipeline (candle agg + features + strategy)
 *   5. Signals CPU via GPU semaphore when batch is ready
 *
 * NOTE: Requires DOCA GPUNetIO device headers (.cuh). Only compiles on server.
 */

#include "../../common/market_event.h"
#include <cuda_runtime.h>
#include <cstdint>

#ifdef HAVE_DOCA
/* DOCA 3.x GPU device headers use .cuh extension */
#include <doca_gpunetio.h>
#include <doca_gpunetio_dev_eth_rxq.cuh>
#include <doca_gpunetio_dev_sem.cuh>
#include <doca_gpunetio_dev_buf.cuh>
#endif

/* ─── Network Header Structures (parsed on GPU) ─────────────────────── */

struct __attribute__((packed)) EthHeader {
    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];
    uint16_t ether_type;  // 0x0800 = IPv4
};

struct __attribute__((packed)) IPv4Header {
    uint8_t  ver_ihl;
    uint8_t  tos;
    uint16_t total_length;
    uint16_t identification;
    uint16_t flags_fragment;
    uint8_t  ttl;
    uint8_t  protocol;    // 6 = TCP, 17 = UDP
    uint16_t checksum;
    uint32_t src_ip;
    uint32_t dst_ip;
};

struct __attribute__((packed)) TCPHeader {
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t seq_num;
    uint32_t ack_num;
    uint8_t  data_offset; // upper 4 bits = header length in 32-bit words
    uint8_t  flags;
    uint16_t window;
    uint16_t checksum;
    uint16_t urgent;
};

struct __attribute__((packed)) UDPHeader {
    uint16_t src_port;
    uint16_t dst_port;
    uint16_t length;
    uint16_t checksum;
};

/* ─── GPU Helper: Byte Swap ──────────────────────────────────────────── */

__device__ uint16_t gpu_ntohs(uint16_t val) {
    return (val >> 8) | (val << 8);
}

/* ─── GPU Packet Parser ──────────────────────────────────────────────── */

// Parse a raw packet buffer into a MarketEvent
// Returns true if successfully parsed
__device__ bool parse_packet_to_event(
    const uint8_t* pkt, int pkt_len,
    MarketEvent* out_event)
{
    if (pkt_len < (int)(sizeof(EthHeader) + sizeof(IPv4Header))) return false;

    const EthHeader* eth = (const EthHeader*)pkt;
    if (gpu_ntohs(eth->ether_type) != 0x0800) return false; // Not IPv4

    const IPv4Header* ip = (const IPv4Header*)(pkt + sizeof(EthHeader));
    int ip_hdr_len = (ip->ver_ihl & 0x0F) * 4;

    const uint8_t* payload = NULL;
    int payload_len = 0;

    if (ip->protocol == 17) { // UDP
        const UDPHeader* udp = (const UDPHeader*)(pkt + sizeof(EthHeader) + ip_hdr_len);
        payload = (const uint8_t*)(udp + 1);
        payload_len = pkt_len - sizeof(EthHeader) - ip_hdr_len - sizeof(UDPHeader);
    } else if (ip->protocol == 6) { // TCP
        const TCPHeader* tcp = (const TCPHeader*)(pkt + sizeof(EthHeader) + ip_hdr_len);
        int tcp_hdr_len = ((tcp->data_offset >> 4) & 0x0F) * 4;
        payload = pkt + sizeof(EthHeader) + ip_hdr_len + tcp_hdr_len;
        payload_len = pkt_len - sizeof(EthHeader) - ip_hdr_len - tcp_hdr_len;
    } else {
        return false;
    }

    // Check if payload contains our binary MarketEvent format
    // (In production, the DPU ARM cores or a local proxy would convert
    //  Binance JSON → binary MarketEvent before steering to GPU)
    if (payload_len >= (int)sizeof(MarketEvent)) {
        const MarketEvent* ev = (const MarketEvent*)payload;
        *out_event = *ev;
        return true;
    }

    return false;
}

/* ─── GPU Persistent Kernel: Receive + Process ───────────────────────── */

#ifdef HAVE_DOCA

#ifndef MAX_RX_BURST
#define MAX_RX_BURST 64
#endif
#ifndef NUM_SEMAPHORES
#define NUM_SEMAPHORES 16
#endif

__global__ void gpu_receive_and_process(
    struct doca_gpu_eth_rxq* rxq,
    struct doca_gpu_semaphore_gpu* sem,
    PerSymbolState* states,
    Order* orders,
    int* order_count,
    volatile bool* d_running)
{
    int tid = threadIdx.x;
    int sem_idx = 0;

    while (*d_running) {
        /* ── Step 1: Receive packets from NIC ── */
        uint32_t first_idx = 0;
        uint32_t num_pkts = 0;

        doca_error_t result = doca_gpu_dev_eth_rxq_recv(
            rxq, MAX_RX_BURST, /*timeout_ns=*/1000000, /* 1ms */
            &first_idx, &num_pkts);

        if (result != DOCA_SUCCESS || num_pkts == 0) continue;

        /* ── Step 2: Parse packets → MarketEvents ── */
        __shared__ MarketEvent events[MAX_RX_BURST];
        __shared__ int event_count;
        if (tid == 0) event_count = 0;
        __syncthreads();

        for (uint32_t p = tid; p < num_pkts; p += blockDim.x) {
            uintptr_t pkt_addr;
            uint32_t pkt_len;
            doca_gpu_dev_eth_rxq_get_pkt_addr(rxq, first_idx + p,
                                               &pkt_addr, &pkt_len);

            MarketEvent ev;
            if (parse_packet_to_event((const uint8_t*)pkt_addr, pkt_len, &ev)) {
                int idx = atomicAdd(&event_count, 1);
                if (idx < MAX_RX_BURST) events[idx] = ev;
            }
        }
        __syncthreads();

        if (event_count == 0) continue;

        /* ── Step 3: Apply events — thread 0 per symbol for correctness ── */
        if (tid < N_SYMBOLS) {
            PerSymbolState& s = states[tid];
            for (int i = 0; i < event_count; i++) {
                const MarketEvent& ev = events[i];
                if (ev.symbol_id != (uint32_t)tid) continue;

                uint64_t candle_ts = (ev.ts_ns / CANDLE_INTERVAL_NS) * CANDLE_INTERVAL_NS;

                if (s.candle_trade_count == 0) {
                    s.candle_start_ts = candle_ts;
                    s.candle_open = ev.price;
                    s.candle_high = ev.price;
                    s.candle_low  = ev.price;
                } else if (candle_ts != s.candle_start_ts) {
                    s.close_candle();
                    s.candle_start_ts = candle_ts;
                    s.candle_open = ev.price;
                    s.candle_high = ev.price;
                    s.candle_low  = ev.price;
                }

                s.candle_high = fmaxf(s.candle_high, ev.price);
                s.candle_low  = fminf(s.candle_low,  ev.price);
                s.candle_close = ev.price;
                s.candle_volume += ev.qty;
                s.candle_trade_count++;
                s.last_price = ev.price;
                s.total_trades++;
                s.vwap_sum_pq += (double)ev.price * (double)ev.qty;
                s.vwap_sum_q  += (double)ev.qty;
            }
        }
        __syncthreads();

        /* ── Step 4: Strategy (thread 0 per symbol) ── */
        if (tid == 0) *order_count = 0;
        __syncthreads();

        if (tid < N_SYMBOLS) {
            const PerSymbolState& s = states[tid];
            if (s.candle_trade_count > 0 && s.closed_count > 0) {
                const Candle& prev = s.closed_candles[s.closed_count - 1];
                float pc = (s.candle_close - prev.close) / prev.close;

                Order o;
                o.symbol_id = tid;
                o.ts_ns = 0;
                o.price = s.last_price;
                o.qty = 0.01f;
                o.order_type = 0;

                bool emit = false;
                float v = s.vwap();
                if (pc > 0.001f && s.last_price > v) {
                    o.side = 0; emit = true;
                } else if (pc < -0.001f && s.last_price < v) {
                    o.side = 1; emit = true;
                }

                if (emit) {
                    int idx = atomicAdd(order_count, 1);
                    if (idx < N_SYMBOLS * 2) orders[idx] = o;
                }
            }
        }
        __syncthreads();

        /* ── Step 5: Signal CPU via semaphore ── */
        if (tid == 0 && *order_count > 0) {
            doca_gpu_dev_semaphore_set_status(sem, sem_idx,
                DOCA_GPU_SEMAPHORE_STATUS_READY);
            sem_idx = (sem_idx + 1) % NUM_SEMAPHORES;
        }
        __syncthreads();
    }
}

#endif /* HAVE_DOCA */

/* ─── Stub for non-DOCA builds ───────────────────────────────────────── */

#ifndef HAVE_DOCA
#define NUM_SEMAPHORES 16
#define MAX_RX_BURST   64

// Stub: simulates the DOCA persistent kernel for testing
__global__ void gpu_receive_stub(
    const MarketEvent* input_events, int n_events,
    PerSymbolState* states, Order* orders, int* order_count,
    int batch_size)
{
    // Each block handles one symbol — no race conditions
    int sid = blockIdx.x;
    if (sid >= N_SYMBOLS || threadIdx.x != 0) return;

    PerSymbolState& s = states[sid];

    for (int i = 0; i < n_events; i++) {
        const MarketEvent& ev = input_events[i];
        if (ev.symbol_id != (uint32_t)sid) continue;

        uint64_t candle_ts = (ev.ts_ns / CANDLE_INTERVAL_NS) * CANDLE_INTERVAL_NS;

        if (s.candle_trade_count == 0) {
            s.candle_start_ts = candle_ts;
            s.candle_open = ev.price;
            s.candle_high = ev.price;
            s.candle_low  = ev.price;
        } else if (candle_ts != s.candle_start_ts) {
            s.close_candle();
            s.candle_start_ts = candle_ts;
            s.candle_open = ev.price;
            s.candle_high = ev.price;
            s.candle_low  = ev.price;
        }

        s.candle_high = fmaxf(s.candle_high, ev.price);
        s.candle_low  = fminf(s.candle_low,  ev.price);
        s.candle_close = ev.price;
        s.candle_volume += ev.qty;
        s.candle_trade_count++;
        s.last_price = ev.price;
        s.total_trades++;
        s.vwap_sum_pq += (double)ev.price * (double)ev.qty;
        s.vwap_sum_q  += (double)ev.qty;
    }
}

#endif /* !HAVE_DOCA */
