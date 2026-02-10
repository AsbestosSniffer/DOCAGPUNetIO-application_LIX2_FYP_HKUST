#!/bin/bash
# Binance trades downloader for 10 popular tickers
# Downloads daily trades CSV files from Binance and extracts them

set -e

# Configuration
SYMBOLS=("BTCUSDT" "ETHUSDT" "BNBUSDT" "SOLUSDT" "XRPUSDT" "ADAUSDT" "DOGEUSDT" "TRXUSDT" "AVAXUSDT" "DOTUSDT")
BASE_URL="https://data.binance.vision/data/spot/daily/trades"
OUTPUT_DIR="data/raw"
START_DATE="${1:-2023-01-01}"  # Default to 2023-01-01
END_DATE="${2:-2023-01-31}"    # Default to 2023-01-31

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to convert date (YYYY-MM-DD) to day number
date_to_ordinal() {
    date -d "$1" +%s 2>/dev/null || gdate -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s
}

# Parse start and end dates
start_ts=$(date_to_ordinal "$START_DATE")
end_ts=$(date_to_ordinal "$END_DATE")

echo "Downloading Binance trades from $START_DATE to $END_DATE"
echo "Symbols: ${SYMBOLS[*]}"

# Download for each symbol
for symbol in "${SYMBOLS[@]}"; do
    echo "Downloading $symbol..."
    mkdir -p "$OUTPUT_DIR/$symbol"

    # Download using a date loop
    current_ts=$start_ts
    while [ $current_ts -le $end_ts ]; do
        # Convert timestamp back to date
        date_str=$(date -d @$current_ts +%Y-%m-%d 2>/dev/null || gdate -d @$current_ts +%Y-%m-%d 2>/dev/null || date -j -f "%s" $current_ts +%Y-%m-%d)

        zip_file="$symbol-trades-$date_str.zip"
        download_url="$BASE_URL/$symbol/$zip_file"
        output_file="$OUTPUT_DIR/$symbol/$date_str.csv"

        echo "  Fetching $date_str..."

        # Download with curl, suppress progress
        if curl -s -f -o "/tmp/$zip_file" "$download_url"; then
            # Extract CSV from zip
            unzip -q -j "/tmp/$zip_file" "*.csv" -d "$OUTPUT_DIR/$symbol" 2>/dev/null || true

            # Rename if extracted directly
            if [ -f "$OUTPUT_DIR/$symbol/$symbol-trades-$date_str.csv" ]; then
                mv "$OUTPUT_DIR/$symbol/$symbol-trades-$date_str.csv" "$output_file"
            fi

            rm -f "/tmp/$zip_file"
        else
            echo "    Warning: Failed to download $date_str (may not have data)"
        fi

        # Move to next day (+86400 seconds)
        current_ts=$((current_ts + 86400))
    done
done

echo "Download complete! CSV files in $OUTPUT_DIR/"
echo "Next: convert CSV to binary format using csv_to_bin_converter"
