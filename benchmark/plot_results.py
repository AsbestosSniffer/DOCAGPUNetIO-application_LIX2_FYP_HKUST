#!/usr/bin/env python3
"""
FYP Benchmark Plotter — CPU vs GPU RDMA vs DOCA GPUNetIO
Reads CSV from run_benchmarks.sh and generates comparison charts.

Usage:
    python3 plot_results.py results/benchmark_*.csv
"""

import sys
import csv
import os

def load_csv(path):
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows

def print_table(rows):
    """ASCII table output (no matplotlib dependency needed)"""
    if not rows:
        print("No data found.")
        return

    headers = list(rows[0].keys())
    widths = [max(len(h), max(len(str(r.get(h, ""))) for r in rows)) for h in headers]

    # Header
    line = " | ".join(h.ljust(w) for h, w in zip(headers, widths))
    print(line)
    print("-+-".join("-" * w for w in widths))

    # Rows
    for r in rows:
        line = " | ".join(str(r.get(h, "")).ljust(w) for h, w in zip(headers, widths))
        print(line)

def main():
    if len(sys.argv) < 2:
        # Find most recent CSV
        results_dir = os.path.join(os.path.dirname(__file__), "results")
        csvs = sorted([f for f in os.listdir(results_dir) if f.endswith(".csv")])
        if not csvs:
            print("No CSV files found. Run ./run_benchmarks.sh first.")
            return
        path = os.path.join(results_dir, csvs[-1])
    else:
        path = sys.argv[1]

    print(f"\nLoading: {path}\n")
    rows = load_csv(path)
    print_table(rows)

    # Try matplotlib if available
    try:
        import matplotlib.pyplot as plt
        import numpy as np

        systems = sorted(set(r["system"] for r in rows))
        batch_sizes = sorted(set(int(r["batch_size"]) for r in rows))

        fig, axes = plt.subplots(1, 2, figsize=(14, 6))

        # Latency comparison
        ax = axes[0]
        for sys_name in systems:
            bs_vals = []
            lat_vals = []
            for bs in batch_sizes:
                matching = [r for r in rows if r["system"] == sys_name and int(r["batch_size"]) == bs]
                if matching:
                    bs_vals.append(bs)
                    lat_vals.append(float(matching[0].get("lat_p99_us", 0)))
            ax.plot(bs_vals, lat_vals, "o-", label=sys_name)
        ax.set_xlabel("Batch Size")
        ax.set_ylabel("p99 Latency (us)")
        ax.set_title("Latency: CPU vs GPU RDMA vs DOCA")
        ax.set_xscale("log")
        ax.legend()
        ax.grid(True, alpha=0.3)

        # Throughput comparison
        ax = axes[1]
        for sys_name in systems:
            bs_vals = []
            tp_vals = []
            for bs in batch_sizes:
                matching = [r for r in rows if r["system"] == sys_name and int(r["batch_size"]) == bs]
                if matching:
                    bs_vals.append(bs)
                    tp_vals.append(float(matching[0].get("throughput_evps", 0)))
            ax.plot(bs_vals, tp_vals, "s-", label=sys_name)
        ax.set_xlabel("Batch Size")
        ax.set_ylabel("Throughput (events/sec)")
        ax.set_title("Throughput: CPU vs GPU RDMA vs DOCA")
        ax.set_xscale("log")
        ax.legend()
        ax.grid(True, alpha=0.3)

        plt.tight_layout()
        out_path = path.replace(".csv", ".png")
        plt.savefig(out_path, dpi=150)
        print(f"\nChart saved: {out_path}")
        plt.show()

    except ImportError:
        print("\nmatplotlib not available — showing ASCII table only.")
        print("Install with: pip3 install matplotlib")

if __name__ == "__main__":
    main()
