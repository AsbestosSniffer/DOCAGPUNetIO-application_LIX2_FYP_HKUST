# ═══════════════════════════════════════════════════════════════════════
#  FYP Top-Level Makefile — DOCA GPUNetIO Trading System
# ═══════════════════════════════════════════════════════════════════════
#
# Targets:
#   make cpu        — Build System 1 (CPU baseline)
#   make gpu        — Build System 2 (GPU RDMA pipeline)
#   make doca       — Build System 3 (DOCA GPUNetIO) — requires DOCA SDK
#   make tools      — Build converter + replayer (from mini_trader/)
#   make all        — Build cpu + gpu + tools
#   make bench      — Run benchmark suite
#   make clean      — Remove all binaries
#
# GPU selection: defaults to GPU 1 (sm_86 for A2).
# Override with: make gpu CUDA_ARCH=86

NVCC      = nvcc
CXX       = g++
CXXFLAGS  = -O3 -std=c++17 -Wall
NVCCFLAGS = -O3 -std=c++17
CUDA_ARCH ?= 86

COMMON    = common

# ─── System 1: CPU Baseline ───────────────────────────────────────────
CPU_SRC = cpu_baseline/cpu_pipeline.cpp
CPU_BIN = cpu_baseline/cpu_baseline

cpu: $(CPU_BIN)

$(CPU_BIN): $(CPU_SRC) $(COMMON)/market_event.h $(COMMON)/benchmark.h $(COMMON)/pnl_tracker.h $(COMMON)/binance_feed.h
	$(CXX) $(CXXFLAGS) -I$(COMMON) $(CPU_SRC) -o $(CPU_BIN) -lpthread

# ─── System 2: GPU RDMA Pipeline ─────────────────────────────────────
GPU_SRC = gpu_rdma/src/gpu_pipeline.cu
GPU_BIN = gpu_rdma/gpu_rdma_pipeline

gpu: $(GPU_BIN)

$(GPU_BIN): $(GPU_SRC) $(COMMON)/market_event.h $(COMMON)/benchmark.h $(COMMON)/pnl_tracker.h $(COMMON)/binance_feed.h
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) -I$(COMMON) $(GPU_SRC) -o $(GPU_BIN)

# ─── System 3: DOCA GPUNetIO (meson build, separate) ─────────────────
doca:
	@echo "DOCA build requires meson. Run:"
	@echo "  cd gpu_doca && meson setup build && ninja -C build"

# ─── Legacy Tools (from mini_trader/) ─────────────────────────────────
CONVERTER_SRC = mini_trader/src/csv_to_bin_converter.cpp
CONVERTER_BIN = mini_trader/csv_to_bin_converter

REPLAYER_SRC  = mini_trader/src/udp_replayer.cpp
REPLAYER_BIN  = mini_trader/udp_replayer

LEGACY_GPU_SRC = mini_trader/src/gpu_staging.cu
LEGACY_GPU_BIN = mini_trader/gpu_staging

RECEIVER_SRC  = mini_trader/src/udp_receiver.cpp
RECEIVER_BIN  = mini_trader/udp_receiver

tools: $(CONVERTER_BIN) $(REPLAYER_BIN)

$(CONVERTER_BIN): $(CONVERTER_SRC)
	$(CXX) $(CXXFLAGS) -Imini_trader/include $(CONVERTER_SRC) -o $(CONVERTER_BIN)

$(REPLAYER_BIN): $(REPLAYER_SRC)
	$(CXX) $(CXXFLAGS) -Imini_trader/include $(REPLAYER_SRC) -o $(REPLAYER_BIN)

legacy_gpu: $(LEGACY_GPU_BIN)

$(LEGACY_GPU_BIN): $(LEGACY_GPU_SRC)
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) -Imini_trader/include $(LEGACY_GPU_SRC) -o $(LEGACY_GPU_BIN)

legacy_receiver: $(RECEIVER_BIN)

$(RECEIVER_BIN): $(RECEIVER_SRC)
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) -Imini_trader/include -x cu $(RECEIVER_SRC) -o $(RECEIVER_BIN)

# ─── Aggregate ───────────────────────────────────────────────────────
all: cpu gpu tools

# ─── Benchmark ───────────────────────────────────────────────────────
bench: all
	chmod +x benchmark/run_benchmarks.sh
	benchmark/run_benchmarks.sh quick

bench-full: all
	chmod +x benchmark/run_benchmarks.sh
	benchmark/run_benchmarks.sh full

# ─── Clean ───────────────────────────────────────────────────────────
clean:
	rm -f $(CPU_BIN) $(GPU_BIN) $(CONVERTER_BIN) $(REPLAYER_BIN)
	rm -f $(LEGACY_GPU_BIN) $(RECEIVER_BIN)
	rm -f mini_trader/mini_trader_stream mini_trader/results_logger
	rm -rf gpu_doca/build/

.PHONY: all cpu gpu doca tools legacy_gpu legacy_receiver bench bench-full clean
