/*
 * microbench_udp.cu — Standalone CUDA microbenchmark replicating the UDP
 * receive kernel's payload inspection loop.
 *
 * Purpose: allow `ncu --set full` to replay the kernel without the live NIC
 * dependency. Reads 48-byte packets from a pre-populated device buffer and
 * performs the same DNS classification that cuda_kernel_receive_udp does.
 *
 * Build:
 *   nvcc -O3 -arch=sm_86 -o microbench_udp microbench_udp.cu
 *
 * Run (Nsight Compute roofline):
 *   ncu --set roofline --output microbench_udp_roofline ./microbench_udp
 *
 * Run (full sections — includes cache, occupancy, warp stats):
 *   ncu --set full --output microbench_udp_full ./microbench_udp
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cuda_runtime.h>

/* Match the pipeline's packet layout: each slot is MAX_PKT_SIZE bytes */
#define PKT_SLOT_BYTES   8192
#define NUM_PKTS         4096   /* packets per batch, matching MAX_RX_NUM_PKTS */
#define NUM_THREADS      512    /* matching CUDA_THREADS in defines.h */
#define DNS_PORT_BE      0x3500 /* DNS port 53 in big-endian */

/* Minimal UDP header overlay at the start of each packet slot */
struct udp_hdr_stub {
    uint8_t  eth[14];
    uint8_t  ip[20];
    uint16_t src_port;
    uint16_t dst_port;
    uint16_t length;
    uint16_t checksum;
};

/* Classify a packet as DNS (port 53) — mirrors filter_is_dns() */
__device__ __forceinline__ int is_dns(const uint8_t *pkt_base)
{
    const struct udp_hdr_stub *h = (const struct udp_hdr_stub *)pkt_base;
    return (h->dst_port == DNS_PORT_BE);
}

/*
 * Kernel: replicates the payload inspection loop of cuda_kernel_receive_udp.
 * Each thread processes packets at stride blockDim.x, then warp-reduces.
 */
__global__ void microbench_classify_udp(const uint8_t *pkt_buf,
                                        uint32_t       num_pkts,
                                        uint64_t      *dns_count_out,
                                        uint64_t      *other_count_out)
{
    __shared__ uint64_t sh_dns;
    __shared__ uint64_t sh_other;

    if (threadIdx.x == 0) { sh_dns = 0; sh_other = 0; }
    __syncthreads();

    uint64_t dns   = 0;
    uint64_t other = 0;

    uint32_t idx = threadIdx.x;
    while (idx < num_pkts) {
        const uint8_t *pkt = pkt_buf + (uint64_t)idx * PKT_SLOT_BYTES;
        if (is_dns(pkt))
            dns++;
        else
            other++;
        idx += blockDim.x;
    }

    /* Warp-level reduction — mirrors the __shfl_down_sync in the main kernel */
#pragma unroll
    for (int offset = 16; offset > 0; offset >>= 1) {
        dns   += __shfl_down_sync(0xffffffff, dns,   offset);
        other += __shfl_down_sync(0xffffffff, other, offset);
        __syncwarp();
    }

    if ((threadIdx.x & 31) == 0) {
        atomicAdd((unsigned long long *)&sh_dns,   (unsigned long long)dns);
        atomicAdd((unsigned long long *)&sh_other, (unsigned long long)other);
    }
    __syncthreads();

    if (threadIdx.x == 0) {
        atomicAdd((unsigned long long *)dns_count_out,   (unsigned long long)sh_dns);
        atomicAdd((unsigned long long *)other_count_out, (unsigned long long)sh_other);
    }
}

static void check(cudaError_t e, const char *ctx)
{
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error at %s: %s\n", ctx, cudaGetErrorString(e));
        exit(1);
    }
}

int main(int argc, char **argv)
{
    int num_iters = (argc > 1) ? atoi(argv[1]) : 1000;

    /* Allocate device packet buffer and fill with pseudo-random bytes */
    size_t buf_bytes = (size_t)NUM_PKTS * PKT_SLOT_BYTES;
    uint8_t *h_buf = (uint8_t *)malloc(buf_bytes);
    if (!h_buf) { fprintf(stderr, "malloc failed\n"); return 1; }

    /* Make ~50% of packets appear DNS (port 53) */
    memset(h_buf, 0, buf_bytes);
    for (int i = 0; i < NUM_PKTS; i++) {
        struct udp_hdr_stub *hdr = (struct udp_hdr_stub *)(h_buf + (size_t)i * PKT_SLOT_BYTES);
        if (i % 2 == 0)
            hdr->dst_port = DNS_PORT_BE;
        else
            hdr->dst_port = 0x5000; /* port 80 */
    }

    uint8_t  *d_buf = NULL;
    uint64_t *d_dns = NULL, *d_other = NULL;
    check(cudaMalloc(&d_buf,   buf_bytes),    "cudaMalloc pkt_buf");
    check(cudaMalloc(&d_dns,   sizeof(uint64_t)), "cudaMalloc dns");
    check(cudaMalloc(&d_other, sizeof(uint64_t)), "cudaMalloc other");
    check(cudaMemcpy(d_buf, h_buf, buf_bytes, cudaMemcpyHostToDevice), "H2D pkt_buf");

    cudaEvent_t t0, t1;
    check(cudaEventCreate(&t0), "event t0");
    check(cudaEventCreate(&t1), "event t1");

    /* Warmup */
    microbench_classify_udp<<<1, NUM_THREADS>>>(d_buf, NUM_PKTS, d_dns, d_other);
    check(cudaDeviceSynchronize(), "warmup sync");
    check(cudaMemset(d_dns,   0, sizeof(uint64_t)), "reset dns");
    check(cudaMemset(d_other, 0, sizeof(uint64_t)), "reset other");

    /* Timed iterations */
    check(cudaEventRecord(t0), "record t0");
    for (int it = 0; it < num_iters; it++) {
        microbench_classify_udp<<<1, NUM_THREADS>>>(d_buf, NUM_PKTS, d_dns, d_other);
    }
    check(cudaEventRecord(t1), "record t1");
    check(cudaEventSynchronize(t1), "sync t1");

    float ms = 0;
    check(cudaEventElapsedTime(&ms, t0, t1), "elapsed");

    uint64_t h_dns = 0, h_other = 0;
    check(cudaMemcpy(&h_dns,   d_dns,   sizeof(uint64_t), cudaMemcpyDeviceToHost), "D2H dns");
    check(cudaMemcpy(&h_other, d_other, sizeof(uint64_t), cudaMemcpyDeviceToHost), "D2H other");

    double pkts_per_iter = (double)NUM_PKTS;
    double total_pkts    = pkts_per_iter * num_iters;
    double throughput_gpps = total_pkts / (ms * 1e6); /* Gpkts/s */
    double bytes_per_iter  = pkts_per_iter * PKT_SLOT_BYTES; /* bytes read per iter */
    double bw_gbps         = (bytes_per_iter * num_iters) / (ms * 1e6);

    printf("=== microbench_udp results ===\n");
    printf("Iterations    : %d\n", num_iters);
    printf("Packets/iter  : %d (slot size %d B)\n", NUM_PKTS, PKT_SLOT_BYTES);
    printf("Total time    : %.2f ms\n", ms);
    printf("Throughput    : %.3f Gpkt/s\n", throughput_gpps);
    printf("Memory BW     : %.2f GB/s (read only, assuming full slot read)\n", bw_gbps);
    printf("DNS classified: %llu  Other: %llu\n",
           (unsigned long long)h_dns, (unsigned long long)h_other);
    printf("\nNOTE: 'Memory BW' above is an upper bound (full PKT_SLOT_BYTES per packet).\n"
           "In practice the kernel only reads the 42-byte UDP header — actual BW is ~42/%d = %.1f%%.\n",
           PKT_SLOT_BYTES, 100.0 * 42.0 / PKT_SLOT_BYTES);

    cudaFree(d_buf); cudaFree(d_dns); cudaFree(d_other);
    free(h_buf);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
    return 0;
}
