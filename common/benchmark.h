#pragma once
#include <cstdint>
#include <cstdio>
#include <cmath>
#include <algorithm>
#include <vector>
#include <chrono>
#include <string>

/* ─── High-Resolution Timer ───────────────────────────────────────────── */

static inline uint64_t now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* ─── Latency Histogram ──────────────────────────────────────────────── */

struct LatencyStats {
    std::vector<double> samples_us; // microseconds

    void record(uint64_t start_ns, uint64_t end_ns) {
        double us = (double)(end_ns - start_ns) / 1000.0;
        samples_us.push_back(us);
    }

    void record_us(double us) {
        samples_us.push_back(us);
    }

    void compute(double* p50, double* p99, double* p999, double* mean, double* stddev) const {
        if (samples_us.empty()) {
            *p50 = *p99 = *p999 = *mean = *stddev = 0;
            return;
        }
        std::vector<double> sorted = samples_us;
        std::sort(sorted.begin(), sorted.end());
        int n = (int)sorted.size();

        *p50  = sorted[(int)(n * 0.50)];
        *p99  = sorted[(int)(n * 0.99)];
        *p999 = sorted[std::min(n - 1, (int)(n * 0.999))];

        double sum = 0;
        for (double v : sorted) sum += v;
        *mean = sum / n;

        double var = 0;
        for (double v : sorted) var += (v - *mean) * (v - *mean);
        *stddev = sqrt(var / n);
    }

    void print(const char* label) const {
        double p50, p99, p999, mean, stddev;
        compute(&p50, &p99, &p999, &mean, &stddev);
        printf("[%s] samples=%zu  mean=%.1f us  p50=%.1f  p99=%.1f  p999=%.1f  stddev=%.1f\n",
               label, samples_us.size(), mean, p50, p99, p999, stddev);
    }
};

/* ─── Throughput Meter ───────────────────────────────────────────────── */

struct ThroughputMeter {
    uint64_t total_events;
    uint64_t total_batches;
    uint64_t start_ns;

    ThroughputMeter() : total_events(0), total_batches(0), start_ns(now_ns()) {}

    void add_batch(int n_events) {
        total_events += n_events;
        total_batches++;
    }

    double events_per_sec() const {
        uint64_t elapsed = now_ns() - start_ns;
        if (elapsed == 0) return 0;
        return (double)total_events / ((double)elapsed / 1e9);
    }

    void print(const char* label) const {
        printf("[%s] %lu events in %lu batches  %.0f ev/s\n",
               label, total_events, total_batches, events_per_sec());
    }
};

/* ─── Benchmark Result (for CSV export) ──────────────────────────────── */

struct BenchmarkResult {
    std::string system;       // "cpu", "gpu_rdma", "gpu_doca"
    int n_symbols;
    int batch_size;
    double latency_p50_us;
    double latency_p99_us;
    double latency_p999_us;
    double latency_mean_us;
    double throughput_evps;
    double cpu_util_pct;

    void print_csv_header(FILE* f) const {
        fprintf(f, "system,n_symbols,batch_size,lat_p50_us,lat_p99_us,lat_p999_us,lat_mean_us,throughput_evps,cpu_util_pct\n");
    }

    void print_csv_row(FILE* f) const {
        fprintf(f, "%s,%d,%d,%.1f,%.1f,%.1f,%.1f,%.0f,%.1f\n",
                system.c_str(), n_symbols, batch_size,
                latency_p50_us, latency_p99_us, latency_p999_us,
                latency_mean_us, throughput_evps, cpu_util_pct);
    }
};
