import argparse
import glob
import os
import time

import pandas as pd

try:
    import cupy as cp
except Exception as exc:
    raise SystemExit(
        "CuPy is required. Install a CUDA-specific build, e.g. "
        "`pip install cupy-cuda12x`."
    ) from exc


def load_batches(head_n: int, dt: int):
    file_list = glob.glob("*.csv")
    print(file_list)

    trades_data = []
    for file in file_list:
        symbol = os.path.basename(file).split("-")[0]
        df = pd.read_csv(
            file,
            header=None,
            names=[
                "id",
                "price",
                "qty",
                "quote_qty",
                "time",
                "is_buyer_maker",
                "is_best_match",
            ],
        )
        df["symbol"] = symbol
        trades_data.append(df.head(head_n))

    if not trades_data:
        return []

    all_trades = pd.concat(trades_data, ignore_index=True)
    all_trades.sort_values("time", inplace=True)

    window_start = all_trades["time"].min()
    all_trades["bin"] = (all_trades["time"] - window_start) // dt

    return [g for _, g in all_trades.groupby(["bin"])]


def decide_orders_batch(prices_cp, thr: float, qty: float) -> int:
    n = prices_cp.size
    if n == 0:
        return 0

    pprev = cp.empty_like(prices_cp)
    pprev[0] = prices_cp[0]
    pprev[1:] = prices_cp[:-1]

    ret = (prices_cp - pprev) / pprev
    ret[0] = 0.0

    side = cp.where(ret > thr, 1, cp.where(ret < -thr, -1, 0)).astype(cp.int8)
    _ = cp.where(side != 0, qty, 0.0).astype(cp.float32)  # oqty, unused here

    return int(cp.count_nonzero(side).get())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--thr", type=float, default=0.0008)
    parser.add_argument("--qty", type=float, default=1.0)
    parser.add_argument("--dt", type=int, default=1000)
    parser.add_argument("--head", type=int, default=5)
    args = parser.parse_args()
    gpu_check()

    batches = load_batches(args.head, args.dt)
    total_n = sum(len(b) for b in batches)

    t0 = time.perf_counter()
    total_orders = 0

    for batch in batches:
        prices = batch["price"].to_numpy(dtype="float32", copy=False)
        prices_cp = cp.asarray(prices)
        total_orders += decide_orders_batch(prices_cp, args.thr, args.qty)

    cp.cuda.Stream.null.synchronize()
    ms = (time.perf_counter() - t0) * 1000.0

    print(f"Total orders fired: {total_orders}")
    print(f"Total time: {ms:.3f} ms")
    if ms > 0:
        print(f"End-to-end throughput: {total_n / (ms * 1e6):.6f} GEvents/s")


if __name__ == "__main__":
    main()

def gpu_check():
    device = cp.cuda.Device()
    props = cp.cuda.runtime.getDeviceProperties(device.id)
    name = props["name"].decode("utf-8")
    x = cp.empty((1,), dtype=cp.float32)
    print(f"Using GPU {device.id}: {name}")
    print(f"Allocation device: {x.device}")