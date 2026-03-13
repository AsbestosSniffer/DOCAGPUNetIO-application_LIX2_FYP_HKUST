/*
 * System 3: DOCA GPUNetIO Trading Pipeline
 * ──────────────────────────────────────────
 * NIC → GPU direct packet delivery, bypassing CPU entirely.
 *
 * Architecture:
 *   BlueField-3 NIC (ConnectX-7) steers packets to GPU RXQ
 *   → GPU kernel receives packets via doca_gpu_dev_eth_rxq_recv()
 *   → GPU parses Ethernet/IP/TCP headers in-place
 *   → GPU extracts MarketEvent from payload
 *   → Feeds into the same 4-kernel trading pipeline
 *   → GPU semaphore signals CPU for order logging
 *
 * Build: meson (see meson.build)
 *
 * NOTE: This file requires DOCA SDK headers. It will only compile on
 * the server with DOCA installed at /opt/mellanox/doca/.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <stdbool.h>

/* DOCA headers — only available on server with SDK installed */
#ifdef HAVE_DOCA
#include <doca_gpunetio.h>
#include <doca_gpunetio_dev.h>
#include <doca_eth_rxq.h>
#include <doca_flow.h>
#include <doca_pe.h>
#include <doca_dev.h>
#include <doca_buf.h>
#include <doca_mmap.h>
#include <doca_error.h>
#endif

/* Common headers */
#include "../common/market_event.h"

/* ─── Configuration ──────────────────────────────────────────────────── */

#define MAX_PKT_NUM         2048
#define MAX_PKT_SIZE        2048
#define MAX_RX_BURST        64
#define GPU_PAGE_SIZE       (1UL << 16)  /* 64KB GPU pages */
#define NUM_SEMAPHORES      16           /* Ring buffer depth */

/* ─── DOCA Context (CPU-side) ────────────────────────────────────────── */

struct DOCAContext {
#ifdef HAVE_DOCA
    struct doca_dev*         nic_dev;
    struct doca_gpu*         gpu_dev;
    struct doca_eth_rxq*     rxq;
    struct doca_gpu_semaphore* sem;
    struct doca_flow_port*   flow_port;
    struct doca_pe*          pe;
    struct doca_mmap*        pkt_mmap;
#endif
    int gpu_id;
    volatile bool running;
};

static volatile bool g_running = true;

static void signal_handler(int sig) {
    (void)sig;
    g_running = false;
}

/* ─── DOCA Device Discovery ──────────────────────────────────────────── */

#ifdef HAVE_DOCA

static doca_error_t open_doca_device(struct doca_dev** dev) {
    struct doca_devinfo** dev_list;
    uint32_t nb_devs;
    doca_error_t result;

    result = doca_devinfo_create_list(&dev_list, &nb_devs);
    if (result != DOCA_SUCCESS) return result;

    /* Find a device that supports GPUNetIO */
    for (uint32_t i = 0; i < nb_devs; i++) {
        /* Check if device supports Ethernet RX */
        result = doca_eth_rxq_cap_is_type_supported(dev_list[i],
                    DOCA_ETH_RXQ_TYPE_REGULAR);
        if (result == DOCA_SUCCESS) {
            result = doca_dev_open(dev_list[i], dev);
            if (result == DOCA_SUCCESS) {
                printf("Opened DOCA device: index %u\n", i);
                doca_devinfo_destroy_list(dev_list);
                return DOCA_SUCCESS;
            }
        }
    }

    doca_devinfo_destroy_list(dev_list);
    return DOCA_ERROR_NOT_FOUND;
}

/* ─── GPU Device Setup ───────────────────────────────────────────────── */

static doca_error_t setup_gpu(struct DOCAContext* ctx) {
    doca_error_t result;

    result = doca_gpu_create("", &ctx->gpu_dev);
    if (result != DOCA_SUCCESS) {
        fprintf(stderr, "Failed to create GPU device: %s\n",
                doca_error_get_descr(result));
        return result;
    }
    printf("GPU device created (will use GPU %d)\n", ctx->gpu_id);
    return DOCA_SUCCESS;
}

/* ─── RXQ Setup ──────────────────────────────────────────────────────── */

static doca_error_t setup_rxq(struct DOCAContext* ctx) {
    doca_error_t result;

    result = doca_eth_rxq_create(ctx->nic_dev, MAX_PKT_NUM, MAX_PKT_SIZE,
                                  &ctx->rxq);
    if (result != DOCA_SUCCESS) {
        fprintf(stderr, "Failed to create RXQ: %s\n",
                doca_error_get_descr(result));
        return result;
    }

    /* Set RXQ type to CYCLIC for GPU-side receive */
    result = doca_eth_rxq_set_type(ctx->rxq, DOCA_ETH_RXQ_TYPE_REGULAR);
    if (result != DOCA_SUCCESS) return result;

    printf("RXQ created: %d packets, %d bytes max\n", MAX_PKT_NUM, MAX_PKT_SIZE);
    return DOCA_SUCCESS;
}

/* ─── Flow Rules ─────────────────────────────────────────────────────── */

static doca_error_t setup_flow(struct DOCAContext* ctx) {
    /* DOCA Flow steering: steer all traffic matching our criteria to GPU RXQ */
    printf("Flow rules setup (placeholder — needs port/protocol config)\n");
    /* In production:
     *   1. doca_flow_init()
     *   2. doca_flow_port_start(ctx->flow_port)
     *   3. Create pipe matching dst_port=<binance_proxy_port>
     *   4. Add entry steering to GPU RXQ
     */
    return DOCA_SUCCESS;
}

/* ─── Semaphore Setup ────────────────────────────────────────────────── */

static doca_error_t setup_semaphores(struct DOCAContext* ctx) {
    doca_error_t result;

    result = doca_gpu_semaphore_create(ctx->gpu_dev, NUM_SEMAPHORES, &ctx->sem);
    if (result != DOCA_SUCCESS) {
        fprintf(stderr, "Failed to create semaphore: %s\n",
                doca_error_get_descr(result));
        return result;
    }

    /* Set all semaphores to FREE initially */
    for (int i = 0; i < NUM_SEMAPHORES; i++) {
        doca_gpu_semaphore_set_status(ctx->sem, i,
                                      DOCA_GPU_SEMAPHORE_STATUS_FREE);
    }

    printf("GPU semaphores created: %d slots\n", NUM_SEMAPHORES);
    return DOCA_SUCCESS;
}

#endif /* HAVE_DOCA */

/* ─── CPU Control Loop ───────────────────────────────────────────────── */

static void cpu_control_loop(struct DOCAContext* ctx) {
    printf("CPU control loop running (waiting for GPU semaphore signals)...\n");

    int sem_idx = 0;
    uint64_t total_batches = 0;

    while (g_running) {
#ifdef HAVE_DOCA
        /* Progress DOCA engine */
        doca_pe_progress(ctx->pe);

        /* Poll GPU semaphore for completed batches */
        enum doca_gpu_semaphore_status status;
        doca_error_t result = doca_gpu_semaphore_get_status(
            ctx->sem, sem_idx, &status);

        if (result == DOCA_SUCCESS &&
            status == DOCA_GPU_SEMAPHORE_STATUS_READY) {
            /* GPU has completed a batch — read results */
            total_batches++;

            if (total_batches % 100 == 0) {
                printf("[DOCA] Batch %lu completed (sem slot %d)\n",
                       total_batches, sem_idx);
            }

            /* Mark semaphore as free for GPU to reuse */
            doca_gpu_semaphore_set_status(ctx->sem, sem_idx,
                                          DOCA_GPU_SEMAPHORE_STATUS_FREE);
            sem_idx = (sem_idx + 1) % NUM_SEMAPHORES;
        }
#else
        /* Stub: simulate polling */
        usleep(1000);
#endif
    }

    printf("Control loop exited. Total batches: %lu\n", total_batches);
}

/* ─── Main ───────────────────────────────────────────────────────────── */

int main(int argc, char** argv) {
    printf("╔══════════════════════════════════════╗\n");
    printf("║  System 3: DOCA GPUNetIO Pipeline    ║\n");
    printf("╚══════════════════════════════════════╝\n\n");

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    struct DOCAContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.gpu_id = 1; /* Use GPU 1 (GPU 0 has VLLM) */
    ctx.running = true;

#ifdef HAVE_DOCA
    doca_error_t result;

    printf("Initializing DOCA GPUNetIO...\n");

    /* Step 1: Open NIC device */
    result = open_doca_device(&ctx.nic_dev);
    if (result != DOCA_SUCCESS) {
        fprintf(stderr, "Cannot find DOCA-capable device\n");
        return 1;
    }

    /* Step 2: Setup GPU */
    result = setup_gpu(&ctx);
    if (result != DOCA_SUCCESS) return 1;

    /* Step 3: Create RXQ */
    result = setup_rxq(&ctx);
    if (result != DOCA_SUCCESS) return 1;

    /* Step 4: Setup flow rules */
    result = setup_flow(&ctx);
    if (result != DOCA_SUCCESS) return 1;

    /* Step 5: Setup semaphores */
    result = setup_semaphores(&ctx);
    if (result != DOCA_SUCCESS) return 1;

    /* Step 6: Launch GPU persistent kernel */
    printf("TODO: Launch GPU persistent kernel (gpu_kernels/packet_recv.cu)\n");

    /* Step 7: Run CPU control loop */
    cpu_control_loop(&ctx);

    /* Cleanup */
    doca_gpu_semaphore_destroy(ctx.sem);
    doca_eth_rxq_destroy(ctx.rxq);
    doca_gpu_destroy(ctx.gpu_dev);
    doca_dev_close(ctx.nic_dev);

#else
    printf("DOCA SDK not available — running in stub mode.\n");
    printf("Build with -DHAVE_DOCA on server with /opt/mellanox/doca/ installed.\n\n");

    printf("Simulating DOCA pipeline for development...\n");
    cpu_control_loop(&ctx);
#endif

    printf("DOCA pipeline shutdown complete.\n");
    return 0;
}
