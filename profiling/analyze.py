#!/usr/bin/env python3
"""
analyze.py -- Post-run profiling analysis for the DOCA GPUNetIO pipeline.

Reads the CSV produced by benchmark_harness (bench results) and the
profiling_timing_gpu.csv written by gpu_receiver on shutdown, then generates
the figures needed for the hardware profiling report.

Plots produced:
  1. E2E latency CDF -- T1 vs T4 at 100k ticks/sec
  2. E2E latency vs offered rate (p50 and p99) -- T1 vs T4
  3. Stage breakdown stacked bar -- ingest / compute / egress per tier per rate
  4. NIC-wait histogram -- per-burst NIC wait cycles from profiling_timing_gpu.csv
  5. Throughput vs offered rate -- T1 vs T4

Usage:
  python3 profiling/analyze.py \\
      --bench  results/benchmark_YYYYMMDD_HHMMSS.csv \\
      --timing profiling_out/profiling_timing_gpu.csv \\
      --outdir profiling_out/plots/

  --bench          Path to benchmark_harness results CSV (required for plots 1-3, 5)
  --timing         Path to profiling_timing_gpu.csv from gpu_receiver (required for plot 4)
  --gpu-clock-mhz  GPU SM clock in MHz (default: 1695 for NVIDIA A2 boost clock)
  --outdir         Directory to write PNG files (default: profiling_plots/)
"""

import argparse
import os
import sys

import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    print("matplotlib not found -- install with: pip install matplotlib")
    sys.exit(1)

try:
    import pandas as pd
except ImportError:
    print("pandas not found -- install with: pip install pandas")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def save(fig, filename, outdir):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    print(f"  Saved {path}")
    plt.close(fig)


def ns_to_us(ns):
    return ns / 1e3


def cycles_to_us(cycles, gpu_clock_mhz):
    return cycles / gpu_clock_mhz


def load_bench(bench_csv):
    """Load benchmark_harness CSV. Expected columns (subset):
       tier, rate, tick_id, t1_ns, t2_ns, t3_ns, t4_ns, compute_ns,
       e2e_ns, ingest_ns
    """
    try:
        df = pd.read_csv(bench_csv)
    except FileNotFoundError:
        print(f"  File not found: {bench_csv}")
        return None

    # Normalise column names (strip whitespace)
    df.columns = df.columns.str.strip()

    required = {"tier", "t1_ns", "t2_ns", "t3_ns", "t4_ns"}
    missing = required - set(df.columns)
    if missing:
        print(f"  Missing columns in {bench_csv}: {missing}")
        print(f"  Available columns: {list(df.columns)}")
        return None

    # Derive columns if not present
    if "e2e_ns" not in df.columns:
        df["e2e_ns"] = df["t4_ns"] - df["t1_ns"]
    if "ingest_ns" not in df.columns:
        df["ingest_ns"] = df["t2_ns"] - df["t1_ns"]
    if "compute_ns" not in df.columns:
        df["compute_ns"] = df["t3_ns"] - df["t2_ns"]
    if "egress_ns" not in df.columns:
        df["egress_ns"] = df["t4_ns"] - df["t3_ns"]

    # Filter out obviously bogus rows (negative latencies from clock drift)
    df = df[(df["e2e_ns"] > 0) & (df["e2e_ns"] < 10_000_000)]  # < 10 ms

    # Derive rate from data if not present (benchmark_harness writes it)
    if "rate" not in df.columns:
        df["rate"] = 0  # unknown

    print(f"  Loaded {len(df)} rows from {bench_csv}")
    print(f"  Tiers present: {sorted(df['tier'].unique())}")
    if "rate" in df.columns:
        print(f"  Rates present: {sorted(df['rate'].unique())}")
    return df


# ---------------------------------------------------------------------------
# Plot 1: E2E latency CDF -- T1 vs T4 at the highest common rate
# ---------------------------------------------------------------------------

def plot_e2e_cdf(df, outdir):
    print("[1] E2E latency CDF")

    tiers = [1, 4]
    colors = {1: "tab:orange", 4: "tab:blue"}
    labels = {1: "T1 (CPU+POSIX)", 4: "T4 (DOCA GPUNetIO)"}

    # Use the highest rate both tiers have in common, or all data if rate unknown
    common_rates = None
    if "rate" in df.columns and df["rate"].max() > 0:
        for t in tiers:
            rates = set(df[df["tier"] == t]["rate"].unique())
            common_rates = rates if common_rates is None else common_rates & rates
        rate = max(common_rates) if common_rates else None
    else:
        rate = None

    fig, ax = plt.subplots(figsize=(8, 5))
    for tier in tiers:
        subset = df[df["tier"] == tier]
        if rate is not None:
            subset = subset[subset["rate"] == rate]
        if len(subset) == 0:
            continue
        latency_us = ns_to_us(subset["e2e_ns"].values)
        sorted_lat = np.sort(latency_us)
        cdf = np.arange(1, len(sorted_lat) + 1) / len(sorted_lat) * 100
        ax.plot(sorted_lat, cdf, color=colors[tier], label=labels[tier], linewidth=1.5)
        for pct, ls in [(50, "--"), (99, ":")]:
            p = np.percentile(latency_us, pct)
            ax.axvline(p, color=colors[tier], linestyle=ls, alpha=0.6,
                       label=f"T{tier} p{pct}={p:.0f} us")

    rate_str = f" @ {rate//1000}k ticks/s" if rate else ""
    ax.set_xlabel("E2E latency (us)")
    ax.set_ylabel("CDF (%)")
    ax.set_title(f"End-to-End Latency CDF -- T1 vs T4{rate_str}")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=0)
    fig.tight_layout()
    save(fig, "e2e_cdf.png", outdir)


# ---------------------------------------------------------------------------
# Plot 2: E2E p50/p99 vs offered rate -- T1 vs T4
# ---------------------------------------------------------------------------

def plot_latency_vs_rate(df, outdir):
    print("[2] Latency vs offered rate")

    if "rate" not in df.columns or df["rate"].max() == 0:
        print("  No rate column -- skipping.")
        return

    tiers = sorted(df["tier"].unique())
    colors = {1: "tab:orange", 2: "tab:green", 3: "tab:purple", 4: "tab:blue", 5: "tab:red"}
    styles_p50 = {1: "-o", 2: "-s", 3: "-^", 4: "-D", 5: "-v"}
    styles_p99 = {1: "--o", 2: "--s", 3: "--^", 4: "--D", 5: "--v"}

    fig, ax = plt.subplots(figsize=(9, 5))
    for tier in tiers:
        sub = df[df["tier"] == tier]
        rates = sorted(sub["rate"].unique())
        p50s, p99s = [], []
        for r in rates:
            lat = ns_to_us(sub[sub["rate"] == r]["e2e_ns"].values)
            p50s.append(np.percentile(lat, 50))
            p99s.append(np.percentile(lat, 99))
        c = colors.get(tier, "black")
        rates_k = [r / 1000 for r in rates]
        ax.plot(rates_k, p50s, styles_p50.get(tier, "-o"), color=c,
                label=f"T{tier} p50", linewidth=1.5)
        ax.plot(rates_k, p99s, styles_p99.get(tier, "--o"), color=c,
                label=f"T{tier} p99", linewidth=1.5, alpha=0.7)

    ax.set_xlabel("Offered rate (k ticks/sec)")
    ax.set_ylabel("E2E latency (us)")
    ax.set_title("E2E Latency vs Offered Rate -- T1 vs T4")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "latency_vs_rate.png", outdir)


# ---------------------------------------------------------------------------
# Plot 3: Stage breakdown stacked bar -- ingest / compute / egress
# ---------------------------------------------------------------------------

def plot_stage_breakdown(df, outdir):
    print("[3] Stage breakdown stacked bar")

    if "rate" not in df.columns or df["rate"].max() == 0:
        print("  No rate column -- skipping stage breakdown.")
        return

    focus_tiers = [t for t in [1, 4] if t in df["tier"].values]
    rates = sorted(df["rate"].unique())
    stages = ["ingest_ns", "compute_ns", "egress_ns"]
    stage_labels = ["Ingest (NIC->GPU)", "Compute (EMA+RSI)", "Egress (ring write)"]
    colors = ["#4878cf", "#6acc65", "#d65f5f"]

    fig, ax = plt.subplots(figsize=(max(8, len(rates) * len(focus_tiers) * 0.8 + 2), 5))

    n_groups = len(rates)
    n_tiers = len(focus_tiers)
    group_w = 0.8
    bar_w = group_w / n_tiers
    tier_labels_map = {1: "T1 (CPU)", 4: "T4 (GPUNetIO)"}

    for ti, tier in enumerate(focus_tiers):
        sub_tier = df[df["tier"] == tier]
        xs = []
        bottoms = np.zeros(n_groups)
        for si, (stage, slabel, color) in enumerate(zip(stages, stage_labels, colors)):
            vals = []
            for ri, rate in enumerate(rates):
                sub = sub_tier[sub_tier["rate"] == rate]
                vals.append(ns_to_us(np.percentile(sub[stage].values, 50))
                            if len(sub) > 0 else 0)
            vals = np.array(vals)
            x = np.arange(n_groups) * (n_tiers + 0.5) + ti * bar_w
            label = slabel if ti == 0 else None
            ax.bar(x, vals, width=bar_w, bottom=bottoms, color=color,
                   label=label, edgecolor="white", linewidth=0.5)
            bottoms += vals
            if si == 0:
                xs = x

        # Annotate tier label at base
        for xi, x_pos in enumerate(xs):
            ax.text(x_pos + bar_w / 2, -2, tier_labels_map.get(tier, f"T{tier}"),
                    ha="center", va="top", fontsize=7, rotation=45)

    # x-axis tick at group centre
    group_centres = np.arange(n_groups) * (n_tiers + 0.5) + (n_tiers - 1) * bar_w / 2
    ax.set_xticks(group_centres)
    ax.set_xticklabels([f"{r//1000}k" for r in rates])
    ax.set_xlabel("Offered rate (ticks/sec)")
    ax.set_ylabel("p50 latency (us)")
    ax.set_title("Stage Latency Breakdown -- T1 vs T4")
    ax.legend(fontsize=8, loc="upper left")
    ax.grid(True, axis="y", alpha=0.3)
    ax.set_ylim(bottom=0)
    fig.tight_layout()
    save(fig, "stage_breakdown.png", outdir)


# ---------------------------------------------------------------------------
# Plot 4: NIC-wait histogram from profiling_timing_gpu.csv
# ---------------------------------------------------------------------------

def plot_nic_wait(timing_csv, gpu_clock_mhz, outdir):
    print(f"[4] NIC-wait histogram from {timing_csv}")
    try:
        df = pd.read_csv(timing_csv)
    except FileNotFoundError:
        print(f"  File not found: {timing_csv} -- skipping.")
        return

    df.columns = df.columns.str.strip()
    if "nic_wait_cycles" not in df.columns:
        print("  nic_wait_cycles column not found -- skipping.")
        return

    wait_us = cycles_to_us(df["nic_wait_cycles"].values, gpu_clock_mhz)
    wait_us = wait_us[wait_us > 0]

    fig, axes = plt.subplots(1, 2, figsize=(12, 4))

    # Histogram (clipped at 99th percentile for readability)
    p99 = np.percentile(wait_us, 99)
    axes[0].hist(wait_us[wait_us <= p99 * 1.5], bins=80, color="tab:blue",
                 edgecolor="white", linewidth=0.3, density=True)
    axes[0].axvline(np.percentile(wait_us, 50), color="black", linestyle="--",
                    label=f"p50 = {np.percentile(wait_us,50):.1f} us")
    axes[0].axvline(p99, color="red", linestyle=":", label=f"p99 = {p99:.1f} us")
    axes[0].set_xlabel("NIC-wait time per burst (us)")
    axes[0].set_ylabel("Density")
    axes[0].set_title("Per-Burst NIC-Wait Distribution (T4)")
    axes[0].legend(fontsize=9)
    axes[0].grid(True, alpha=0.3)

    # CDF
    sorted_w = np.sort(wait_us)
    cdf = np.arange(1, len(sorted_w) + 1) / len(sorted_w) * 100
    axes[1].plot(sorted_w, cdf, color="tab:blue", linewidth=1.5)
    axes[1].axvline(np.percentile(wait_us, 50), color="black", linestyle="--",
                    alpha=0.7, label=f"p50 = {np.percentile(wait_us,50):.1f} us")
    axes[1].axvline(p99, color="red", linestyle=":", alpha=0.7,
                    label=f"p99 = {p99:.1f} us")
    axes[1].set_xlabel("NIC-wait time per burst (us)")
    axes[1].set_ylabel("CDF (%)")
    axes[1].set_title("NIC-Wait CDF (T4)")
    axes[1].legend(fontsize=9)
    axes[1].grid(True, alpha=0.3)
    axes[1].set_xlim(left=0)

    # Print summary
    print(f"  NIC-wait summary  (n={len(wait_us)} bursts, GPU clock {gpu_clock_mhz} MHz):")
    for pct in [50, 90, 99]:
        print(f"    p{pct:>2} = {np.percentile(wait_us, pct):8.2f} us")
    print(f"    mean = {wait_us.mean():8.2f} us   max = {wait_us.max():.2f} us")

    fig.tight_layout()
    save(fig, "nic_wait.png", outdir)


# ---------------------------------------------------------------------------
# Plot 5: Throughput vs offered rate
# ---------------------------------------------------------------------------

def plot_throughput_vs_rate(df, outdir):
    print("[5] Throughput vs offered rate")

    if "rate" not in df.columns or df["rate"].max() == 0:
        print("  No rate column -- skipping.")
        return

    tiers = sorted(df["tier"].unique())
    colors = {1: "tab:orange", 2: "tab:green", 3: "tab:purple", 4: "tab:blue", 5: "tab:red"}

    fig, ax = plt.subplots(figsize=(8, 5))
    for tier in tiers:
        sub = df[df["tier"] == tier]
        rates = sorted(sub["rate"].unique())
        achieved = []
        for r in rates:
            n = len(sub[sub["rate"] == r])
            achieved.append(n)
        fractions = [a / r * 100 if r > 0 else 0
                     for a, r in zip(achieved, rates)]
        ax.plot([r / 1000 for r in rates], fractions,
                "-o", color=colors.get(tier, "black"),
                label=f"T{tier}", linewidth=1.5)

    ax.set_xlabel("Offered rate (k ticks/sec)")
    ax.set_ylabel("Received ticks (% of offered)")
    ax.set_title("Throughput vs Offered Rate -- T1 vs T4")
    ax.set_ylim(0, 110)
    ax.axhline(100, color="gray", linestyle="--", alpha=0.5, label="100% (no drop)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "throughput_vs_rate.png", outdir)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="DOCA GPUNetIO profiling analysis -- generate report figures")
    parser.add_argument("--bench",
        help="Path to benchmark_harness results CSV")
    parser.add_argument("--timing",
        help="Path to profiling_timing_gpu.csv from gpu_receiver")
    parser.add_argument("--gpu-clock-mhz", type=float, default=1695.0,
        help="GPU SM clock in MHz (default: 1695 for NVIDIA A2 boost)")
    parser.add_argument("--outdir", default="profiling_plots",
        help="Directory to write PNG files (default: profiling_plots/)")
    args = parser.parse_args()

    print(f"GPU clock: {args.gpu_clock_mhz} MHz")
    print(f"Output:    {args.outdir}\n")

    df = None
    if args.bench:
        df = load_bench(args.bench)

    if df is not None:
        print()
        plot_e2e_cdf(df, args.outdir)
        plot_latency_vs_rate(df, args.outdir)
        plot_stage_breakdown(df, args.outdir)
        plot_throughput_vs_rate(df, args.outdir)
    elif args.bench:
        print("  Could not load benchmark CSV -- bench plots skipped.")

    if args.timing:
        print()
        plot_nic_wait(args.timing, args.gpu_clock_mhz, args.outdir)
    elif not args.bench:
        print("No inputs provided. Use --bench and/or --timing.")
        parser.print_help()
        sys.exit(1)

    print("\nDone. Figures written to", args.outdir)


if __name__ == "__main__":
    main()
