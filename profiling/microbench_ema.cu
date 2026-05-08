/*
 * microbench_ema.cu -- Standalone EMA+RSI microbenchmark for ncu profiling.
 *
 * Replicates the compute path of gpu_recv_process_kernel (gpu_receiver.cu)
 * without a live NIC or DOCA SDK. Loads a pre-generated array of TickMessage
 * structs into GPU memory and runs the EMA+RSI+signal logic in a terminating
 * kernel, so ncu can replay it freely with --set full or --set roofline.
 *
 * This is the correct target for Experiments 2 (roofline) and 4 (cache hit
 * rates) -- the live persistent kernel cannot be replayed by ncu.
 *
 * Build:
 *   nvcc -O3 -arch=sm_86 -o profiling/microbench_ema profiling/microbench_ema.cu
 *
 * Run standalone:
 *   ./profiling/microbench_ema
 *
 * Profile with ncu:
 *   ncu --set roofline  --output profiling_out/ncu_roofline ./profiling/microbench_ema
 *   ncu --set full      --output profiling_out/ncu_full     ./profiling/microbench_ema
 *   ncu --metrics l1tex__t_sectors_pipe_lsu_mem_global_op_ld_lookup_hit.sum,\
 *                 l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum,\
 *                 lts__t_sectors_op_read_lookup_hit.sum,lts__t_requests.sum \
 *       --output profiling_out/ncu_cache ./profiling/microbench_ema
 *
 * Arithmetic intensity (theoretical):
 *   ~14 FP64 FLOPs/tick, ~240 bytes read+write of TickMessage + EMA/RSI state
 *   -> ~0.058 FLOPs/byte -- far left of A2 ridge point (~75 FLOPs/byte).
 *   The kernel is trivially memory-bound; the real bottleneck is NIC latency.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cuda_runtime.h>

/* Mirror of constants from signal_result.h / tick_message.h */
#define MAX_INSTRUMENTS    256
#define EMA_ALPHA_FAST     0.05
#define EMA_ALPHA_SLOW     0.01
#define RSI_ALPHA          (2.0 / 15.0)
#define RSI_OVERBOUGHT     70.0
#define RSI_OVERSOLD       30.0
#define EMA_CROSS_THRESH   0.0003

/* Batch parameters */
#define N_TICKS            65536   /* total ticks to process */
#define WARP_SIZE          32      /* process in warp-sized batches */
#define N_BATCHES          (N_TICKS / WARP_SIZE)

#define CUDA_CHECK(call) \
    do { cudaError_t _e=(call); if(_e!=cudaSuccess){ \
        fprintf(stderr,"CUDA %s:%d: %s\n",__FILE__,__LINE__,cudaGetErrorString(_e)); \
        exit(1); }} while(0)

/* Mirror of TickMessage — must match src/common/tick_message.h exactly */
#pragma pack(push, 1)
struct TickMessage {
    uint64_t timestamp_ns;
    uint32_t tick_id;
    uint16_t instrument_id;
    uint8_t  source;
    uint8_t  _pad;
    double   bid;
    double   ask;
    double   last_price;
    double   volume;
};
#pragma pack(pop)
static_assert(sizeof(TickMessage) == 48, "TickMessage must be 48 bytes");

/* Device helper: atomic double CAS update */
__device__ static double ema_cas(double *slot, double sample, double alpha)
{
    unsigned long long *addr = reinterpret_cast<unsigned long long *>(slot);
    unsigned long long expected, desired;
    double old_val, new_val;
    do {
        expected = atomicAdd(addr, 0ULL);
        old_val  = __longlong_as_double((long long)expected);
        if (old_val == 0.0) old_val = sample;
        new_val  = alpha * sample + (1.0 - alpha) * old_val;
        desired  = (unsigned long long)__double_as_longlong(new_val);
    } while (atomicCAS(addr, expected, desired) != expected);
    return new_val;
}

__device__ static double rsi_cas(double *slot, double sample, double alpha)
{
    unsigned long long *addr = reinterpret_cast<unsigned long long *>(slot);
    unsigned long long expected, desired;
    double old_val, new_val;
    do {
        expected = atomicAdd(addr, 0ULL);
        old_val  = __longlong_as_double((long long)expected);
        new_val  = alpha * sample + (1.0 - alpha) * old_val;
        desired  = (unsigned long long)__double_as_longlong(new_val);
    } while (atomicCAS(addr, expected, desired) != expected);
    return new_val;
}

/* Output struct: one signal per tick */
struct SignalOut {
    int8_t  combined;
    int8_t  ema_sig;
    int8_t  rsi_sig;
    float   rsi;
    double  fast_ema;
    double  slow_ema;
};

/*
 * EMA+RSI kernel (one thread per tick, warp-sized batches).
 *
 * Replicates the inner loop of gpu_recv_process_kernel exactly:
 * for each tick, update fast_ema, slow_ema, avg_gain, avg_loss, last_mid
 * and emit a trading signal. All state arrays are persistent across batches
 * (they live in global memory for the kernel's lifetime, mimicking the
 * persistent-kernel behaviour of the real receiver).
 *
 * Grid: <<<N_BATCHES, WARP_SIZE>>> -- one warp per batch, N_BATCHES batches.
 * Each thread processes one tick per batch, so total ticks = N_TICKS.
 */
__global__ void ema_rsi_kernel(
    const TickMessage *ticks,    /* input: pre-loaded tick array */
    double  *d_fast_ema,         /* per-instrument state (persistent) */
    double  *d_slow_ema,
    double  *d_avg_gain,
    double  *d_avg_loss,
    double  *d_last_mid,
    SignalOut *signals)           /* output: one entry per tick */
{
    const int global_tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (global_tid >= N_TICKS) return;

    const TickMessage *tick = &ticks[global_tid];

    double mid    = (tick->bid + tick->ask) * 0.5;
    int    inst   =  tick->instrument_id % MAX_INSTRUMENTS;

    double fast_ema = ema_cas(&d_fast_ema[inst], mid, EMA_ALPHA_FAST);
    double slow_ema = ema_cas(&d_slow_ema[inst], mid, EMA_ALPHA_SLOW);

    /* RSI */
    double last_mid = d_last_mid[inst];
    if (last_mid == 0.0) last_mid = mid;
    double delta    = mid - last_mid;
    double g        = (delta > 0.0) ? delta : 0.0;
    double l        = (delta < 0.0) ? -delta : 0.0;
    double avg_gain = rsi_cas(&d_avg_gain[inst], g, RSI_ALPHA);
    double avg_loss = rsi_cas(&d_avg_loss[inst], l, RSI_ALPHA);
    *(unsigned long long *)&d_last_mid[inst] =
        (unsigned long long)__double_as_longlong(mid);

    double rs_val = (avg_loss > 1e-12) ? avg_gain / avg_loss : 100.0;
    float  rsi    = (float)(100.0 - 100.0 / (1.0 + rs_val));
    rsi = fmaxf(0.0f, fminf(100.0f, rsi));

    /* EMA crossover signal */
    int8_t ema_sig = 0;
    if (slow_ema > 0.0) {
        double cross = (fast_ema - slow_ema) / slow_ema;
        if (cross >  EMA_CROSS_THRESH) ema_sig = +1;
        if (cross < -EMA_CROSS_THRESH) ema_sig = -1;
    }

    /* RSI signal */
    int8_t rsi_sig = 0;
    if (rsi < RSI_OVERSOLD)   rsi_sig = +1;
    if (rsi > RSI_OVERBOUGHT) rsi_sig = -1;

    /* Combined signal */
    int8_t combined = 0;
    if (ema_sig != 0 && ema_sig == rsi_sig) combined = ema_sig;

    signals[global_tid].combined = combined;
    signals[global_tid].ema_sig  = ema_sig;
    signals[global_tid].rsi_sig  = rsi_sig;
    signals[global_tid].rsi      = rsi;
    signals[global_tid].fast_ema = fast_ema;
    signals[global_tid].slow_ema = slow_ema;
}

/* Host: generate synthetic tick data */
static void generate_ticks(TickMessage *ticks, int n)
{
    for (int i = 0; i < n; ++i) {
        ticks[i].timestamp_ns  = (uint64_t)i * 10000;
        ticks[i].tick_id       = (uint64_t)i;
        ticks[i].instrument_id = (uint16_t)(i % MAX_INSTRUMENTS);
        ticks[i].source        = 0;
        uint32_t rng = (uint32_t)(i * 1664525u + 1013904223u);
        double spread = 0.01 + (double)(rng & 0xFF) * 0.0001;
        double mid    = 150.0 + (double)((int)(rng >> 8) % 1000) * 0.01;
        ticks[i].bid        = mid - spread * 0.5;
        ticks[i].ask        = mid + spread * 0.5;
        ticks[i].last_price = mid;
        ticks[i].volume     = 1.0 + (double)(rng & 0xF);
    }
}

int main(void)
{
    printf("microbench_ema: N_TICKS=%d, MAX_INSTRUMENTS=%d\n",
           N_TICKS, MAX_INSTRUMENTS);
    printf("  Grid: %d blocks x %d threads (%d batches of warp size)\n",
           N_BATCHES, WARP_SIZE, N_BATCHES);

    TickMessage *h_ticks = new TickMessage[N_TICKS];
    generate_ticks(h_ticks, N_TICKS);

    TickMessage *d_ticks   = nullptr;
    SignalOut   *d_signals = nullptr;
    double *d_fast_ema = nullptr, *d_slow_ema = nullptr;
    double *d_avg_gain = nullptr, *d_avg_loss = nullptr, *d_last_mid = nullptr;

    size_t tick_sz   = N_TICKS         * sizeof(TickMessage);
    size_t signal_sz = N_TICKS         * sizeof(SignalOut);
    size_t state_sz  = MAX_INSTRUMENTS * sizeof(double);

    CUDA_CHECK(cudaMalloc(&d_ticks,    tick_sz));
    CUDA_CHECK(cudaMalloc(&d_signals,  signal_sz));
    CUDA_CHECK(cudaMalloc(&d_fast_ema, state_sz)); CUDA_CHECK(cudaMemset(d_fast_ema, 0, state_sz));
    CUDA_CHECK(cudaMalloc(&d_slow_ema, state_sz)); CUDA_CHECK(cudaMemset(d_slow_ema, 0, state_sz));
    CUDA_CHECK(cudaMalloc(&d_avg_gain, state_sz)); CUDA_CHECK(cudaMemset(d_avg_gain, 0, state_sz));
    CUDA_CHECK(cudaMalloc(&d_avg_loss, state_sz)); CUDA_CHECK(cudaMemset(d_avg_loss, 0, state_sz));
    CUDA_CHECK(cudaMalloc(&d_last_mid, state_sz)); CUDA_CHECK(cudaMemset(d_last_mid, 0, state_sz));

    CUDA_CHECK(cudaMemcpy(d_ticks, h_ticks, tick_sz, cudaMemcpyHostToDevice));

    /* Warm-up run (excluded from ncu replay -- replay uses the 2nd invocation) */
    ema_rsi_kernel<<<N_BATCHES, WARP_SIZE>>>(
        d_ticks, d_fast_ema, d_slow_ema, d_avg_gain, d_avg_loss, d_last_mid,
        d_signals);
    CUDA_CHECK(cudaDeviceSynchronize());

    /* Reset state so the profiled run starts from the same initial conditions */
    CUDA_CHECK(cudaMemset(d_fast_ema, 0, state_sz));
    CUDA_CHECK(cudaMemset(d_slow_ema, 0, state_sz));
    CUDA_CHECK(cudaMemset(d_avg_gain, 0, state_sz));
    CUDA_CHECK(cudaMemset(d_avg_loss, 0, state_sz));
    CUDA_CHECK(cudaMemset(d_last_mid, 0, state_sz));

    /* Profiled run -- ncu instruments this invocation */
    ema_rsi_kernel<<<N_BATCHES, WARP_SIZE>>>(
        d_ticks, d_fast_ema, d_slow_ema, d_avg_gain, d_avg_loss, d_last_mid,
        d_signals);
    CUDA_CHECK(cudaDeviceSynchronize());

    SignalOut *h_signals = new SignalOut[N_TICKS];
    CUDA_CHECK(cudaMemcpy(h_signals, d_signals, signal_sz, cudaMemcpyDeviceToHost));

    int buy = 0, sell = 0, neutral = 0;
    for (int i = 0; i < N_TICKS; ++i) {
        if      (h_signals[i].combined > 0) buy++;
        else if (h_signals[i].combined < 0) sell++;
        else                                neutral++;
    }
    printf("  Results (sanity): buy=%d sell=%d neutral=%d  (total=%d)\n",
           buy, sell, neutral, N_TICKS);
    printf("  Sample: tick[1000] rsi=%.2f fast_ema=%.4f slow_ema=%.4f signal=%d\n",
           h_signals[1000].rsi, h_signals[1000].fast_ema,
           h_signals[1000].slow_ema, (int)h_signals[1000].combined);

    cudaFree(d_ticks);
    cudaFree(d_signals);
    cudaFree(d_fast_ema);
    cudaFree(d_slow_ema);
    cudaFree(d_avg_gain);
    cudaFree(d_avg_loss);
    cudaFree(d_last_mid);
    delete[] h_ticks;
    delete[] h_signals;

    printf("microbench_ema: done.\n");
    return 0;
}
