#!/usr/bin/env python3
"""
analyze.py — Post-run profiling analysis for the DOCA GPUNetIO pipeline.

Reads the CSV files produced by the instrumented application and generates
the figures needed for the hardware profiling report:

  1. Throughput time series (profiling_stats.csv)
  2. Intra-kernel timing breakdown: NIC wait / compute / semaphore write
     (profiling_timing_udp.csv, profiling_timing_tcp.csv)
  3. Scalability: throughput vs queue count (if multiple stats CSVs supplied)

Usage:
  python3 analyze.py [--stats FILE] [--timing-udp FILE] [--timing-tcp FILE]
                     [--gpu-clock-mhz N] [--outdir DIR]

  --stats          profiling_stats.csv from one run (default: profiling_stats.csv)
  --timing-udp     profiling_timing_udp.csv (default: profiling_timing_udp.csv)
  --timing-tcp     profiling_timing_tcp.csv (default: profiling_timing_tcp.csv)
  --gpu-clock-mhz  GPU SM clock in MHz for cycle→µs conversion (default: 1695
                   for NVIDIA A2 boost clock)
  --outdir         directory to write PNG files (default: profiling_plots/)
"""

import argparse
import os
import sys

import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
except ImportError:
    print("matplotlib not found — install with: pip install matplotlib")
    sys.exit(1)

try:
    import pandas as pd
except ImportError:
    print("pandas not found — install with: pip install pandas")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def cycles_to_us(cycles, gpu_clock_mhz):
    """Convert GPU clock64() cycle delta to microseconds."""
    return cycles / gpu_clock_mhz


def save(fig, path, outdir):
    os.makedirs(outdir, exist_ok=True)
    full = os.path.join(outdir, path)
    fig.savefig(full, dpi=150, bbox_inches="tight")
    print(f"  Saved {full}")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Plot 1: Throughput time series
# ---------------------------------------------------------------------------

def plot_throughput(stats_csv, outdir):
    print(f"[1] Throughput time series from {stats_csv}")
    try:
        df = pd.read_csv(stats_csv)
    except FileNotFoundError:
        print(f"    File not found: {stats_csv} — skipping.")
        return

    fig, axes = plt.subplots(2, 1, figsize=(10, 6), sharex=True)

    axes[0].plot(df["elapsed_sec"], df["udp_total"], label="UDP total", color="tab:blue")
    axes[0].plot(df["elapsed_sec"], df["udp_dns"],   label="UDP DNS",   color="tab:orange", linestyle="--")
    axes[0].set_ylabel("Packets / sec")
    axes[0].set_title("UDP Throughput (per second)")
    axes[0].legend(fontsize=8)
    axes[0].grid(True, alpha=0.3)

    axes[1].plot(df["elapsed_sec"], df["tcp_total"],    label="TCP total",    color="tab:green")
    axes[1].plot(df["elapsed_sec"], df["tcp_http"],     label="TCP HTTP",     color="tab:red",    linestyle="--")
    axes[1].plot(df["elapsed_sec"], df["tcp_http_get"], label="TCP HTTP GET", color="tab:purple", linestyle=":")
    axes[1].plot(df["elapsed_sec"], df["tcp_syn"],      label="TCP SYN",      color="tab:brown",  linestyle="-.")
    axes[1].set_ylabel("Packets / sec")
    axes[1].set_xlabel("Elapsed time (s)")
    axes[1].set_title("TCP Throughput (per second)")
    axes[1].legend(fontsize=8)
    axes[1].grid(True, alpha=0.3)

    fig.tight_layout()
    save(fig, "throughput_timeseries.png", outdir)


# ---------------------------------------------------------------------------
# Plot 2: Intra-kernel timing breakdown (stacked bar)
# ---------------------------------------------------------------------------

def plot_timing_breakdown(timing_csv, protocol, gpu_clock_mhz, outdir):
    print(f"[2] Intra-kernel timing breakdown ({protocol}) from {timing_csv}")
    try:
        df = pd.read_csv(timing_csv)
    except FileNotFoundError:
        print(f"    File not found: {timing_csv} — skipping.")
        return

    # Convert cycles to microseconds
    for col in ["nic_wait_cycles", "compute_cycles", "semaphore_cycles"]:
        df[col.replace("_cycles", "_us")] = cycles_to_us(df[col], gpu_clock_mhz)

    nic_wait = df["nic_wait_us"]
    compute  = df["compute_us"]
    sem      = df["semaphore_us"]

    labels = ["NIC wait", "Payload compute", "Semaphore write"]
    means  = [nic_wait.mean(), compute.mean(), sem.mean()]
    p99s   = [np.percentile(nic_wait, 99), np.percentile(compute, 99), np.percentile(sem, 99)]

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    # Left: stacked bar (mean breakdown)
    bottom = 0
    colors = ["#4878cf", "#6acc65", "#d65f5f"]
    x = [0]
    for label, mean, color in zip(labels, means, colors):
        axes[0].bar(x, mean, bottom=bottom, label=f"{label} ({mean:.2f} µs)", color=color, width=0.5)
        bottom += mean
    axes[0].set_xticks(x)
    axes[0].set_xticklabels([f"{protocol} kernel"])
    axes[0].set_ylabel("Mean latency (µs)")
    axes[0].set_title(f"{protocol} Kernel — Mean Stage Breakdown")
    axes[0].legend(fontsize=9)
    axes[0].grid(True, axis="y", alpha=0.3)

    # Right: CDF of per-iteration total latency
    total_us = nic_wait + compute + sem
    sorted_total = np.sort(total_us)
    cdf = np.arange(1, len(sorted_total) + 1) / len(sorted_total)
    axes[1].plot(sorted_total, cdf * 100, color="tab:blue")
    axes[1].axvline(np.percentile(total_us, 50), color="gray",   linestyle="--", label="p50")
    axes[1].axvline(np.percentile(total_us, 99), color="red",    linestyle="--", label="p99")
    axes[1].set_xlabel("Total iteration latency (µs)")
    axes[1].set_ylabel("CDF (%)")
    axes[1].set_title(f"{protocol} Kernel — Per-Iteration Latency CDF")
    axes[1].legend(fontsize=9)
    axes[1].grid(True, alpha=0.3)

    fig.suptitle(f"{protocol} CUDA Kernel — Intra-Kernel Timing  (GPU clock: {gpu_clock_mhz} MHz)", y=1.01)
    fig.tight_layout()
    save(fig, f"timing_breakdown_{protocol.lower()}.png", outdir)

    # Print summary table
    print(f"\n  {protocol} kernel stage summary (µs):")
    print(f"  {'Stage':<20} {'Mean':>8} {'p50':>8} {'p99':>8} {'Max':>8}")
    print(f"  {'-'*52}")
    for label, col in zip(labels, [nic_wait, compute, sem]):
        print(f"  {label:<20} {col.mean():>8.2f} {np.percentile(col,50):>8.2f} "
              f"{np.percentile(col,99):>8.2f} {col.max():>8.2f}")
    total = nic_wait + compute + sem
    print(f"  {'Total':<20} {total.mean():>8.2f} {np.percentile(total,50):>8.2f} "
          f"{np.percentile(total,99):>8.2f} {total.max():>8.2f}")
    print()


# ---------------------------------------------------------------------------
# Plot 3: NIC-wait fraction vs compute fraction over time
# ---------------------------------------------------------------------------

def plot_wait_fraction(timing_csv, protocol, gpu_clock_mhz, outdir):
    print(f"[3] NIC-wait fraction over iterations ({protocol})")
    try:
        df = pd.read_csv(timing_csv)
    except FileNotFoundError:
        return

    for col in ["nic_wait_cycles", "compute_cycles", "semaphore_cycles"]:
        df[col.replace("_cycles", "_us")] = cycles_to_us(df[col], gpu_clock_mhz)

    total = df["nic_wait_us"] + df["compute_us"] + df["semaphore_us"]
    wait_frac    = df["nic_wait_us"] / total * 100
    compute_frac = df["compute_us"]  / total * 100
    sem_frac     = df["semaphore_us"]/ total * 100

    # Smooth with a rolling window for readability
    win = max(1, len(df) // 50)
    fig, ax = plt.subplots(figsize=(11, 4))
    ax.stackplot(df["slot"],
                 wait_frac.rolling(win, min_periods=1).mean(),
                 compute_frac.rolling(win, min_periods=1).mean(),
                 sem_frac.rolling(win, min_periods=1).mean(),
                 labels=["NIC wait", "Payload compute", "Semaphore write"],
                 colors=["#4878cf", "#6acc65", "#d65f5f"],
                 alpha=0.85)
    ax.set_xlabel("Batch iteration")
    ax.set_ylabel("Fraction of iteration time (%)")
    ax.set_title(f"{protocol} Kernel — Time Composition per Batch")
    ax.legend(loc="upper right", fontsize=9)
    ax.set_ylim(0, 100)
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    save(fig, f"wait_fraction_{protocol.lower()}.png", outdir)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="DOCA GPUNetIO profiling analysis")
    parser.add_argument("--stats",        default="profiling_stats.csv")
    parser.add_argument("--timing-udp",   default="profiling_timing_udp.csv")
    parser.add_argument("--timing-tcp",   default="profiling_timing_tcp.csv")
    parser.add_argument("--gpu-clock-mhz", type=float, default=1695.0,
                        help="GPU SM clock in MHz (default: 1695 for NVIDIA A2 boost)")
    parser.add_argument("--outdir",       default="profiling_plots")
    args = parser.parse_args()

    print(f"GPU clock assumed: {args.gpu_clock_mhz} MHz")
    print(f"Output directory : {args.outdir}\n")

    plot_throughput(args.stats, args.outdir)

    for proto, csv_path in [("UDP", args.timing_udp), ("TCP", args.timing_tcp)]:
        plot_timing_breakdown(csv_path, proto, args.gpu_clock_mhz, args.outdir)
        plot_wait_fraction(csv_path, proto, args.gpu_clock_mhz, args.outdir)

    print("Done. Figures written to", args.outdir)


if __name__ == "__main__":
    main()
