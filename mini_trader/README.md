# Modular GPU Trading Pipeline

## Build Targets

- `converter`: CSV→BIN converter
- `replayer`: UDP replayer (can use fake data)
- `receiver`: UDP receiver (batches for GPU)
- `gpu`: GPU pipeline (dummy kernels)
- `logger`: Results logger

## Quick Start

### 1. Build all modules

```bash
cd mini_trader
make converter replayer receiver gpu logger
```

### 2. Convert CSV to binary (or skip for fake data)

```bash
./csv_to_bin_converter data/raw/BTCUSDT/2023-01-01.csv BTCUSDT data/bin/BTCUSDT.bin
```

### 3. Replay events (fake data mode)

```bash
./udp_replayer 127.0.0.1 9999 FAKE 1000 10000 0
```
- Sends 10,000 fake events in batches of 1,000 to UDP port 9999

### 4. Receive events

```bash
./udp_receiver 9999 1000
```
- Prints received batch info

### 5. Run GPU pipeline (standalone test)

```bash
./gpu_staging 10000
```
- Prints dummy packed orders

### 6. Log results

```bash
./results_logger orders.csv
```
- Writes dummy orders to CSV

## File Structure

- `include/market_event.h`: Unified event struct and symbol mapping
- `src/csv_to_bin_converter.cpp`: CSV→BIN converter
- `src/udp_replayer.cpp`: UDP replayer (with fake data option)
- `src/udp_receiver.cpp`: UDP receiver (batches for GPU)
- `src/gpu_staging.cu`: GPU pipeline (dummy kernels)
- `src/results_logger.cpp`: Results logger

## Next Steps
- Integrate real GPU pipeline with receiver
- Add real CSV/BIN data for full test
- Swap UDP receiver to DPDK when NIC is ready
