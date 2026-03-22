#!/bin/bash
mkdir -p data/bin
for symbol in BTCUSDT ETHUSDT BNBUSDT SOLUSDT XRPUSDT ADAUSDT DOGEUSDT TRXUSDT AVAXUSDT DOTUSDT; do
    echo "Converting $symbol..."
    for csv in data/raw/$symbol/*.csv; do
        if [ -f "$csv" ]; then
            date=$(basename "$csv" .csv)
            ./csv_to_bin_converter "$csv" "$symbol" "data/bin/${symbol,,}_${date}.bin"
        fi
    done
done
echo "Done!"
