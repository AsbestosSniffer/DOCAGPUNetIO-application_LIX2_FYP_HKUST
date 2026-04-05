#!/usr/bin/env python3
"""
benchmark_suite.py — run the ingress comparison benchmark suite.

This script orchestrates the existing C++ benchmark harness across the
kernel baseline, DPDK, RDMA, GPU-RDMA, and GPUNetIO tiers. It runs
repeatable rate sweeps, copies workload CSVs into the harness input path,
collects per-workload benchmark CSVs, and produces comparison summaries.

Usage:
  python scripts/benchmark_suite.py
  python scripts/benchmark_suite.py --real-csv data/ticks.csv --reps 10 --min-events 10000000
  python scripts/benchmark_suite.py --dashboard
"""

import argparse
import csv
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from math import ceil
from pathlib import Path


TIER_LABELS = {
    1: "T1 CPU naive",
    2: "T2 DPDK",
    3: "T3 GPU RDMA",
    4: "T4 GPUNetIO",
    5: "T5 GPUNetIO+DPU",
}

DEFAULT_RATES = [10000, 100000, 200000, 500000, 1000000]
STRESS_RATES = [2000000]
ALL_TIERS = [1, 2, 3, 4, 5]
GPUNETIO_TIERS = [4, 5]


@dataclass
class Summary:
    runs: int = 0
    total_ticks: int = 0
    drop_rates: list[float] = None
    e2e_p50: list[float] = None
    e2e_p95: list[float] = None
    e2e_p99: list[float] = None
    throughput: list[float] = None

    def __post_init__(self):
        self.drop_rates = []
        self.e2e_p50 = []
        self.e2e_p95 = []
        self.e2e_p99 = []
        self.throughput = []

    def add_row(self, row):
        self.runs += 1
        self.total_ticks += int(row["n_ticks"])
        self.drop_rates.append(float(row["drop_rate"]))
        self.e2e_p50.append(float(row["e2e_p50_us"]))
        self.e2e_p95.append(float(row["e2e_p95_us"]))
        self.e2e_p99.append(float(row["e2e_p99_us"]))
        self.throughput.append(float(row["throughput_per_sec"]))

    def average(self, values):
        return sum(values) / len(values) if values else 0.0

    def summary(self):
        return {
            "runs": self.runs,
            "total_ticks": self.total_ticks,
            "avg_drop_rate": self.average(self.drop_rates),
            "avg_e2e_p50": self.average(self.e2e_p50),
            "avg_e2e_p95": self.average(self.e2e_p95),
            "avg_e2e_p99": self.average(self.e2e_p99),
            "avg_throughput": self.average(self.throughput),
        }


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run the full ingress benchmarking suite for this project")
    parser.add_argument("--build-dir", default=".",
                        help="Build directory containing benchmark_harness (default: project root)")
    parser.add_argument("--real-csv", default=None,
                        help="Path to a real-market replay CSV for the real workload")
    parser.add_argument("--csv-dir", default="data",
                        help="Directory used for benchmark harness CSV input")
    parser.add_argument("--results-dir", default="results/benchmarks",
                        help="Directory to store benchmark outputs")
    parser.add_argument("--rates", default=','.join(str(r) for r in DEFAULT_RATES),
                        help="Comma-separated fixed-rate sweep for all tiers")
    parser.add_argument("--stress-rates", default=','.join(str(r) for r in STRESS_RATES),
                        help="Comma-separated stress-only rates for GPUNetIO tiers")
    parser.add_argument("--tiers", default=','.join(str(t) for t in ALL_TIERS),
                        help="Comma-separated tiers for normal sweep")
    parser.add_argument("--stress-tiers", default=','.join(str(t) for t in GPUNETIO_TIERS),
                        help="Comma-separated tiers for stress-only runs")
    parser.add_argument("--reps", type=int, default=10,
                        help="Repetitions per rate/tier combination")
    parser.add_argument("--warmup", type=int, default=5,
                        help="Warmup seconds per run")
    parser.add_argument("--min-events", type=int, default=10000000,
                        help="Minimum events per run; duration will be computed from the slowest rate")
    parser.add_argument("--duration", type=int, default=120,
                        help="Minimum measurement duration in seconds")
    parser.add_argument("--workloads", default="real,synthetic",
                        help="Comma-separated workload names to run")
    parser.add_argument("--dashboard", action="store_true",
                        help="Generate dashboard plots after benchmark completion")
    parser.add_argument("--skip-harness", action="store_true",
                        help="Skip benchmark execution and only summarize existing results")
    return parser.parse_args()


def run_command(cmd, cwd=None):
    print("[cmd]", " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def synthesize_csv(target_path: Path, rows: int = 10_000_000, symbols: int = 10):
    print(f"Generating synthetic workload CSV ({rows:,} rows, {symbols} symbols) -> {target_path}")
    target_path.parent.mkdir(parents=True, exist_ok=True)

    symbols = min(max(symbols, 1), 10)
    mids = [1000.0 + 500.0 * i for i in range(symbols)]
    spreads = [mid * 0.0002 for mid in mids]
    prices = list(mids)

    with target_path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp_ns", "instrument_id", "bid", "ask", "last_price", "volume"])

        t_ns = 0
        interval_ns = 100_000  # 100µs between synthetic ticks
        for i in range(rows):
            instrument_id = i % symbols
            bid_mid = prices[instrument_id]
            bid_mid *= 1.0 + 0.0001 * (0.5 - (i % 100) / 100.0)
            prices[instrument_id] = bid_mid
            spread = spreads[instrument_id]
            bid = bid_mid - spread * 0.5
            ask = bid_mid + spread * 0.5
            last = bid_mid + (spread * 0.1) * ((i % 3) - 1)
            volume = 1.0 + ((i % 10) * 0.1)
            writer.writerow([t_ns, instrument_id, f"{bid:.8f}", f"{ask:.8f}", f"{last:.8f}", f"{volume:.6f}"])
            t_ns += interval_ns


def prepare_workload_csv(workload: str, real_csv: Path, workdir: Path) -> Path:
    workdir.mkdir(parents=True, exist_ok=True)
    target_csv = workdir / "ticks.csv"

    if workload == "real":
        if real_csv is None or not real_csv.exists():
            raise FileNotFoundError(
                "Real workload selected but --real-csv was not provided or does not exist")
        print(f"Preparing real workload CSV from {real_csv}")
        shutil.copy(real_csv, target_csv)

    elif workload == "synthetic":
        synthesize_csv(target_csv, rows=10_000_000, symbols=10)

    else:
        raise ValueError(f"Unknown workload: {workload}")

    return target_csv


def parse_csv_list(value: str):
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_int_list(value: str):
    return [int(item) for item in parse_csv_list(value)]


def compute_duration(min_events: int, rates: list[int], base_duration: int) -> int:
    min_rate = min(rates)
    expected_duration = ceil(min_events / float(min_rate))
    return max(base_duration, expected_duration)


def run_harness(build_dir: Path, csv_dir: Path, results_path: Path,
                rates: list[int], tiers: list[int], warmup: int,
                duration: int, reps: int):
    candidates = [build_dir / "benchmark_harness",
                  build_dir / "bin" / "benchmark_harness",
                  Path("bin") / "benchmark_harness"]
    harness = next((p for p in candidates if p.exists()), None)
    if harness is None:
        raise FileNotFoundError(
            f"benchmark_harness not found in {build_dir}, {build_dir / 'bin'}, or bin/")

    args = [str(harness),
            "--csv-dir", str(csv_dir),
            "--results", str(results_path),
            "--warmup", str(warmup),
            "--duration", str(duration),
            "--rates", ','.join(str(r) for r in rates),
            "--tiers", ','.join(str(t) for t in tiers),
            "--reps", str(reps)]

    print(f"\nRunning harness: tiers={tiers} rates={rates} reps={reps} duration={duration}s\n")
    run_command(args, cwd=build_dir)


def read_results(results_path: Path):
    if not results_path.exists():
        raise FileNotFoundError(f"Benchmark results not found: {results_path}")

    with results_path.open(newline="") as f:
        reader = csv.DictReader(f)
        return [row for row in reader]


def aggregate_summary(rows):
    summaries = defaultdict(Summary)
    for row in rows:
        tier = int(row["tier"])
        summaries[tier].add_row(row)
    return {tier: summary.summary() for tier, summary in summaries.items()}


def print_summary(summaries, label: str):
    print(f"\n=== Summary for {label} ===")
    baseline = summaries.get(1, {}).get("avg_e2e_p50", None)
    print("Tier  Name                Runs  Drop%   p50_us   p95_us   p99_us   thpt_k/s  speedup")
    print("----- ------------------  ----  ------  -------  -------  -------  --------  -------")
    for tier in sorted(summaries):
        s = summaries[tier]
        speedup = baseline / s["avg_e2e_p50"] if baseline and s["avg_e2e_p50"] else 0.0
        print(f"{tier:<5} {TIER_LABELS.get(tier,'T'+str(tier)):<18} {s['runs']:>4} "
              f"{s['avg_drop_rate']*100:>6.2f}  {s['avg_e2e_p50']:>7.1f}  "
              f"{s['avg_e2e_p95']:>7.1f}  {s['avg_e2e_p99']:>7.1f}  "
              f"{s['avg_throughput']/1000:>8.2f}  {speedup:>7.2f}x")


def save_summary_csv(summaries, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["tier", "name", "runs", "avg_drop_rate",
                         "avg_e2e_p50_us", "avg_e2e_p95_us", "avg_e2e_p99_us",
                         "avg_throughput_per_sec", "speedup_vs_T1"])
        baseline = summaries.get(1, {}).get("avg_e2e_p50", None)
        for tier in sorted(summaries):
            s = summaries[tier]
            speedup = baseline / s["avg_e2e_p50"] if baseline and s["avg_e2e_p50"] else 0.0
            writer.writerow([
                tier,
                TIER_LABELS.get(tier, f"T{tier}"),
                s["runs"],
                f"{s['avg_drop_rate']:.6f}",
                f"{s['avg_e2e_p50']:.3f}",
                f"{s['avg_e2e_p95']:.3f}",
                f"{s['avg_e2e_p99']:.3f}",
                f"{s['avg_throughput']:.3f}",
                f"{speedup:.3f}",
            ])


def run_dashboard(results_path: Path, out_dir: Path):
    dashboard = Path("src/dashboard/dashboard.py")
    if not dashboard.exists():
        raise FileNotFoundError(f"Dashboard script not found: {dashboard}")
    print(f"Running dashboard for {results_path} -> {out_dir}")
    run_command([sys.executable, str(dashboard),
                 "--results", str(results_path),
                 "--out", str(out_dir)])


def main():
    args = parse_args()
    build_dir = Path(args.build_dir).resolve()
    if not build_dir.exists():
        fallback = Path('.').resolve()
        print(f"[warning] build dir {build_dir} does not exist, falling back to {fallback}")
        build_dir = fallback
    base_results_dir = Path(args.results_dir).resolve()
    csv_dir = Path(args.csv_dir).resolve()
    real_csv = Path(args.real_csv).resolve() if args.real_csv else None
    workloads = parse_csv_list(args.workloads)
    rates = parse_int_list(args.rates)
    stress_rates = parse_int_list(args.stress_rates)
    tiers = parse_int_list(args.tiers)
    stress_tiers = parse_int_list(args.stress_tiers)

    if not args.skip_harness:
        for workload in workloads:
            workload_dir = base_results_dir / workload
            workload_dir.mkdir(parents=True, exist_ok=True)
            print(f"\n=== Workload: {workload} ===")
            workload_csv = prepare_workload_csv(workload, real_csv, workload_dir / "csv")
            csv_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy(workload_csv, csv_dir / "ticks.csv")

            duration = compute_duration(args.min_events, rates, args.duration)
            run_harness(build_dir, csv_dir, workload_dir / "benchmark.csv",
                        rates, tiers, args.warmup, duration, args.reps)

            if stress_rates and stress_tiers:
                stress_duration = max(args.duration, ceil(args.min_events / float(min(stress_rates))))
                run_harness(build_dir, csv_dir, workload_dir / "benchmark_stress.csv",
                            stress_rates, stress_tiers, args.warmup, stress_duration, args.reps)

    for workload in workloads:
        workload_dir = base_results_dir / workload
        for file_label, results_file in [("benchmark", workload_dir / "benchmark.csv"),
                                         ("stress", workload_dir / "benchmark_stress.csv")]:
            if results_file.exists():
                rows = read_results(results_file)
                summaries = aggregate_summary(rows)
                print_summary(summaries, f"{workload}/{file_label}")
                save_summary_csv(summaries, workload_dir / f"summary_{file_label}.csv")
                if args.dashboard:
                    run_dashboard(results_file, workload_dir / f"plots_{file_label}")
            else:
                print(f"Skipping missing results file: {results_file}")

    print("\nBenchmark suite complete.")


if __name__ == "__main__":
    main()
